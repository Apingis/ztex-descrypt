`timescale 1ns / 1ps

//*****************************************************************************
//
// High-Speed communtcation to USB device controller's Slave FIFO
//
// It is implemented on a state machine with outputs dependent on both input
// and internal state. That's slow and is unable to operate at 48 MHz IFCLK.
//
//*****************************************************************************

module hs_io #(
	parameter USB_ENDPOINT_IN = 2, // from the point of view from the host
	parameter USB_ENDPOINT_OUT = 6
	)(
	input IFCLK,
	// Low CS puts all outputs into Z-state,
	// exactly as examples/intraffic is doing
	input CS, 
	
	// enable read/write
	input EN,

	// Attention: attempt to send data to FPGA not aligned to
	// 2-byte word would result in a junk in upper byte
	input [15:0] FIFO_DATA_IN,
	output FIFOADR0,
	output FIFOADR1,
	// Following signals are active low.
	output SLOE, // Slave output enable
	output SLRD,
	output SLWR,
	output PKTEND,
	input FLAGB, // FULL
	input FLAGC, // EMPTY

	output rw_direction,
	
	// write into some internal FIFO
	output [15:0] dout,
	output wr_en,
	//input full,
	input almost_full,
	
	// read from some internal FIFO
	//input [15:0] din,
	output rd_en,
	input empty,

	// status information
	output [7:0] io_timeout, // in ~1us intervals @30MHz IFCLK
	output sfifo_not_empty,
	output io_fsm_error
	);

	wire ENABLE = EN && CS;
	
	assign sfifo_not_empty = FLAGC;
	assign io_fsm_error = 1'b0;

	// Input register (data-out from hs_io)
	(* KEEP="true" *) reg [15:0] input_r;
	assign dout = input_r;
	always @(posedge IFCLK)
		input_r <= FIFO_DATA_IN;
	
	(* KEEP_HIERARCHY="true" *) hs_io_logic hs_io_logic_inst(
		.IFCLK(IFCLK), .ENABLE(ENABLE),
		.FLAGB(FLAGB), .FLAGC(FLAGC),
		.rw_direction(rw_direction), .input_r_ok(input_r_ok),
		.IO_WRITE_OK(IO_WRITE_OK), .IO_READ_OK(IO_READ_OK),
		.IO_SLOE_OK(IO_SLOE_OK), .IO_PKTEND_OK(IO_PKTEND_OK),
		.full(almost_full), .empty(empty),
		.io_timeout(io_timeout)
	);

	assign SLOE = ~CS ? 1'bz : EN ? ~IO_SLOE_OK : 1'b1;
	assign SLRD = ~CS ? 1'bz : EN ? ~IO_READ_OK : 1'b1;
	assign wr_en = input_r_ok;

	assign SLWR = ~CS ? 1'bz : EN ? ~IO_WRITE_OK : 1'b1;
	assign rd_en = IO_WRITE_OK;
	assign PKTEND = ~CS ? 1'bz : EN ? ~IO_PKTEND_OK : 1'b1;
	
	localparam USB_EP_OUT_B = (USB_ENDPOINT_OUT-2) >> 1;
	localparam USB_EP_IN_B = (USB_ENDPOINT_IN-2) >> 1;
	assign {FIFOADR1, FIFOADR0} =
		~CS ? 2'bz :
		EN && rw_direction ? USB_EP_IN_B[1:0] :
		USB_EP_OUT_B[1:0];

endmodule


/////////////////////////////////////////////////////////////////////
//
//  Gather the stuff in some place near FLAG{B,C}, SL{WR/RD}
//  SLICE_X124Y120:SLICE_X127Y127
//
/////////////////////////////////////////////////////////////////////
module hs_io_logic (
	input IFCLK,
	input ENABLE,
	output reg rw_direction = 0,
	output reg input_r_ok = 0,
	output IO_WRITE_OK,
	output IO_READ_OK,
	output IO_SLOE_OK,
	output IO_PKTEND_OK,
	input FLAGB, // FULL
	input FLAGC, // EMPTY
	input full,
	input empty,
	output [7:0] io_timeout // in ~1us intervals @30MHz IFCLK
	);

	// It works as follows:
	// 1. reads as long as possible; //up to USB_PKT_SIZE, 
	// 2. writes up to USB_PKT_SIZE.
	localparam USB_PKT_SIZE = 256; // in 16-bit words
	reg [8:0] word_counter = 0;
	
	localparam TIMEOUT_MSB = 12;
	reg [TIMEOUT_MSB:0] timeout = 0;//{TIMEOUT_MSB+1{1'b1}};
	assign io_timeout = timeout[TIMEOUT_MSB : TIMEOUT_MSB-7];

	// Finally deal with PKTEND issue.
	// - when output FIFO is in mode_limit, there's no problem:
	// FIFO already has all the data, so it outputs every cycle
	// until EMPTY.
	// - when mode_limit is off, the data might arrive from FPGA's output FIFO
	// in small pieces such as 2-8 bytes or so, with intervals like 2-4 cycles.
	// That might result in partial reads by the host and overall performance degradation.
	// 
	localparam PKTEND_WR_TIMEOUT = 5;
	reg [2:0] rw_timeout = 0;

	wire READ_OK = (!full && FLAGC && ENABLE);// && word_counter < USB_PKT_SIZE);
	wire WRITE_OK = (!empty && FLAGB && ENABLE && word_counter != USB_PKT_SIZE);
	//wire PKTEND_OK = (empty && FLAGB && ENABLE && word_counter > 0 && word_counter < USB_PKT_SIZE);
	
	localparam IO_STATE_RESET = 1;
	localparam IO_STATE_READ_SETUP0 = 2;
	localparam IO_STATE_READ_SETUP1 = 3;
	localparam IO_STATE_READ_SETUP2 = 4;
	localparam IO_STATE_READ = 6;
	localparam IO_STATE_WR_SETUP0 = 7;
	localparam IO_STATE_WR_SETUP1 = 8;
	localparam IO_STATE_WR_SETUP2 = 9;
	localparam IO_STATE_WR = 11;
	localparam IO_STATE_DISABLED = 13;
	localparam IO_STATE_WR_WAIT = 14;
	
	(* FSM_EXTRACT="YES" *)//,FSM_ENCODING="auto" *)
	reg [3:0] io_state = IO_STATE_RESET;
	
	always @(posedge IFCLK)
	begin
		if (!ENABLE && io_state != IO_STATE_DISABLED)
			io_state <= IO_STATE_DISABLED;
			
		if ( ! (&timeout[TIMEOUT_MSB : TIMEOUT_MSB-7]) )
			timeout <= timeout + 1'b1;
		
		(* FULL_CASE, PARALLEL_CASE *) case (io_state)
		IO_STATE_RESET: begin
			//timeout <= {TIMEOUT_MSB+1{1'b1}};
			io_state <= IO_STATE_READ_SETUP0;
		end

		IO_STATE_READ_SETUP0: begin
			rw_direction <= 0;
			//word_counter <= 0;
			io_state <= IO_STATE_READ_SETUP1;
		end

		IO_STATE_READ_SETUP1:
			io_state <= IO_STATE_READ_SETUP2;

		IO_STATE_READ_SETUP2:
			io_state <= IO_STATE_READ;
		
		IO_STATE_READ: begin
			if (READ_OK) begin
				input_r_ok <= 1;
				//word_counter <= word_counter + 1'b1;
				timeout <= 0;
			end
			else begin
				input_r_ok <= 0;
				io_state <= IO_STATE_WR_SETUP0;
			end
			
		end

		IO_STATE_WR_SETUP0: begin
			rw_direction <= 1;
			word_counter <= 0;
			io_state <= IO_STATE_WR_SETUP1;
		end

		IO_STATE_WR_SETUP1:
			io_state <= IO_STATE_WR_SETUP2;
		
		IO_STATE_WR_SETUP2:
			io_state <= IO_STATE_WR;

		IO_STATE_WR: begin
			if (WRITE_OK) begin
				word_counter <= word_counter + 1'b1;
				timeout <= 0;
				rw_timeout <= 0;
			end
			else begin
				if (!FLAGB || word_counter == USB_PKT_SIZE || word_counter == 0)
					io_state <= IO_STATE_READ_SETUP0;

				else if (rw_timeout == PKTEND_WR_TIMEOUT)
					io_state <= IO_STATE_WR_WAIT;

				rw_timeout <= rw_timeout + 1'b1;
			end
		end
		
		IO_STATE_WR_WAIT: begin
			io_state <= IO_STATE_READ_SETUP0;
		end
		
		IO_STATE_DISABLED: begin
			rw_direction <= 0;
			if (ENABLE)
				io_state <= IO_STATE_READ_SETUP0;
		end
		endcase
	end // IFCLK
	
	assign IO_READ_OK = io_state == IO_STATE_READ && READ_OK;
	assign IO_WRITE_OK = io_state == IO_STATE_WR && WRITE_OK;
	
	assign IO_SLOE_OK = (io_state == IO_STATE_READ_SETUP2 || io_state == IO_STATE_READ);
	assign IO_PKTEND_OK = io_state == IO_STATE_WR_WAIT;//IO_STATE_WR && PKTEND_OK;
	
endmodule

