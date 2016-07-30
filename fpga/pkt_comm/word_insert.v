`timescale 1ns / 1ps

// There's a result from word generator in 'range_dout'
// 1. insert word (length='word_len') at position 'word_pos'
//  - if !word_len, pass-by input from word generator
// 2. pad empty chars with 0's up to WORD_MAX_LEN
//
module word_insert #(
	parameter CHAR_BITS = 7,
	parameter RANGES_MAX = 8,
	parameter WORD_MAX_LEN = RANGES_MAX,
	parameter WORDS_INSERT_MAX = 1,
	parameter WORD_LEN_MSB = `MSB(WORD_MAX_LEN)
	)(
	input [RANGES_MAX * CHAR_BITS - 1 :0] range_dout,
	input [WORD_MAX_LEN * CHAR_BITS - 1 :0] word_in,
	input [WORD_LEN_MSB:0] word_len,
	input [`MSB(WORD_MAX_LEN-1):0] word_pos,
	output [WORD_MAX_LEN * CHAR_BITS - 1 :0] dout
	);
	
	localparam WORD_LEN_NBITS = WORD_LEN_MSB + 1;
	

	wire [WORD_MAX_LEN * CHAR_BITS - 1 :0] shifts [WORD_MAX_LEN-1:0];

	genvar i;

	generate
	for (i=0; i < WORD_MAX_LEN; i=i+1)
	begin: shifts_gen
	
		assign shifts[i] =
			{ range_dout[(WORD_MAX_LEN-i) * CHAR_BITS - 1 :0], {i*CHAR_BITS{1'b0}} };
	
	end
	endgenerate
	
	// if result char to be taken from some range
	//wire [WORD_MAX_LEN-1:0] if_range;
	wire [WORD_MAX_LEN-1:0] if_range_pass_by;
	wire [WORD_MAX_LEN-1:0] if_range_shift;

	// if result char to be taken from inserted word
	wire [WORD_MAX_LEN-1:0] if_word;

	generate
	for (i=0; i < WORD_MAX_LEN; i=i+1)
	begin: if_range_gen
	
		//assign if_range[i] = word_pos > i || word_pos + word_len <= i;
		assign if_range_pass_by[i] = !word_len || word_pos > i;
		assign if_range_shift[i] = word_pos + word_len <= i;

		assign if_word[i] = word_pos <= i && word_pos + word_len > i;

	end
	endgenerate


	generate
	for (i=0; i < WORD_MAX_LEN; i=i+1)
	begin: dout_gen

		assign dout [(i+1)*CHAR_BITS-1 -:CHAR_BITS] = 
			
			if_range_pass_by[i] ? range_dout[(i+1)*CHAR_BITS-1 -:CHAR_BITS] :
			//if_word[i]	? word_in[(i+1)*CHAR_BITS-1 -:CHAR_BITS] :
			
			if_range_shift[i]	? shifts[word_len][(i+1)*CHAR_BITS-1 -:CHAR_BITS] :
			
			//range_dout[(i+1)*CHAR_BITS-1 -:CHAR_BITS];
			word_in[(i+1)*CHAR_BITS-1 -:CHAR_BITS];
				
	end
	endgenerate


endmodule
