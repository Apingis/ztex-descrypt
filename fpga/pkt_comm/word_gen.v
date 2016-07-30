`timescale 1ns / 1ps

//**********************************************************************
//
// Word Generator
// http://github.com/Apingis
//
// * Words are produced every cycle (as long as reader is not full).
// * Delay when getting a new word from word_list:
//		1 cycle if start_idx's not used, 3 if used.
// * There's a delay when it loads a new configuration for word generator,
// 	equal to number of bytes in configuration at CLK frequency
// 	plus few more cycles.
//
// Possible TODO:
// * Let it load next configuration while it generates with current configuration,
//		thus eliminating delay when it switches configurations.
// * Eliminate delay when getting a new word from word_list.
//
// Alternatively:
// * Utilize both RAM access ports for generation, thus halving RAM usage.
//
//**********************************************************************

module word_gen #(
	parameter CHAR_BITS = 7, // valid values: 7 8
	parameter RANGES_MAX = 8,
	parameter WORD_MAX_LEN = RANGES_MAX,
	parameter WORDS_INSERT_MAX = 1
	)(
	input CLK, // configuration clock
	// Word generator configuration.
	input [7:0] din,
	input [15:0] inpkt_id,
	input wr_conf_en,
	output conf_full,

	input WORD_GEN_CLK, // clock for running word_list input, generation and output
	// If num_words!=0, it take input words
	// and use them to generate output.
	// Accepts 1 packet of type word_list then finishes.
	input [WORD_MAX_LEN * CHAR_BITS - 1 :0] word_in,
	input [`MSB(WORD_MAX_LEN):0] word_len,
	input [15:0] word_id,
	input word_list_end,
	input word_wr_en,
	output reg word_full = 0,

	input rd_en,
	output empty,
	output [WORD_MAX_LEN * CHAR_BITS - 1 :0] dout,
	output reg [15:0] pkt_id,
	output [15:0] word_id_out,
	// Number of generated word (resets on each inserted word if num_words!=0)
	//(* USE_DSP48="true" *) <-- Saves LUTs but it's too slow for 240 MHz
	output reg [31:0] gen_id = 0,
	output gen_end, // asserts on last generated word
	
	output reg err_word_gen_conf = 0
	);

	
	reg conf_done = 0;
	assign conf_full = state == CONF_ERROR | state == CONF_DONE;

	// Max. number of chars in range
	localparam CHARS_NUMBER_MAX = CHAR_BITS == 7 ? 96 : 224;
	
	localparam NUM_RANGES_MSB = `MSB(RANGES_MAX);
	localparam NUM_CHARS_MSB = `MSB(CHARS_NUMBER_MAX);
	localparam NUM_WORDS_MSB = `MSB(WORDS_INSERT_MAX);
	
	//reg [NUM_RANGES_MSB:0] num_ranges = 0;
	reg [NUM_RANGES_MSB:0] last_range_num;
	reg [NUM_RANGES_MSB:0] conf_range_count;

	//reg [NUM_CHARS_MSB:0] conf_num_chars;
	reg [NUM_CHARS_MSB:0] conf_last_char_num;
	reg [NUM_CHARS_MSB:0] conf_chars_count;
	
	reg [NUM_WORDS_MSB:0] num_words = 0;
	reg [NUM_WORDS_MSB:0] conf_words_count;
	reg [`MSB(WORD_MAX_LEN-1):0] word_insert_pos [NUM_WORDS_MSB:0];
	reg used_start_idx = 0;
	
	// ID for generated output
	reg gen_limit = 0;	// there's a limit
	reg gen_limit1 = 0;	// limit equals to 1
	reg gen_limit2 = 0;
	reg gen_limit_reached = 0;
	reg [31:0] gen_id_max = 0;

	assign conf_en_num_chars = state == CONF_RANGE_NUM_CHARS;
	assign conf_en_start_idx = state == CONF_RANGE_START_IDX;
	assign conf_en_chars = state == CONF_RANGE_CHARS;

	wire [RANGES_MAX * CHAR_BITS - 1:0] range_dout;
	
	wire range_rd_en;
	wire carry_in [RANGES_MAX-1:0];
	wire carry [RANGES_MAX-1:0];
	wire carry_out [RANGES_MAX-1:0];
	reg op_done = 0;

	sync_short_sig #(.CLK1(1)) sync_op_done (.sig(op_done), .clk(CLK), .out(op_done_sync) );


	`include "word_gen.vh"

	(* FSM_EXTRACT = "true", FSM_ENCODING = "speed1" *)
	reg [2:0] op_state = OP_STATE_DONE;
	
	genvar i;
	generate
	for (i=0; i < RANGES_MAX; i=i+1)
	begin:char_ranges
	
		assign range_conf_en = i == conf_range_count;
		assign carry_in[i] = i == RANGES_MAX-1 ? 1'b1 : carry_out[i+1];
		assign carry_out[i] = carry_in[i] & carry[i];
		
		//(* KEEP_HIERARCHY="true" *)
		word_gen_char_range #(
			.CHAR_BITS(CHAR_BITS), .CHARS_NUMBER_MAX(CHARS_NUMBER_MAX)
		) word_gen_char_range(
			.CONF_CLK(CLK),
			.din(din[CHAR_BITS-1:0]),
			.conf_en_num_chars(range_conf_en & conf_en_num_chars),
			.num_chars_eq0(din[NUM_CHARS_MSB:0] == 0), .num_chars_lt2(din[NUM_CHARS_MSB:0] < 2),
			
			.conf_en_start_idx(range_conf_en & conf_en_start_idx),
			.conf_en_chars(range_conf_en & conf_en_chars), .conf_char_addr(conf_chars_count),
			.pre_end_char(conf_chars_count + 1'b1 == conf_last_char_num),
			
			.OP_CLK(WORD_GEN_CLK),
			.op_en(range_rd_en), .op_state(op_state), .op_done_sync(op_done_sync),
			.carry_in(carry_in[i]), .carry(carry[i]),
			.dout(range_dout[(i+1)*CHAR_BITS-1 -:CHAR_BITS])
		);
		
	end
	endgenerate


	// *******************************************************************
	//
	// Operation
	//
	// *******************************************************************

	wire word_insert_mode = num_words != 0;
	// for now, it allows no more than 1 word_insert
	wire [`MSB(WORD_MAX_LEN-1):0] word_pos = word_insert_pos[0];

	// input from word_list
	reg [`MSB(WORD_MAX_LEN):0] word_len_r;
	reg [15:0] word_id_r;
	reg word_list_end_r = 0;

	wire [WORD_MAX_LEN * CHAR_BITS - 1 :0] word_in_shifted;

	word_shift #(
		.CHAR_BITS(CHAR_BITS), .WORD_MAX_LEN(WORD_MAX_LEN)
	) word_shift(
		.din(word_in), .pos(word_pos), .dout(word_in_shifted)
	);

	reg [WORD_MAX_LEN * CHAR_BITS - 1 :0] word_in_shifted_r;
	//wire [WORD_MAX_LEN * CHAR_BITS - 1 :0] word_insert_dout;
	
	word_insert #(
		.CHAR_BITS(CHAR_BITS), .RANGES_MAX(RANGES_MAX), .WORD_MAX_LEN(WORD_MAX_LEN)
	) word_insert(
		.range_dout(range_dout),
		.word_in(word_in_shifted_r),
		.word_len(word_len_r),
		.word_pos(word_pos),
		.dout(dout)
	);
	//assign dout=range_dout;
	assign word_id_out = word_id_r;
	
	always @(posedge WORD_GEN_CLK) begin
		begin
			if (~word_insert_mode) begin
				word_len_r <= 0;
				word_id_r <= 0;
			end
				
			if (word_insert_mode & ~word_full & word_wr_en) begin
				word_full <= 1;
				word_in_shifted_r <= word_in_shifted;
				word_len_r <= word_len;
				word_id_r <= word_id;
				word_list_end_r <= word_list_end;
			end

			case (op_state)
			OP_STATE_READY: begin
				// Ranges configured, ready for operation
				if (conf_done_sync) begin
					op_state <= OP_STATE_START;
				end
			end
			
			OP_STATE_START: begin
				if (EXTRA_REGISTER_STAGE)
					op_state <= OP_STATE_EXTRA_STAGE;
				else
					op_state <= OP_STATE_NEXT_CHAR;
			end
			
			OP_STATE_EXTRA_STAGE: begin
				op_state <= OP_STATE_NEXT_CHAR;
			end
			
			OP_STATE_NEXT_CHAR: begin // set next output word
				if (range_rd_en) begin
					if (carry_out[0] | gen_limit_reached) begin
						
						// Generation for current config ends.
						if (~word_insert_mode) begin
							op_done <= 1;
							op_state <= OP_STATE_DONE;
						end

						// Generation for current word ends.
						else begin
							word_full <= 0;
							if (word_list_end_r) begin
								op_done <= 1;
								op_state <= OP_STATE_DONE;
							end
							// requires reload of start_idx
							else if (used_start_idx | gen_limit_reached) begin
								op_state <= OP_STATE_NEXT_WORD;
							end
							// no reload of start_idx - continue with next word
						end

					end
				end // range_rd_en
			end

			OP_STATE_NEXT_WORD: begin
				op_state <= OP_STATE_START;
			end
			
			OP_STATE_DONE: begin // reset configuration
				op_done <= 0;
				op_state <= OP_STATE_READY;
			end
			endcase

		end 
	end

	assign range_rd_en = rd_en & ~empty;

	assign empty = ~(
		op_state == OP_STATE_NEXT_CHAR & (word_insert_mode & word_full | ~word_insert_mode)
	);

	assign gen_end =
		op_state == OP_STATE_NEXT_CHAR
		& (carry_out[0] | gen_limit_reached)
		& (word_insert_mode & word_list_end_r | ~word_insert_mode);
	
	// requires speed optimization so the result from 32-bit comparator is computed on previous cycle.
	always @(posedge WORD_GEN_CLK) begin
		if (op_state == OP_STATE_READY | op_state == OP_STATE_NEXT_WORD) begin
			gen_id <= 0;
			gen_limit_reached <= gen_limit1;
		end
		else if (range_rd_en) begin
			gen_id <= gen_id + 1'b1;
			if (gen_limit2)
				gen_limit_reached <= 1;
			else
				gen_limit_reached <= gen_limit && gen_id == gen_id_max;
		end
	end
	

	// *******************************************************************
	//
	// Configuration (word_gen.h)
	//
	// struct word_gen_char_range {
	//		unsigned char num_chars;		// number of chars in range
	//		unsigned char start_idx;		// index of char to start iteration
	//		unsigned char chars[CHAR_BITS==7 ? 96 : 224]; // only chars_number transmitted
	//	};
	// range must have at least 1 char
	//
	// struct word_gen {
	//		unsigned char num_ranges;
	//		struct word_gen_char_range ranges[RANGES_MAX]; // only num_ranges transmitted
	//		unsigned char num_words;
	//		unsigned char word_insert_pos[WORDS_INSERT_MAX]; // only num_words transmitted
	//		unsigned long num_generate;
	//		unsigned char magic;	// 0xBB
	//	};
	//
	// example word generator (words pass-by):
	// {
	// 0,		// num_ranges
	// 1,		// num_words
	// 0,		// word_insert_pos
	// 0,		// no limit
	// 0xBB
	// };
	//
	// *******************************************************************

	localparam	CONF_NUM_RANGES = 1,
					CONF_RANGE_NUM_CHARS = 2,
					CONF_RANGE_START_IDX = 3,
					CONF_RANGE_CHARS = 4,
					CONF_NUM_WORDS = 5,
					CONF_WORD_INSERT_POS = 6,
					CONF_NUM_GENERATE0 = 7,
					CONF_NUM_GENERATE1 = 8,
					CONF_NUM_GENERATE2 = 9,
					CONF_NUM_GENERATE3 = 10,
					CONF_MAGIC = 11,
					CONF_DONE = 12,
					CONF_ERROR = 13;
	
	(* FSM_EXTRACT = "true" *)
	reg [3:0] state = CONF_NUM_RANGES;
	
	always @(posedge CLK) begin
		if (state == CONF_DONE) begin
			conf_done <= 0;
			if (op_done_sync) begin
				//num_ranges <= 0;
				num_words <= 0;
				used_start_idx <= 0;
				state <= CONF_NUM_RANGES;
			end
		end
		
		else if (state == CONF_ERROR)
			err_word_gen_conf <= 1;

		else if (wr_conf_en) begin
			case (state)
			CONF_NUM_RANGES: begin
				pkt_id <= inpkt_id;
				//num_ranges <= din[NUM_RANGES_MSB:0];
				last_range_num <= din[NUM_RANGES_MSB:0] - 1'b1;
				conf_range_count <= 0;
				// Num. of ranges exceeds RANGES_MAX
				if ( din > RANGES_MAX )
					state <= CONF_ERROR;
				else if ( din[NUM_RANGES_MSB:0] )
					state <= CONF_RANGE_NUM_CHARS;
				else
					state <= CONF_NUM_WORDS;
			end
			
			CONF_RANGE_NUM_CHARS: begin
				//conf_num_chars <= din[NUM_CHARS_MSB:0];
				conf_last_char_num <= din[NUM_CHARS_MSB:0] - 1'b1;
				conf_chars_count <= 0;
				// Wrong number of chars in range
				if (!din || din > CHARS_NUMBER_MAX)
					state <= CONF_ERROR;
				else
					state <= CONF_RANGE_START_IDX;
			end
			
			CONF_RANGE_START_IDX: begin
				if (din[NUM_CHARS_MSB:0])
					used_start_idx <= 1;
				state <= CONF_RANGE_CHARS;
			end
			
			CONF_RANGE_CHARS: begin
				conf_chars_count <= conf_chars_count + 1'b1;
				//if (conf_chars_count + 1'b1 == conf_num_chars) begin
				if (conf_chars_count == conf_last_char_num) begin
					conf_range_count <= conf_range_count + 1'b1;
					//if (conf_range_count + 1'b1 == num_ranges)
					if (conf_range_count == last_range_num)
						state <= CONF_NUM_WORDS;
					else
						state <= CONF_RANGE_NUM_CHARS;
				end
			end
			
			CONF_NUM_WORDS: begin
				conf_words_count <= 0;
				num_words <= din[NUM_WORDS_MSB:0];
				//if ( din > 1 || (!din[NUM_WORDS_MSB:0] && !num_ranges) )
				if ( din > 1 || (!din[NUM_WORDS_MSB:0] && &last_range_num) )
					// Number of inserted words exceeds 1
					state <= CONF_ERROR;
				else 
				if ( din[NUM_WORDS_MSB:0] )
					state <= CONF_WORD_INSERT_POS;
				else
					state <= CONF_NUM_GENERATE0;
			end
			
			CONF_WORD_INSERT_POS: begin
				word_insert_pos[conf_words_count] <= din[`MSB(WORD_MAX_LEN-1):0];
				conf_words_count <= conf_words_count + 1'b1;
				if (conf_words_count + 1'b1 == num_words)
					state <= CONF_NUM_GENERATE0;
			end
			
			CONF_NUM_GENERATE0: begin
				gen_id_max[7:0] <= din;
				state <= CONF_NUM_GENERATE1;
			end
			
			CONF_NUM_GENERATE1: begin
				gen_id_max[15:8] <= din;
				state <= CONF_NUM_GENERATE2;
			end
			
			CONF_NUM_GENERATE2: begin
				gen_id_max[23:16] <= din;
				state <= CONF_NUM_GENERATE3;
			end
			
			CONF_NUM_GENERATE3: begin
				gen_id_max <= { din, gen_id_max[23:0] } - 2;
				gen_limit <= { din, gen_id_max[23:0] } != 0;
				gen_limit1 <= { din, gen_id_max[23:0] } == 1;
				gen_limit2 <= { din, gen_id_max[23:0] } == 2;
				state <= CONF_MAGIC;
			end
			
			CONF_MAGIC: begin
				if (din == 8'hBB) begin
					conf_done <= 1;
					state <= CONF_DONE;
				end
				else
					state <= CONF_ERROR;
			end
			
			endcase
		end
		
	end

	sync_sig sync_conf_done(.sig(conf_done), .clk(WORD_GEN_CLK), .out(conf_done_sync));

endmodule
