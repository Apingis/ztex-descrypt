`timescale 1ns / 1ps

`include "../descrypt/descrypt_core/descrypt.vh"

// ******************************************************
//
// * Read units of various data (all the packet data in parallel)
// * Create output application packets (pkt_comm.h)
// * Expect read from 16-bit output FIFO
//
// ******************************************************

module outpkt_v2 #(
	parameter [7:0] VERSION = 1,
	parameter PKT_TYPE_MSB = 1
	)(
	input CLK,
	
	output full,
	input wr_en,
	input [PKT_TYPE_MSB:0] pkt_type,
	// data depends on packet type
	input [15:0] pkt_id, word_id, // this pkt_id is for inclusion into packet body for reference
	input [31:0] gen_id, num_processed,
	input [`RAM_ADDR_MSB:0] hash_num_eq,
	
	//input rd_clk,
	output [15:0] dout,
	input rd_en,
	output empty
	);

	localparam HEADER_LEN = 10; // in bytes

	localparam OUTPKT_TYPE_CMP_EQUAL		= 8'hD1;
	localparam OUTPKT_TYPE_PACKET_DONE	= 8'hD2;

	reg [PKT_TYPE_MSB:0] outpkt_type_r;
	
	wire [7:0] outpkt_type =
		outpkt_type_r == 'b01 ? OUTPKT_TYPE_CMP_EQUAL : 
		outpkt_type_r == 'b10 ? OUTPKT_TYPE_PACKET_DONE :
	0;

	wire [15:0] outpkt_len = // in bytes, must be even number
		outpkt_type_r == 'b01 ? 10 :
		outpkt_type_r == 'b10 ? 6 :
	0;
	
	
	// Register everything then go.
	reg [15:0] pkt_id_r, word_id_r;
	reg [31:0] gen_id_r, num_processed_r;
	reg [`RAM_ADDR_MSB:0] hash_num_eq_r;
	
	// *************************************
	//
	// pkt_id for output packets.
	//
	// *************************************
	reg [15:0] outpkt_id = 0;

	
	reg full_r = 0;
	assign full = full_r;

	reg [7:0] count = 0;
	
	always @(posedge CLK) begin
		if (~full & wr_en) begin
			gen_id_r <= gen_id;
			pkt_id_r <= pkt_id;
			word_id_r <= word_id;
			num_processed_r <= num_processed;
			hash_num_eq_r <= hash_num_eq;
			outpkt_type_r <= pkt_type;
			full_r <= 1;
		end

		if (full_r & rd_en_pkt) begin
			if (count == outpkt_len[8:1] + HEADER_LEN/2 - 1) begin
				count <= 0;
				full_r <= 0;
			end
			else
				count <= count + 1'b1;
		end
	end

	wire pkt_new = count == 0;
	
	wire pkt_end = count == outpkt_len[8:1] + HEADER_LEN/2 - 1;
	
	wire [15:0] pkt_dout =
		// version, type
		count == 0 ? { outpkt_type, VERSION } :
		// reserved
		count == 1 ? 16'h0 :
		// data length
		count == 2 ? outpkt_len :
		count == 3 ? 16'h0 :
		// packet id
		count == 4 ? outpkt_id :
		// packet header ends

		count == 5 ? (
			outpkt_type == OUTPKT_TYPE_CMP_EQUAL	? pkt_id_r :
			outpkt_type == OUTPKT_TYPE_PACKET_DONE ? pkt_id_r :
			{16{1'b0}}
		) :
		count == 6 ? (
			outpkt_type == OUTPKT_TYPE_CMP_EQUAL	? word_id_r :
			outpkt_type == OUTPKT_TYPE_PACKET_DONE ? num_processed_r[15:0] :
			{16{1'b0}}
		) :
		count == 7 ? (
			outpkt_type == OUTPKT_TYPE_CMP_EQUAL	? gen_id_r[15:0] :
			outpkt_type == OUTPKT_TYPE_PACKET_DONE ? num_processed_r[31:16] :
			{16{1'b0}}
		) :
		count == 8 ? (
			outpkt_type == OUTPKT_TYPE_CMP_EQUAL	? { gen_id_r[31:16] } :
			{16{1'b0}}
		) :
		count == 9 ? (
			outpkt_type == OUTPKT_TYPE_CMP_EQUAL	? { {16-(`RAM_ADDR_MSB+1){1'b0}}, hash_num_eq_r } :
			{16{1'b0}}
		) :
	{16{1'b0}};
	
	
	assign rd_en_pkt = full_r & ~full_checksum;
	assign wr_en_checksum = rd_en_pkt;

	outpkt_checksum outpkt_checksum(
		.CLK(CLK), .din(pkt_dout), .pkt_new(pkt_new), .pkt_end(pkt_end),
		.wr_en(wr_en_checksum), .full(full_checksum),
		
		.dout(dout), .rd_en(rd_en), .empty(empty)
	);
	
endmodule
