`timescale 1ns / 1ps

//
// Process incoming ASCII words (\0 terminated) char by char.
//
module word_list #(
	parameter CHAR_BITS = 7,
	parameter WORD_MAX_LEN = 8
	)(
	input wr_clk,	
	input [7:0] din,
	input wr_en,
	output full,
	input inpkt_end,

	input rd_clk,
	output [WORD_MAX_LEN*CHAR_BITS-1:0] dout,
	output [`MSB(WORD_MAX_LEN):0] word_len, // 4 bits if max.len==8 
	output [15:0] word_id,
	output word_list_end,
	input rd_en,
	output empty,
	
	output reg err_word_list_len = 0, err_word_list_count = 0
	);
	
	reg full_r = 0;
	assign full = full_r;
	
	reg [WORD_MAX_LEN*CHAR_BITS-1:0] dout_r = { WORD_MAX_LEN*CHAR_BITS {1'b0}};
	
	reg [15:0] word_id_r = 0;
	
	reg word_list_end_r = 0;
	
	reg [`MSB(WORD_MAX_LEN):0] char_count = 0;


	always @(posedge wr_clk) begin
		if (~full_r & wr_en) begin
			if ( !din && !char_count ) begin
				// extra \0 or empty word - skip
			end
			else if (!din) begin
				// word ends
				full_r <= 1;
			end
			else begin
				if (char_count == WORD_MAX_LEN) begin
					// word exceeds max.length; extra chars skipped
					err_word_list_len <= 1;
				end
				else begin
					dout_r[(char_count + 1'b1)*CHAR_BITS-1 -:CHAR_BITS] <= din[CHAR_BITS-1:0];
					char_count <= char_count + 1'b1;
				end
			end

			if (inpkt_end) begin
				word_list_end_r <= 1;
				// packet ends and last word not terminated with '\0' - let it go
				full_r <= 1;
			end
		end // ~full & wr_en
		
		else if (full_r & rd_en_internal) begin
			full_r <= 0;
			dout_r <= { WORD_MAX_LEN*CHAR_BITS {1'b0}};
			char_count <= 0;
			word_list_end_r <= 0;
			if (word_list_end_r)
				word_id_r <= 0;
			else
				word_id_r <= word_id_r + 1'b1;

			if ( ~|(word_id_r + 1'b1) )
				// word_id_r overflows
				err_word_list_count <= 1;
		end
	end

	assign rd_en_internal = full_r & ~output_reg_full;

	cdc_reg #( .WIDTH(WORD_MAX_LEN*CHAR_BITS + `MSB(WORD_MAX_LEN)+1 + 16 + 1)
	) output_reg (
		.wr_clk(wr_clk),
		.din({ dout_r, char_count, word_id_r, word_list_end_r }),
		.wr_en(rd_en_internal), .full(output_reg_full),
		
		.rd_clk(rd_clk),
		.dout({ dout, word_len, word_id, word_list_end }),
		.rd_en(rd_en), .empty(empty)
	);

endmodule

