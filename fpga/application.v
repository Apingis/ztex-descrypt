`timescale 1ns / 1ps

module application(
	input CLK,
	//input RESET,
	
	// read from some internal FIFO (recieved via high-speed interface)
	//input [63:0] din,
	input [7:0] din,
	output rd_en,
	input empty,

	// write into some internal FIFO (to be send via high-speed interface)
	//output [63:0] dout,
	output [15:0] dout,
	output wr_en,
	input full,
	//output pkt_end,
	
	// control input (VCR interface)
	input [7:0] app_mode,
	
	// status output (VCR interface)
	output [7:0] pkt_comm_status,
	output [7:0] debug2,
	output [7:0] app_status
	);

	assign pkt_comm_status = 8'h00;
	assign debug2 = 8'h55;
	assign app_status = 8'h00;
	
	// convert 8-bit to 16-bit
	reg [15:0] dout_mode01;
	reg dout_mode01_ready = 0;
	reg counter = 0;

	// Application: send what received
	assign dout = dout_mode01;
	assign rd_en = ~empty & ~full;
	assign wr_en = dout_mode01_ready;
	
	
	always @(posedge CLK) begin
		if (counter == 0) begin
			dout_mode01_ready <= 0;
		end
		if (rd_en && (app_mode == 8'h00 || app_mode == 8'h01) ) begin
			if (counter == 0) begin
				dout_mode01[7:0] <= din;
			end
			else if (counter == 1) begin
				dout_mode01[15:8] <= din;
				dout_mode01_ready <= 1;
			end
			counter <= counter + 1'b1;
		end
	end
	
endmodule
