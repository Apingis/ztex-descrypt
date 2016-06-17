`timescale 1ns / 1ps

//**********************************************************
//
// Output FIFO (high-speed output).
//
//**********************************************************

module output_fifo (
	input wr_clk,
	//input [63:0] din,
	input [15:0] din,
	input wr_en,
	output full,

	input rd_clk,
	output [15:0] dout,
	input rd_en,
	output empty,
	//input pkt_end,
	//output err_overflow,
	input mode_limit,
	input reg_output_limit,
	//input [15:0] output_limit_min,
	output [15:0] output_limit,
	output output_limit_not_done
	);

	// Frontend 16-deep asynchronous FIFO:
	// Required for Clock Domain Crossing
	// IP Coregen: DRAM - Independent clocks, width 64, 1st Word Fall-Through
	//
	// TODO: replace with some 1-deep design

/*	wire [63:0] data_stage2;
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
*/

	wire [15:0] data_stage2;
	fifo_dram_async_16 fifo_dram_async_16(
		.wr_clk(wr_clk),
		.din(din),
		.wr_en(wr_en),
		.full(full),

		.rd_clk(rd_clk),
		.dout(data_stage2),
		.rd_en(rd_en_stage2),
		.empty(empty_stage2)
	);
	assign rd_en_stage2 = ~empty_stage2 & ~full_stage2;
	assign wr_en_stage2 = rd_en_stage2;

/*
	// Output FIFO reconsidered:
	//
	// * Task for handling application's data packets
	//		removed from link layer
	//
	packet_aware_fifo packet_aware_fifo_inst(
		.rst(1'b0),
		.CLK(rd_clk),
		.din(data_stage2),
		.wr_en(wr_en_stage2),
		.rd_en(rd_en),
		.dout(dout),
		.full(full_stage2),
		.empty(empty),
		
		.pkt_end(1'b1),//pkt_end),
		.err_overflow(),//err_overflow),
		.mode_limit(mode_limit),
		.reg_output_limit(reg_output_limit),
		.output_limit_min(16'b0),//output_limit_min),
		.output_limit(output_limit),
		.output_limit_done(output_limit_done)
	);
*/

	output_limit_fifo #(
		//.ADDR_MSB(12)
		.ADDR_MSB(13)	// 32 Kbytes
	) output_limit_fifo(
		.rst(1'b0),
		.CLK(rd_clk),
		
		.din(data_stage2),
		.wr_en(wr_en_stage2),
		.full(full_stage2),

		.dout(dout),
		.rd_en(rd_en),
		.empty(empty),
		
		.mode_limit(mode_limit),
		.reg_output_limit(reg_output_limit),
		.output_limit(output_limit),
		.output_limit_not_done(output_limit_not_done)
	);

endmodule
