`timescale 1ns / 1ps

module application(
	input CLK,
	input RESET,
	
	// read from some internal FIFO (recieved via high-speed interface)
	input [63:0] din,
	output rd_en,
	input empty,

	// write into some internal FIFO (to be send via high-speed interface)
	output [63:0] dout,
	output wr_en,
	input full,
	output pkt_end,
	
	// control input (VCR interface)
	input [7:0] app_mode,
	// status output (VCR interface)
	output [7:0] app_status
	);

	assign app_status = 8'h00;
	
	// Application: send what received
	assign dout = din;
	assign rd_en = do_rw;
	assign wr_en = do_rw;
	assign pkt_end = 1'b1;
	
	assign do_rw =
		// Application mode 0 (default): send immediately
		(app_mode == 8'h00) ? ~empty && ~full :
		// Application mode 1: let's say we have some processing, 1 word in 16 clock cycles @30 MHz
		(app_mode == 8'h01) ? ~empty && ~full && do_rw_ok :
		1'b0;

	reg [3:0] counter = 0;
	wire do_rw_ok = counter == 15;

	always @(posedge CLK) begin
		if (RESET) begin
			counter <= 0;
		end
		else begin
			counter <= counter + 1'b1;
		end
	end
	
endmodule
