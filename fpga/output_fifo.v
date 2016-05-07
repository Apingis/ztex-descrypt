`timescale 1ns / 1ps

//**********************************************************
//
// Output FIFO (high-speed output).
//
//**********************************************************

module output_fifo (
	input rst,
	input wr_clk,
	input rd_clk,
	input [63:0] din,
	input wr_en,
	input rd_en,
	output [15:0] dout,
	output full,
	output empty,
	input pkt_end,
	output err_overflow,
	input mode_limit,
	input reg_output_limit,
	input [15:0] output_limit_min,
	output [15:0] output_limit,
	output output_limit_done
	);

	// Frontend 16-deep asynchronous FIFO:
	// Required for Clock Domain Crossing
	// IP Coregen: DRAM - Independent clocks, width 64, 1st Word Fall-Through
	//
	// TODO: replace with some 1-deep design

	wire [63:0] data_stage2;
	fifo_dram_async fifo_dram_async(
	  .rst(rst),
	  .wr_clk(wr_clk),
	  .rd_clk(rd_clk),
	  .din(din),
	  .wr_en(wr_en),
	  .rd_en(rd_en_stage2),
	  .dout(data_stage2),
	  .full(full),
	  .empty(empty_stage2)
	);

	assign rd_en_stage2 = ~empty_stage2 & ~full_stage2;
	assign wr_en_stage2 = rd_en_stage2;

	packet_aware_fifo packet_aware_fifo_inst(
		.rst(rst),
		.CLK(rd_clk),
		.din(data_stage2),
		.wr_en(wr_en_stage2),
		.rd_en(rd_en),
		.dout(dout),
		.full(full_stage2),
		.empty(empty),
		
		.pkt_end(pkt_end),
		.err_overflow(err_overflow),
		.mode_limit(mode_limit),
		.reg_output_limit(reg_output_limit),
		.output_limit_min(output_limit_min),
		.output_limit(output_limit),
		.output_limit_done(output_limit_done)
	);

endmodule
