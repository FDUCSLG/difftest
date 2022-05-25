`include "include/common.sv"

import "DPI-C" function int get_switch();

// import "DPI-C" function void ram_write_helper
// (
//   input  longint    wIdx,
//   input  longint    wdata,
//   input  longint    wmask,
//   input  bit        wen
// );

// import "DPI-C" function longint ram_read_helper
// (
//   input  bit        en,
//   input  longint    rIdx
// );

// latency

`define LATENCY
`ifndef RANDOMIZE_DELAY
`define RANDOMIZE_DELAY 31
`endif

`ifndef BENCHMARK
`define BENCHMARK 0
`endif

/* verilator lint_off WIDTH */

module RAMHelper1 import common::*;
(
	input logic clk, reset,
	input ibus_req_t  ireq,
	output  ibus_resp_t iresp,
	input dbus_req_t  dreq,
	output  dbus_resp_t dresp
);
	u64 wmask;
	for (genvar i = 0; i < 8; i++) begin
		assign wmask[i * 8 + 7 -: 8] = {8{dreq.strobe[i]}};
	end
	addr_t iidx, didx;
	assign iidx = ireq.addr > 64'h8000_0000 ? ((ireq.addr - 64'h8000_0000) >> 3) : 0;
	assign didx = dreq.addr > 64'h8000_0000 ? ((dreq.addr - 64'h8000_0000) >> 3) : 0;
	assign iresp.addr_ok = '1;
	assign iresp.data_ok = '1;
	assign dresp.addr_ok = '1;
	assign dresp.data_ok = '1;
	assign iresp.data = ireq.addr[2] ? (ram_read_helper('1, iidx) >> 32) : (ram_read_helper('1, iidx) & 'hffffffff);
	assign dresp.data = ram_read_helper('1, didx);
	always_ff @(posedge clk) begin
		if (ireq.valid && iidx >= 'h10000000) begin
			$display("ERROR: Load address %x out of range!\n", ireq.addr);
			$finish;
		end
		// if (dreq.valid && didx >= 'h10000000) begin
		// 	$display("Memory address %x out of range!", dreq.addr);
		// 	$finish;
		// end
		if (dreq.valid && dreq.strobe != 0) begin
			ram_write_helper(didx, dreq.data, wmask, '1);
		end
	end
endmodule

module RAMHelper2 import common::*;
(
	input logic clk, reset,
	input cbus_req_t  oreq,
	output  cbus_resp_t oresp,
	output logic trint, swint, exint
);
	
	cbus_req_t saved_oreq;
	enum i2 {NONE, WAIT, READ, WRITE} state;
	i8 count_down;
	i4 size;
	addr_t addr, idx, wrap1, wrap2;
	longint cyc_cnt, ms_cnt;
	assign idx = addr > 64'h8000_0000 ? ((addr - 64'h8000_0000) >> 3) : 0;
	u64 wmask;
	for (genvar i = 0; i < 8; i++) begin
		assign wmask[i * 8 + 7 -: 8] = {8{oreq.strobe[i]}};
	end

	u64 mtime, mtimecmp;
	logic msip;

	always_ff @(posedge clk) begin
		if (~reset) begin
			if (cyc_cnt == 25) begin
				ms_cnt <= ms_cnt + 1;
				mtime <= mtime + 1;
				cyc_cnt <= 0;
			end else
				cyc_cnt <= cyc_cnt + 1;
			trint <= mtime > mtimecmp;
			swint <= msip;
			unique case (state)
			NONE: begin
				if (oreq.valid) begin
					saved_oreq <= oreq;
					`ifdef LATENCY
					if (`BENCHMARK) count_down <= 1000; else
					count_down <= ($random() % `RANDOMIZE_DELAY) + 2;
					state <= WAIT;
					`else
					state <= oreq.is_write ? WRITE : READ;
					addr <= oreq.addr;
					count_down <= oreq.len;
					size <= 1 << oreq.size;
					if ((oreq.addr & ((1 << oreq.size) - 1)) != 0) begin
						$display("ERROR: Memory address misaligned.\n");
						$finish();
					end
					unique case (oreq.burst)
					AXI_BURST_FIXED: begin
						wrap1 <= oreq.addr;
						wrap2 <= oreq.addr + (1 << oreq.size);
					end
					AXI_BURST_WRAP: begin
						wrap1 <= oreq.addr & ~(((64'(oreq.len) + 1) << oreq.size) - 1);
						wrap2 <= (oreq.addr & ~(((64'(oreq.len) + 1) << oreq.size) - 1)) + ((64'(oreq.len) + 1) << oreq.size);
					end
					default: {wrap1, wrap2} <= '0;
					endcase
					`endif
				end
			end
			WAIT: begin
				// if (oreq != saved_oreq) begin
				// 	$display("ERROR: Unexpected CBus request modification.\n");
				// 	$finish();
				// end
				if (oreq.valid != saved_oreq.valid || 
					oreq.is_write != saved_oreq.is_write ||
					oreq.size != saved_oreq.size ||
					oreq.addr != saved_oreq.addr ||
					oreq.len != saved_oreq.len ||
					oreq.burst != saved_oreq.burst) begin
					$display("ERROR: Unexpected CBus request modification.\n");
					$finish();
				end
				unique if (count_down == 0) begin
					state <= oreq.is_write ? WRITE : READ;
					addr <= oreq.addr;
					count_down <= oreq.len;
					size <= 1 << oreq.size;
					// if ((oreq.addr & ((1 << oreq.size) - 1)) != 0) begin
					// 	$display("Memory address misaligned.\n");
					// 	$finish();
					// end
					unique case (oreq.burst)
					AXI_BURST_FIXED: begin
						wrap1 <= oreq.addr;
						wrap2 <= oreq.addr + (1 << oreq.size);
					end
					AXI_BURST_WRAP: begin
						wrap1 <= oreq.addr & ~(((64'(oreq.len) + 1) << oreq.size) - 1);
						wrap2 <= (oreq.addr & ~(((64'(oreq.len) + 1) << oreq.size) - 1)) + ((64'(oreq.len) + 1) << oreq.size);
					end
					default: {wrap1, wrap2} <= '0;
					endcase
				end else
					count_down <= count_down - 1;
			end
			READ: begin
				if (oreq.valid != saved_oreq.valid || 
					oreq.is_write != saved_oreq.is_write ||
					oreq.size != saved_oreq.size ||
					oreq.addr != saved_oreq.addr ||
					oreq.len != saved_oreq.len ||
					oreq.burst != saved_oreq.burst) begin
					$display("ERROR: Unexpected CBus request modification.\n");
					$finish();
				end
				// $display("\tread: %x %x", addr, oresp.data);
				if (idx >= 'h10000000) begin
					$display("ERROR: Load address %x out of range!\n", addr);
					$finish;
				end
				unique if (oresp.last)
					state <= NONE;
				else begin
					count_down <= count_down - 1;
					addr <= (addr + size == wrap2) ? wrap1 : addr + size;
				end
			end
			WRITE: begin
				if (oreq.valid != saved_oreq.valid || 
					oreq.is_write != saved_oreq.is_write ||
					oreq.size != saved_oreq.size ||
					oreq.addr != saved_oreq.addr ||
					oreq.len != saved_oreq.len ||
					oreq.burst != saved_oreq.burst) begin
					$display("ERROR: Unexpected CBus request modification.\n");
					$finish();
				end
				// $display("\twrite: %x %x %b", addr, oreq.data, oreq.strobe);
				// if (idx >= 'h10000000) begin
				// 	$display("Memory address %x out of range!", addr);
				// 	$finish;
				// end
				unique case (addr)
				64'h40600004: if (oreq.strobe[4]) begin
					$fwrite(32'h8000_0001, "%c", oreq.data[39:32]); // stdout
					$fflush(32'h8000_0001);
				end
				64'h23333000: if (oreq.data == 64'h233 && oreq.strobe == '1) $display("Pass!");
				64'h38000000: msip <= oreq.data[0];
				64'h38004000: mtimecmp <= oreq.data;
				64'h3800bff8: mtime <= oreq.data;
				default: if (addr != 64'h4060000c) ram_write_helper(idx, oreq.data, wmask, '1);
				endcase
				unique if (oresp.last)
					state <= NONE;
				else begin
					count_down <= count_down - 1;
					addr <= addr + size;
				end
			end
			endcase
		end else begin
			{state, count_down, cyc_cnt, ms_cnt, addr, size, saved_oreq} <= '0;
			mtime <= '0;
			mtimecmp <= '1;
			msip <= '0;
			{trint, swint, exint} <= '0;
		end
	end

	always_comb begin
		oresp = '0;
		unique if (state == READ) begin
			oresp.ready = '1;
			oresp.last = count_down == 0;
			unique case (addr)
			64'h40600008: oresp.data = '0;
			64'h38000000: oresp.data = {63'0, msip};
			64'h38004000: oresp.data = mtimecmp;
			64'h3800bff8: oresp.data = mtime;
			64'h20003000: oresp.data = ms_cnt;
			64'h23333008: oresp.data = {'0, get_switch()}; // switch
			default: oresp.data = ram_read_helper('1, idx);
			endcase
		end else if (state == WRITE) begin
			oresp.ready = '1;
			oresp.last = count_down == 0;
		end else
			oresp = '0;
	end

endmodule