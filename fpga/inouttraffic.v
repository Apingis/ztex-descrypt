`timescale 1ns / 1ps

// *************************************************************
//
// 20.03.2016
//
// ISE version: 14.5
// Design Goals & Strategies:
// * Strategy: Default (Balanced)
// * Edit -> "Generate Programming File" -> "unused IOB pins" -> "Float"
// 
//
// *************************************************************

module inouttraffic(
	input CS,
	input [2:0] FPGA_ID,
	// It switches IFCLK to 48 MHz when it uploads bitstream.
	// On other FPGAs, CS is low at that time.
	input IFCLK,
	
	// suggest FXCLK as a clock source for application.
	input FXCLK,

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
	input FLAGB, // FULL
	input FLAGC // EMPTY
	);

	// Application clock CLK_APP
	wire CLK_APP = FXCLK;
	
	// Reset is performed via VCR interface with respect to IFCLK
	wire RESET;
	
	wire [7:0] debug1, debug2, debug3;


	// ********************************************************
	//
	// Input buffer (via High Speed interface)
	//
	// ********************************************************

	// * IP Coregen -> FIFO Generator v9.3 -> Native
	// * Independent Clocks - Block RAM
	// * 1st word Fall-Through
	// * write depth 8192 (16 Kbytes)
	// * Single Programmable Full Threshold Constant: Assert Value 4097
	wire [63:0] hs_input_dout;
	wire [15:0] hs_input_din; // input via High-Speed Interface
	
	fifo_16in_64out fifo_16in_64out_inst(
		.rst(RESET),
		.wr_clk(IFCLK),
		.rd_clk(CLK_APP),
		.din(hs_input_din), // wired to Cypress IO
		.wr_en(hs_input_wr_en), // wired to Cypress IO
		.rd_en(hs_input_rd_en),
		.dout({hs_input_dout[15:0],hs_input_dout[31:16],hs_input_dout[47:32],hs_input_dout[63:48]}),
		.full(),//hs_input_full), // wired to Cypress IO
		.almost_full(hs_input_almost_full), // wired to Cypress IO
		.prog_full(hs_input_prog_full),
		.empty(hs_input_empty)
	);	

	
	// ********************************************************
	//
	// Some example application
	// sends back input data
	//
	// Application sends/receives data in 64-bit words
	//
	// ********************************************************
	wire [63:0] app_dout;
	wire [7:0] app_mode;
	wire [7:0] app_status;
	
	application application_inst(
		.CLK(CLK_APP),
		.RESET(RESET),
		// High-Speed FPGA input
		.din(hs_input_dout),
		.rd_en(hs_input_rd_en),
		.empty(hs_input_empty),
		// High-Speed FPGA output
		.dout(app_dout),
		.wr_en(app_wr_en),
		.full(app_full),
		.pkt_end(app_pkt_end),
		// Application control (via VCR I/O). Set with fpga_set_app_mode()
		.app_mode(app_mode),
		// Application status (via VCR I/O). Available at fpga->wr.io_state.app_status
		.app_status(app_status)
	);
	
	
	// ********************************************************
	//
	// Output buffer (via High-Speed interface)
	//
	// ********************************************************
	wire [15:0] output_limit, output_limit_min;
	wire [15:0] output_dout; // output via High-Speed Interface

	(* KEEP_HIERARCHY="true" *)
	packet_aware_fifo packet_aware_fifo_inst(
		.rst(RESET),
		.wr_clk(CLK_APP),
		.rd_clk(IFCLK),
		.din(app_dout),
		.wr_en(app_wr_en),
		.rd_en(output_rd_en), // wired to Cypress IO,
		.dout(output_dout), // wired to Cypress IO,
		.full(app_full),
		.empty(output_empty), // wired to Cypress IO
		.pkt_end(app_pkt_end),
		.err_overflow(output_err_overflow),
		.mode_limit(output_mode_limit),
		.reg_output_limit(reg_output_limit),
		.output_limit_min(output_limit_min),
		.output_limit(output_limit),
		.output_limit_done(output_limit_done)
	);


	// ********************************************************
	//
	// High-Speed I/O Interface (Slave FIFO)
	//
	// ********************************************************
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
		.output_err_overflow(output_err_overflow), .sfifo_not_empty(sfifo_not_empty),
		.output_limit(output_limit), .output_limit_done(output_limit_done),
		.app_status(app_status),
		.debug1(debug1), .debug2(debug2), .debug3(debug3),
		// various control wires
		.hs_en(hs_en),
		.output_mode_limit(output_mode_limit),
		.output_limit_min(output_limit_min),
		.reg_output_limit(reg_output_limit),
		.app_mode(app_mode),
		.RESET_OUT(RESET)
	);


endmodule
