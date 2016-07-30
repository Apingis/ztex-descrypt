`timescale 1ns / 1ps


module input_fifo(
	input wr_clk,
	input [15:0] din,
	input wr_en,
	output full,
	output almost_full,
	output prog_full,
	
	input rd_clk,
	input rd_en,
	output [7:0] dout,
	output empty
	);

	// FIFO Generator v9.3
	// * Independent Clocks - Block RAM
	// * 1st word Fall-Through
	// * write: width 16, depth 16384 (32 Kbytes), read width 8
	// * Almost Full Flag
	// * Single Programmable Full Threshold Constant: Assert Value 8192
	// * Reset: off
	wire [7:0] din_stage2;
	
	fifo_16in_8out fifo_16in_8out(
		.wr_clk(wr_clk),
		.din(din),
		.wr_en(wr_en),
		.full(full),
		.almost_full(almost_full),
		.prog_full(prog_full),
		
		.rd_clk(wr_clk),
		//.dout(dout),
		//.rd_en(rd_en),
		//.empty(empty)
		.dout(din_stage2),
		.rd_en(tx_stage2),
		.empty(empty_stage2)
	);

	assign tx_stage2 = ~empty_stage2 & ~full_stage2;

	//
	// fifo_16in_8out is large in size and its memory blocks are scattered over large area.
	// That's unable to operate at high frequency such as 200 MHz because of routing delay.
	// An additional small FIFO is append.
	//

	// FIFO Generator v9.3
	// * Independent Clocks
	// * 1st word Fall-Through
	// * Reset: off
	fifo_bram_8x1024_fwft fifo_bram_8x1024_fwft(
		.wr_clk(wr_clk),
		.din(din_stage2),
		.wr_en(tx_stage2),
		.full(full_stage2),

		.rd_clk(rd_clk),
		.dout(dout),
		.rd_en(rd_en),
		.empty(empty)
	);

endmodule
