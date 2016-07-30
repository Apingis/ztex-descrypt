//`ifndef WORD_GEN_VH

// Extra stage suggested if BRAM is used.
localparam EXTRA_REGISTER_STAGE = 1;

localparam	OP_STATE_READY = 0,
				OP_STATE_START = 1,
				OP_STATE_EXTRA_STAGE = 2,
				OP_STATE_NEXT_CHAR = 3,
				OP_STATE_NEXT_WORD = 4,
				OP_STATE_DONE = 5;
				

//`define WORD_GEN_VH 
//`endif
