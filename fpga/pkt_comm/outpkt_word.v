`timescale 1ns / 1ps

//
// 1. Read words from wide bus
// (FWFT style read)
// 2. Create headers (packet type 0x81)
// 3. Write packets into 16-bit wide fifo
//
module outpkt_word(
	input CLK,

	input [32+16+ 55:0] din,
	input [15:0] pkt_id,
	input wr_en,
	output full,

	output [15:0] dout,
	output pkt_new, pkt_end,
	input rd_en,
	output empty
	);

	reg full_r = 0;
	assign full = full_r;
	assign empty = ~full_r;
	
	reg [32+16+ 55:0] din_r;
	reg [15:0] pkt_id_r;

	localparam HEADER_LEN = 10; // in bytes
	localparam [15:0] DATA_LEN = 14; // in bytes
	localparam NUM_WRITES = (HEADER_LEN + DATA_LEN) / 2;
	
	reg [`MSB(NUM_WRITES-1):0] count = 0;

	always @(posedge CLK) begin
		if (~full & wr_en) begin
			din_r <= din;
			pkt_id_r <= pkt_id;
			full_r <= 1;
		end

		if (~empty & rd_en) begin
			if (count == NUM_WRITES - 1) begin
				count <= 0;
				full_r <= 0;
			end
			else
				count <= count + 1'b1;
		end
	end

	assign pkt_new = count == 0;
	
	assign pkt_end = count == NUM_WRITES - 1;
	
	assign dout =
		// version, type
		count == 0 ? { 8'h81, 8'h01 } :
		// no checksum for now
		count == 1 ? { {16{1'b0}} } :
		// data length
		count == 2 ? DATA_LEN :
		count == 3 ? 16'h0 :
		// packet id
		count == 4 ? pkt_id_r :
		// packet header ends
		
		// data
		count == 5 ? { 1'b0, din_r[13:7], 1'b0, din_r[6:0] } :
		count == 6 ? { 1'b0, din_r[27:21], 1'b0, din_r[20:14] } :
		count == 7 ? { 1'b0, din_r[41:35], 1'b0, din_r[34:28] } :
		count == 8 ? { 1'b0, din_r[55:49], 1'b0, din_r[48:42] } :
		// IDs - word_id
		count == 9 ? { din_r[71:56] } :
		// IDs - gen_id
		count == 10 ? { din_r[87:72] } :
							{ din_r[103:88] };


endmodule
