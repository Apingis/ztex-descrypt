`timescale 1ns / 1ps

module word_shift #(
	parameter CHAR_BITS = 7,
	parameter WORD_MAX_LEN = 8
	)(
	input [WORD_MAX_LEN * CHAR_BITS - 1 :0] din,
	input [`MSB(WORD_MAX_LEN-1):0] pos,
	output [WORD_MAX_LEN * CHAR_BITS - 1 :0] dout
	);


	wire [WORD_MAX_LEN * CHAR_BITS - 1 :0] shifts [WORD_MAX_LEN-1:0];

	genvar i;

	generate
	for (i=0; i < WORD_MAX_LEN; i=i+1)
	begin: shifts_gen
	
		assign shifts[i] = { din[(WORD_MAX_LEN-i) * CHAR_BITS - 1 :0], {i*CHAR_BITS{1'b0}} };
	
	end
	endgenerate
	
	assign dout = shifts[pos];

endmodule
