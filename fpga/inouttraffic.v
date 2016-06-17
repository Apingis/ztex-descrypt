`timescale 1ns / 1ps

// *************************************************************
//
// 20.03.2016
//
// ISE version: 14.5
// Design Goals & Strategies:
// * Strategy: Default (Balanced)
// * Edit -> "Generate Programming File" -> "unused IOB pins" -> "Float"  <-- fixed by defining INT outputs
// 
// definitions.vh -> "Source Properties" -> "Include as Global File in Compile List"
//
// * http://github.com/Apingis
//
// *************************************************************

module inouttraffic(
	input CS_IN,
	input [2:0] FPGA_ID,
	// It switches IFCLK to 48 MHz when it uploads bitstream.
	// On other FPGAs, CS is low at that time.
	input IFCLK_IN,
	
	// suggest FXCLK as a clock source for application.
	input FXCLK_IN,

	// Vendor Command/Request I/O
	inout [7:0] PC, //  Vendor Command/Request (VCR) address/data
	input PA0, // set (internal to FPGA) VCR IO address
	input PA1, // write or synchronous read
	input PA7, // PC direction: 0 = write to FPGA, 1 = read from FPGA

	// High-Speed I/O Interface
	inout [15:0] FIFO_DATA,
	output FIFOADR0,
	output FIFOADR1,
	output SLOE, 
	output SLRD,
	output SLWR,
	output PKTEND,
	input FLAGA,
	input FLAGB, // FULL
	input FLAGC, // EMPTY

	output INT4,
	output INT5
	);


	clocks #(
		.PKT_COMM_FREQUENCY(216)
	) clocks(
		// Input clocks go to Clock Management Tile via dedicated routing
		.IFCLK_IN(IFCLK_IN),
		.FXCLK_IN(FXCLK_IN),
		// Produced clocks
		.IFCLK(IFCLK), 	// for operating I/O pins
		.PKT_COMM_CLK(PKT_COMM_CLK) // for processing data packets
		//.APP_CLK(APP_CLK)		// for running the application
	);

	chip_select chip_select(
		.CS_IN(CS_IN), .CLK(IFCLK), .CS(CS), .out_z_wait1(out_z_wait1)//, .out_z(out_z)
	);
	
	wire [7:0] debug2, debug3;
	assign debug3 = 8'hd3;


	// ********************************************************
	//
	// Input buffer (via High Speed interface)
	//
	// ********************************************************
	wire [15:0] hs_input_din;
	wire [7:0] hs_input_dout;
	
	input_fifo input_fifo(
		.wr_clk(IFCLK),
		.din( {hs_input_din[7:0],hs_input_din[15:8]} ), // wired to Cypress IO
		.wr_en(hs_input_wr_en), // wired to Cypress IO
		.full(),//hs_input_full), // wired to Cypress IO
		.almost_full(hs_input_almost_full), // wired to Cypress IO
		.prog_full(hs_input_prog_full),

		.rd_clk(PKT_COMM_CLK),
		.dout(hs_input_dout),
		.rd_en(hs_input_rd_en),
		.empty(hs_input_empty)
	);	

	
	// ********************************************************
	//
	// Some example application
	// 8-bit input, 16-bit output
	//
	// ********************************************************
	//wire [63:0] app_dout;
	wire [15:0] app_dout;
	wire [7:0] app_mode;
	wire [7:0] app_status, pkt_comm_status;
	
	//pkt_comm pkt_comm(
	application application(
		.CLK(PKT_COMM_CLK),
		//.APP_CLK(APP_CLK),
		// High-Speed FPGA input
		.din(hs_input_dout),
		.rd_en(hs_input_rd_en),
		.empty(hs_input_empty),
		// High-Speed FPGA output
		.dout(app_dout),
		.wr_en(app_wr_en),
		.full(app_full),
		// Application control (via VCR I/O). Set with fpga_set_app_mode()
		.app_mode(app_mode),
		// Application status (via VCR I/O). Available at fpga->wr.io_state.app_status
		.pkt_comm_status(pkt_comm_status),
		.debug2(debug2),
		.app_status(app_status)
	);
	
	
	// ********************************************************
	//
	// Output buffer (via High-Speed interface)
	//
	// ********************************************************
	wire [15:0] output_limit;//, output_limit_min;
	wire [15:0] output_dout; // output via High-Speed Interface

	output_fifo output_fifo(
		.wr_clk(PKT_COMM_CLK),
		.din(app_dout),
		.wr_en(app_wr_en),
		.full(app_full),

		.rd_clk(IFCLK),
		.dout(output_dout), // wired to Cypress IO,
		.rd_en(output_rd_en), // wired to Cypress IO,
		.empty(output_empty), // wired to Cypress IO
		//.pkt_end(app_pkt_end),
		//.err_overflow(output_err_overflow),
		.mode_limit(output_mode_limit),
		.reg_output_limit(reg_output_limit),
		//.output_limit_min(output_limit_min),
		.output_limit(output_limit),
		.output_limit_not_done(output_limit_not_done)
	);


	// ********************************************************
	//
	// High-Speed I/O Interface (Slave FIFO)
	//
	// ********************************************************
	wire [7:0] hs_io_timeout;
	
	hs_io_v2 #(
		.USB_ENDPOINT_IN(2),
		.USB_ENDPOINT_OUT(6)
	) hs_io_inst(
		.IFCLK(IFCLK), .CS(CS), .out_z_wait1(out_z_wait1), .EN(hs_en),
		.FIFO_DATA(FIFO_DATA), .FIFOADR0(FIFOADR0), .FIFOADR1(FIFOADR1),
		.SLOE(SLOE), .SLRD(SLRD), .SLWR(SLWR), .PKTEND(PKTEND), .FLAGA(FLAGA), .FLAGB(FLAGB), .FLAGC(FLAGC),
		// data output from Cypress IO, received by FPGA
		.dout(hs_input_din),	.wr_en(hs_input_wr_en), .almost_full(hs_input_almost_full),
		.din(output_dout), .rd_en(output_rd_en), .empty(output_empty), // to Cypress IO, out of FPGA
		.io_timeout(hs_io_timeout), .sfifo_not_empty(sfifo_not_empty),
		.io_fsm_error(io_fsm_error), .io_err_write(io_err_write)
	);
/*
	wire ENABLE_HS_IO = CS && hs_en && !RESET;
	assign FIFO_DATA = (ENABLE_HS_IO && hs_io_rw_direction) ? output_dout : 16'bz;
	wire [7:0] hs_io_timeout;
	
	(* KEEP_HIERARCHY="true" *) hs_io #(
		.USB_ENDPOINT_IN(2),
		.USB_ENDPOINT_OUT(6)
	) hs_io_inst(
		.IFCLK(IFCLK), .CS(CS), .EN(ENABLE_HS_IO), .FIFO_DATA_IN(FIFO_DATA), .FIFOADR0(FIFOADR0), .FIFOADR1(FIFOADR1),
		.SLOE(SLOE), .SLRD(SLRD), .SLWR(SLWR), .PKTEND(PKTEND), .FLAGB(FLAGB), .FLAGC(FLAGC),
		.dout(hs_input_din), .rw_direction(hs_io_rw_direction),
		.wr_en(hs_input_wr_en), .almost_full(hs_input_almost_full),// data output from Cypress IO, received by FPGA
		.rd_en(output_rd_en), .empty(output_empty), // to Cypress IO, out of FPGA
		.io_timeout(hs_io_timeout), .sfifo_not_empty(sfifo_not_empty)
	);
*/
	// ********************************************************
	//
	// Vendor Command/Request (VCR) I/O interface
	//
	// ********************************************************
	wire [7:0] vcr_in = PC;
	wire [7:0] vcr_out;
	assign PC = CS && PA7 ? vcr_out : 8'bz;
	
	(* KEEP_HIERARCHY="true" *) vcr vcr_inst(
		.CS(CS), .vcr_in(vcr_in), .vcr_out(vcr_out), .clk_vcr_addr(PA0), .clk_vcr_data(PA1),
		// i/o goes with respect to IFCLK
		.IFCLK(IFCLK),
		// various inputs to be read by CPU
		.FPGA_ID(FPGA_ID),
		.hs_io_timeout(hs_io_timeout), .hs_input_prog_full(hs_input_prog_full),
		//.output_err_overflow(output_err_overflow), 
		.sfifo_not_empty(sfifo_not_empty), .io_fsm_error(io_fsm_error), .io_err_write(io_err_write),
		.output_limit(output_limit), .output_limit_not_done(output_limit_not_done),
		.app_status(app_status),
		.pkt_comm_status(pkt_comm_status), .debug2(debug2), .debug3(debug3),
		// various control wires
		.hs_en(hs_en),
		.output_mode_limit(output_mode_limit),
		//.output_limit_min(output_limit_min),
		.reg_output_limit(reg_output_limit),
		.app_mode(app_mode),
		.RESET_OUT()
	);


	// External interrupts for USB controller - put into defined state
	assign INT4 = 1'b0;
	assign INT5 = 1'b1;

endmodule
