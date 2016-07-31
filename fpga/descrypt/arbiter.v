`timescale 1ns / 1ps

`include "descrypt_core/descrypt.vh"

module arbiter #(
	parameter WIDTH = 56
	)(
	input CLK, // input from generator
	input CORE_CLK, // for most of operations
	input CMP_CLK, // for core's comparator and output
	
	// read words from the generator (CLK)
	input [WIDTH-1:0] word,
	input [15:0] pkt_id, word_id,
	input [31:0] gen_id,
	input gen_end, // asserted on a last generated word in a packet
	input wr_en,
	output full, almost_full,
	
	// read comparator config (CORE_CLK)
	input [`SALT_MSB:0] salt,
	input [`RAM_ADDR_MSB-1:0] read_addr_start, addr_diff_start,
	input hash_valid, hash_end,
	input [`HASH_MSB:0] hash,
	input [`RAM_ADDR_MSB:0] hash_addr,
	input cmp_config_wr_en,
	output reg cmp_config_full = 1,
	input new_cmp_config,
	output reg cmp_config_applied = 0, // got new_cmp_config signal, started handling of config
	
	output [1:0] pkt_type_out,
	// data depends on packet type
	output reg [31:0] gen_id_out,
	output reg [15:0] pkt_id_out, word_id_out, // this pkt_id is for inclusion into packet body for reference
	output [`RAM_ADDR_MSB:0] hash_num_eq,
	output reg [31:0] num_processed_out,

	input rd_en,
	output empty,
	output [7:0] error
	);

	localparam NUM_CRYPT_INSTANCES = 16; // crypt instances per core (unchangeable in this version)
	
	localparam NUM_CORES = 24;//15;
	
	localparam NUM_WRAPPERS = 4;//2;

	// Configuration for wrappers.
	// - number of cores
	// - starting core number
	//
	localparam [NUM_WRAPPERS*16-1:0] WRAPPER_CORES = {
		8'd6, 8'd18,
		8'd6, 8'd12,
		8'd6, 8'd6,	// wrapper #1: 6 cores, starting core number 6
		8'd6, 8'd0	// wrapper #0: 6 cores, starting core number 0
	};

	// Configuration for cores
	// - extra register stages for input
	// - extra register stages for output
	//
	localparam [NUM_CORES*16-1:0] CORES_CONF = {
		// wrapper #3
		12'b0, 2'd2, 2'd2,
		12'b0, 2'd2, 2'd2,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		// wrapper #2
		12'b0, 2'd2, 2'd2,
		12'b0, 2'd2, 2'd2,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		// wrapper #1
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd1, 2'd1,
		12'b0, 2'd2, 2'd2,
		12'b0, 2'd2, 2'd2,
		// wrapper #0
		12'b0, 2'd1, 2'd1,	// core #5: 1 input register stage, 1 output
		12'b0, 2'd1, 2'd1,	// core #4: 1 input register stage, 1 output
		12'b0, 2'd1, 2'd1,	// core #3: 1 input register stage, 1 output
		12'b0, 2'd1, 2'd1,	// core #2: 1 input register stage, 1 output
		12'b0, 2'd2, 2'd2,	// core #1: 2 input register stage, 2 output
		12'b0, 2'd2, 2'd2		// core #0: 2 input register stage, 2 output
	};


	// *************************************************************

	reg err_core = 0, err_cmp = 0; // from cores
	reg err_rd_ram = 0, err_core_output = 0, err_cmp_no_conf = 0; // from arbiter itself
	assign error = {
		1'b0, 1'b0, 1'b0, err_cmp, 
		err_core, err_rd_ram, err_core_output, err_cmp_no_conf
	};

	reg error_r = 0;
	always @(posedge CORE_CLK)
		if (|error)
			error_r <= 1;
	
	
	genvar i;
	integer k;
	
	// Arbiter's Input FIFO
	// IP Coregen: FIFO
	// Block RAM, Independent clocks
	// First Word Fall-Through
	// width 144, depth 256 (use 9K BRAMs: 4)
	// reset: off
	wire [143:0] input_dout;

	arbiter_input_fifo arbiter_input_fifo (
		.wr_clk(CLK),
		.din({ {144-1-32-16-16-WIDTH{1'b0}}, gen_end, gen_id, pkt_id, word_id, word }), // input [143 : 0] din
		.wr_en(wr_en),
		.full(full),
		.almost_full(almost_full),

		.rd_clk(CORE_CLK),
		.dout(input_dout), // output [143 : 0] dout
		.rd_en(input_rd_en),
		.empty(input_empty)
	);
	
	wire gen_end_in = input_dout[WIDTH-1+16+16+32+1:WIDTH+16+16+32];
	wire [31:0] gen_id_in = input_dout[WIDTH-1+16+16+32:WIDTH+16+16];
	wire [15:0] pkt_id_in = input_dout[WIDTH-1+16+16:WIDTH+16];
	wire [15:0] word_id_in = input_dout[WIDTH-1+16:WIDTH];

	// DES crypt(3): create 64-bit binary key from ASCII
	wire [63:0] key64;
	crypt3_ascii2bin crypt3_ascii2bin( .din({ input_dout[55:0] }), .dout(key64) );
	
	// DES crypt(3): perform Permuted-choice 1
	wire [55:0] key56_pc1;
	pc1 pc1( .din(key64), .dout(key56_pc1) );


	// read from input FIFO
	assign input_rd_en = ~input_empty & ~gen_end_r & wr_state == WR_STATE_WRITE_CORE;
	
	// Input timeout
	reg [2:0] input_empty_timeout = 0;
	always @(posedge CORE_CLK)
		if (~input_empty)
			input_empty_timeout <= 0;
		else if (!(&input_empty_timeout))
			input_empty_timeout <= input_empty_timeout + 1'b1;
	
	
	reg cmp_configured = 0; // Comparator has non-empty configuration


	// **********************************
	//
	// Write cores
	//
	// **********************************
	reg [`MSB(NUM_CORES-1):0] wr_core_num = 0;
	reg [`MSB(NUM_CRYPT_INSTANCES-1):0] wr_instance_num = 0;
	reg [NUM_CORES-1:0] crypt_ready, core_idle, core_err = 0;
	reg all_cores_idle_r = 0;
	always @(posedge CORE_CLK) begin
		all_cores_idle_r <= &core_idle;
		err_core <= |core_err;
	end
	
	// It writes candidates to cores in batches.
	// Current batch_num is written to core with the batch.
	reg [`NUM_BATCHES_MSB:0] batch_num [NUM_CORES-1:0];
	reg [`NUM_BATCHES_MSB:0] batch_num_r = 0;


	//
	// Packet accounting.
	// * Limited number of packets in processing
	// * Count batches
	// * Count candidates
	//
	// Current pkt_num is written to core with the batch.
	// 
	reg gen_end_r = 0; // end of packet/generator (attached to input candidate)
	reg pkt_id_num_ok = 0; // 1: some packet is being handled, it's ID is in pkt_id_num
	reg [15:0] pkt_id_num [`NUM_PKTS-1:0];
	
	reg [`NUM_PKTS_MSB:0] pkt_num = 0; // current packet (being processed)
	reg [`PKT_BATCHES_MSB:0] pkt_num_batches [`NUM_PKTS-1:0]; // number of batches in packets
	reg [`PKT_BATCHES_MSB:0] pkt_num_batches_r = 0;
	reg [`NUM_PKTS-1:0] pkt_done = 0; // accounting for this packet is done
	reg [31:0] pkt_num_processed [`NUM_PKTS-1:0]; // number of candidates in packets
	reg [31:0] pkt_num_processed_r = 0;
	
	// There's no empty slot for packet accounting
	wire pkt_full = pkt_done [ pkt_num == `NUM_PKTS-1 ? 0 : pkt_num + 1'b1 ];
	
	reg crypt_ready_r = 0;
	always @(posedge CORE_CLK)
		crypt_ready_r <= crypt_ready[wr_core_num];
		
	localparam	WR_STATE_INIT = 0,
					//WR_STATE_INIT2 = 1,
					WR_STATE_WAIT = 2,
					WR_STATE_WRITE_CORE = 3,
					WR_STATE_START_COMPUTATION = 4,
					WR_STATE_CONFIG_SALT = 5,
					WR_STATE_CONFIG_HASH = 6,
					WR_STATE_PKT_ACCOUNT_WAIT = 7;
					
	(* FSM_EXTRACT="true", FSM_ENCODING="speed1" *)
	reg [2:0] wr_state = WR_STATE_INIT;
	
	wire wr_state_pkt_done_rd = wr_state == WR_STATE_WAIT
			| wr_state == WR_STATE_WRITE_CORE | wr_state == WR_STATE_PKT_ACCOUNT_WAIT;
			
	always @(posedge CORE_CLK) begin
		if (pkt_done_rd_sync & wr_state_pkt_done_rd)
			pkt_done[pkt_num_done_rd] <= 0;
		
		case (wr_state)
		WR_STATE_INIT: begin
			// initialize memory content
			batch_num[wr_core_num] <= batch_num_r;
			wr_core_num <= wr_core_num == NUM_CORES-1 ? {`MSB(NUM_CORES-1)+1{1'b0}} : wr_core_num + 1'b1;
			if (wr_core_num == NUM_CORES - 1)
				wr_state <= WR_STATE_WAIT;
		end
		
		WR_STATE_WAIT: begin
			gen_end_r <= 0;
			batch_num_r <= batch_num[wr_core_num];
			if (~input_empty & crypt_ready_r & ~error_r)
				wr_state <= WR_STATE_WRITE_CORE;
			
			// Store ID of a packet being accounted
			if (~pkt_id_num_ok & ~input_empty) begin
				pkt_id_num[pkt_num] <= pkt_id_in;
				pkt_id_num_ok <= 1;
			end
			
			// New comparator configuration is ready.
			// Finish processing of data from input fifo
			// and wait for all computations to finish
			// before loading new comparator configuration.
			else if (new_cmp_config & &input_empty_timeout & all_cores_idle_r) begin
				wr_state <= WR_STATE_CONFIG_SALT;
				cmp_config_applied <= 1;
			end
		end
		
		WR_STATE_WRITE_CORE: begin
			// write batch of NUM_CRYPT_INSTANCES candidates.
			// if there's no enough candidates on input, don't wait, write empty candidates
			// (that's a requirement from the core)
			if (wr_instance_num == NUM_CRYPT_INSTANCES-1) begin
				pkt_num_batches_r <= pkt_num_batches_r + 1'b1;
				wr_state <= WR_STATE_START_COMPUTATION;
			end
			wr_instance_num <= wr_instance_num + 1'b1;
			
			// For easier accounting, candidates in a batch must have same pkt_id
			// (after packet ends, add-up empty candidates)
			if (gen_end_in)
				gen_end_r <= 1;
			
			if (key_valid)
				pkt_num_processed_r <= pkt_num_processed_r + 1'b1;
			
			if (~cmp_configured)
				err_cmp_no_conf <= 1;
		end
		
		WR_STATE_START_COMPUTATION: begin
			wr_instance_num <= 0;

			wr_core_num <= wr_core_num == NUM_CORES-1 ? {`MSB(NUM_CORES-1)+1{1'b0}} : wr_core_num + 1'b1;

			batch_num[wr_core_num] <= batch_num_r == `NUM_BATCHES-1
					? {`NUM_BATCHES_MSB+1{1'b0}} : batch_num_r + 1'b1;
			
			// packet accounting - count batches
			//pkt_num_batches[pkt_num] <= pkt_num_batches[pkt_num] + 1'b1; <-- too slow
			if (gen_end_r) begin
				pkt_num_batches[pkt_num] <= pkt_num_batches_r;
				pkt_num_batches_r <= 0;
				pkt_num_processed[pkt_num] <= pkt_num_processed_r;
				pkt_num_processed_r <= 0;
				pkt_done[pkt_num] <= 1;
				if (~pkt_full) begin // start accounting a new packet
					pkt_num <= pkt_num == `NUM_PKTS-1 ? {`NUM_PKTS_MSB+1{1'b0}} : pkt_num + 1'b1;
					pkt_id_num_ok <= 0;
					wr_state <= WR_STATE_WAIT;
				end
				else
					wr_state <= WR_STATE_PKT_ACCOUNT_WAIT;
			end
			else
				wr_state <= WR_STATE_WAIT;
		end
		
		WR_STATE_CONFIG_SALT: begin
			cmp_config_applied <= 0;
			cmp_config_full <= 0;
			wr_state <= WR_STATE_CONFIG_HASH;
		end

		WR_STATE_CONFIG_HASH: begin
			if (cmp_config_wr_en & hash_end) begin
				cmp_config_full <= 1;
				cmp_configured <= 1;
				wr_state <= WR_STATE_WAIT;
			end
		end
		
		WR_STATE_PKT_ACCOUNT_WAIT: begin
			// Wait until there's a slot for packet accounting
			if (~pkt_full) begin
				pkt_num <= pkt_num == `NUM_PKTS-1 ? {`NUM_PKTS_MSB+1{1'b0}} : pkt_num + 1'b1;
				pkt_id_num_ok <= 0;
				wr_state <= WR_STATE_WAIT;
			end
		end
		endcase
	end

	wire key_valid = ~input_empty & ~gen_end_r;
	
	// Extra register stage before write to cores
	reg [`DIN_MSB:0] core_din;
	always @(posedge CORE_CLK)
		core_din <= 
			wr_state == WR_STATE_CONFIG_HASH ? { hash_valid, hash } :
			wr_state == WR_STATE_CONFIG_SALT ? { addr_diff_start, read_addr_start, salt } :
			{ key_valid, key56_pc1 };

	reg [`RAM_ADDR_MSB+1:0] core_addr_in;
	always @(posedge CORE_CLK)
		core_addr_in <=
			wr_state == WR_STATE_WRITE_CORE ? { wr_instance_num, 3'b100 } :
			wr_state == WR_STATE_START_COMPUTATION ? { pkt_num, batch_num_r, 3'b110 } :
			wr_state == WR_STATE_CONFIG_SALT ? { 3'b010 } :
			{ hash_addr, 1'b1 };

	reg [NUM_CORES-1:0] core_wr_en = 0;
	generate
	for (i=0; i < NUM_CORES; i=i+1) begin:core_wr_en_gen
		always @(posedge CORE_CLK)
			core_wr_en[i] <=
				i == wr_core_num & (wr_state == WR_STATE_WRITE_CORE | wr_state == WR_STATE_START_COMPUTATION)
				// broadcast write cmp_config to all cores
				| wr_state == WR_STATE_CONFIG_SALT | wr_state == WR_STATE_CONFIG_HASH & cmp_config_wr_en;
	end
	endgenerate


	// *******************************************************************
	//
	// While candidates are computed in cores their IDs are stored in RAM.
	// For each core, it requires NUM_CRYPT_INSTANCES * `NUM_BATCHES rows of RAM.
	//
	// *******************************************************************

	localparam RAM_WIDTH = 1 + 32 + 16;
	localparam RAM_DEPTH = NUM_CORES * `NUM_BATCHES * NUM_CRYPT_INSTANCES;//_RAM;
	localparam RAM_ADDR_MSB = `MSB(RAM_DEPTH-1);
	
	(* RAM_STYLE = "BLOCK" *)
	reg [RAM_WIDTH-1:0] ram [RAM_DEPTH-1:0];
	initial
		for (k=0; k < RAM_DEPTH; k=k+1)
			ram[k] = 0;

	wire [RAM_ADDR_MSB:0] ram_write_addr = { wr_core_num, batch_num_r, wr_instance_num };

	always @(posedge CORE_CLK)
		if (wr_state == WR_STATE_WRITE_CORE)
			ram[ram_write_addr] <= { key_valid, gen_id_in, word_id_in };


	// ***************************************
	//
	// Cores
	// Each core has NUM_CRYPT_INSTANCES
	// and processes `NUM_BATCHES in sequence
	//
	// ***************************************
	wire [NUM_CORES-1:0] crypt_ready_out, core_idle_out, core_err_out;
	
	reg [NUM_CORES-1:0] core_rd_en = 0;
	wire [NUM_CORES-1:0] core_empty;
	wire [NUM_CORES-1:0] err_cmp_out;

	// Output from cores [packed], for usage with multiplexers
	wire [`RAM_ADDR_MSB:0] core_dout [NUM_CORES-1:0];
	wire [`MSB(NUM_CRYPT_INSTANCES-1):0] dout_instance [NUM_CORES-1:0];
	wire [NUM_CORES-1:0] dout_equal;
	wire [NUM_CORES-1:0] dout_key_valid;
	wire [`NUM_BATCHES_MSB:0] dout_batch_num [NUM_CORES-1:0];
	wire [`NUM_PKTS_MSB:0] dout_pkt_num [NUM_CORES-1:0];
	wire [NUM_CORES-1:0] dout_batch_complete;


	// Flattened output from cores
	wire [NUM_CORES * (`RAM_ADDR_MSB+1) - 1 :0] core_dout_f;
	wire [NUM_CORES * (`MSB(NUM_CRYPT_INSTANCES-1)+1) - 1 :0] dout_instance_f;
	wire [NUM_CORES * (`NUM_BATCHES_MSB+1) - 1 :0] dout_batch_num_f;
	wire [NUM_CORES * (`NUM_PKTS_MSB+1) - 1 :0] dout_pkt_num_f;
	
	generate
	for (i=0; i < NUM_CORES; i=i+1) begin:core_out_gen
	
		assign core_dout[i] = core_dout_f [(i+1)*(`RAM_ADDR_MSB+1)-1 -:`RAM_ADDR_MSB+1];
		assign dout_instance[i] = dout_instance_f [(i+1)*(`MSB(NUM_CRYPT_INSTANCES-1)+1)-1 -:`MSB(NUM_CRYPT_INSTANCES-1)+1];
		assign dout_batch_num[i] = dout_batch_num_f [(i+1)*(`NUM_BATCHES_MSB+1)-1 -:`NUM_BATCHES_MSB+1];
		assign dout_pkt_num[i] = dout_pkt_num_f [(i+1)*(`NUM_PKTS_MSB+1)-1 -:`NUM_PKTS_MSB+1];
	
	end
	endgenerate
	

	// Wrappers for cores
	generate
	for (i=0; i < NUM_WRAPPERS; i=i+1) begin:wrapper_gen

		localparam START = WRAPPER_CORES [i*16+7 : i*16];
		localparam N_CORES = WRAPPER_CORES [i*16+15 : i*16+8];
		localparam END = START + N_CORES - 1;
		
		wrapper_v2 #(
			.N_CORES(N_CORES), .CORES_CONF(CORES_CONF[END*16+15 : START*16])
		) wrapper (
			.CORE_CLK(CORE_CLK), .CMP_CLK(CMP_CLK),
			.din(core_din), .addr_in(core_addr_in), // broadcast input
			
			.wr_en(core_wr_en[END:START]),
			.crypt_ready(crypt_ready_out[END:START]), .core_idle(core_idle_out[END:START]),
			.err_core(core_err_out[END:START]),

			.dout(core_dout_f [(END+1) * (`RAM_ADDR_MSB+1)-1 : START * (`RAM_ADDR_MSB+1)]),
			.dout_instance(dout_instance_f [(END+1) * (`MSB(NUM_CRYPT_INSTANCES-1)+1) -1 : START * (`MSB(NUM_CRYPT_INSTANCES-1)+1)]),
			.dout_equal(dout_equal[END:START]), .dout_key_valid(dout_key_valid[END:START]),
			.dout_batch_num(dout_batch_num_f [(END+1) * (`NUM_BATCHES_MSB+1) - 1 : START * (`NUM_BATCHES_MSB+1)]),
			.dout_pkt_num(dout_pkt_num_f [(END+1) * (`NUM_PKTS_MSB+1) - 1 : START * (`NUM_PKTS_MSB+1)]),
			.dout_batch_complete(dout_batch_complete[END:START]),
			
			.rd_en(core_rd_en[END:START]), .empty(core_empty[END:START]), .err_cmp(err_cmp_out[END:START])
		);
	end
	endgenerate
	
	always @(posedge CORE_CLK) begin
		crypt_ready <= crypt_ready_out;
		core_idle <= core_idle_out;
		core_err <= core_err_out;
	end

	
	// ***************************************
	//
	// Read cores (independently from write),
	// process core output.
	// (CMP_CLK is used)
	//
	// ***************************************
	reg [`MSB(NUM_CORES-1):0] rd_core_num = 0;
	
	//reg [`MSB(NUM_CORES-1):0] rd_core_num_r;
	reg [`RAM_ADDR_MSB:0] core_dout_r;
	reg [`MSB(NUM_CRYPT_INSTANCES-1):0] dout_instance_r;
	reg dout_equal_r = 0;
	reg dout_key_valid_r = 0;
	reg [`NUM_BATCHES_MSB:0] dout_batch_num_r;
	reg [`NUM_PKTS_MSB:0] dout_pkt_num_r = 0;
	reg dout_batch_complete_r = 0;

	wire dout_r_equality = dout_key_valid_r & dout_equal_r;

	// packet accounting (process dout_pkt_num_r from core)
	reg [`PKT_BATCHES_MSB:0] pkt_num_batches_rd [`NUM_PKTS-1:0];
	//reg [`PKT_BATCHES_MSB:0] pkt_num_batches_rd_r = 0;
	reg [`NUM_PKTS_MSB:0] pkt_num_done_rd;
	
	reg pkt_done_rd = 0;
	sync_ack sync_pkt_done_rd(
		.sig(pkt_done_rd), .wr_clk(CMP_CLK), .busy(pkt_done_rd_busy),
		.rd_clk(CORE_CLK), .out(pkt_done_rd_sync), .done(wr_state_pkt_done_rd)
	);
	
	reg key_valid_ram = 0;
	reg [31:0] gen_id_ram = 0;
	reg [15:0] word_id_ram = 0;

	localparam	RD_STATE_INIT = 0,
					RD_STATE_READ_CORE = 1,
					RD_STATE_LOOKUP0 = 2,
					RD_STATE_LOOKUP1 = 3,
					RD_STATE_OUTPUT_CMP_EQUAL = 4,
					RD_STATE_PKT_ACCOUNT = 5,
					RD_STATE_OUTPUT_PACKET_DONE = 6;
					
	(* FSM_EXTRACT="true" *)
	reg [2:0] rd_state = RD_STATE_INIT;
	
	//(* MULT_STYLE="LUT" *)
	//wire [RAM_ADDR_MSB:0] ram_read_addr =
	//	rd_core_num * `NUM_BATCHES * NUM_CRYPT_INSTANCES//_RAM
	//	+ dout_batch_num_r * NUM_CRYPT_INSTANCES//_RAM
	//	+ dout_instance_r;
	wire [RAM_ADDR_MSB:0] ram_read_addr = { rd_core_num, dout_batch_num_r, dout_instance_r };
	
	always @(posedge CMP_CLK)
		if (dout_r_equality & rd_state == RD_STATE_LOOKUP0)
			{key_valid_ram, gen_id_ram, word_id_ram} <= ram[ram_read_addr];


	always @(posedge CMP_CLK) begin
		case(rd_state)
		RD_STATE_INIT: begin
			pkt_num_batches_rd[dout_pkt_num_r] <= 0;
			if (dout_pkt_num_r == `NUM_PKTS - 1)
				rd_state <= RD_STATE_READ_CORE;
			else
				dout_pkt_num_r <= dout_pkt_num_r + 1'b1;
		end
		
		RD_STATE_READ_CORE: begin
			if (error_r) begin
			end
			else if (core_empty[rd_core_num]) begin
				if (rd_core_num == NUM_CORES-1)
					rd_core_num <= 0;
				else
					rd_core_num <= rd_core_num + 1'b1;
			end
			else begin
				// Register output from the core.
				//
				// There's 1-deep output register in each core. It contains
				// an equality result or/and a batch_complete result.
				//rd_core_num_r <= rd_core_num;
				
				core_dout_r <= core_dout[rd_core_num];
				dout_instance_r <= dout_instance[rd_core_num];
				dout_equal_r <= dout_equal[rd_core_num];
				dout_key_valid_r <= dout_key_valid[rd_core_num];
				dout_batch_num_r <= dout_batch_num[rd_core_num];
				dout_pkt_num_r <= dout_pkt_num[rd_core_num];
				dout_batch_complete_r <= dout_batch_complete[rd_core_num];

				rd_state <= RD_STATE_LOOKUP0;
			end
		end
		
		// if dout_r_equality, get IDs from RAM
		RD_STATE_LOOKUP0: begin
			core_rd_en[rd_core_num] <= 1; // read delayed until RAM lookup
			pkt_id_out <= pkt_id_num[dout_pkt_num_r];
			if (dout_r_equality)
				rd_state <= RD_STATE_LOOKUP1;
			else
				rd_state <= RD_STATE_PKT_ACCOUNT;//RD_STATE_OUTPUT_PACKET_DONE;
		end
		
		// RAM output available
		RD_STATE_LOOKUP1: begin
			core_rd_en[rd_core_num] <= 0;

			gen_id_out <= gen_id_ram;
			word_id_out <= word_id_ram;
			
			rd_state <= RD_STATE_OUTPUT_CMP_EQUAL;
		end
		
		RD_STATE_OUTPUT_CMP_EQUAL: begin
			if (rd_en & ~empty) begin
				if (dout_batch_complete_r)
					rd_state <= RD_STATE_PKT_ACCOUNT;
				else
					rd_state <= RD_STATE_READ_CORE;
			end
		end
		
		RD_STATE_PKT_ACCOUNT: begin
			core_rd_en[rd_core_num] <= 0;
			
			if (pkt_num_batches[dout_pkt_num_r] == pkt_num_batches_rd[dout_pkt_num_r] + 1'b1
					& pkt_done[dout_pkt_num_r] ) begin
				// got last batch of the packet
				pkt_num_done_rd <= dout_pkt_num_r;
				pkt_done_rd <= 1;
				pkt_num_batches_rd[dout_pkt_num_r] <= 0;
				num_processed_out <= pkt_num_processed[dout_pkt_num_r];
				rd_state <= RD_STATE_OUTPUT_PACKET_DONE;
			end
			else begin
				// continue packet accounting
				pkt_num_batches_rd[dout_pkt_num_r] <= pkt_num_batches_rd[dout_pkt_num_r] + 1'b1;
				rd_state <= RD_STATE_READ_CORE;
			end
		end
		
		RD_STATE_OUTPUT_PACKET_DONE: begin
			pkt_done_rd <= 0;
			if (pkt_done_rd_busy) begin // delay until synchronization complete
			end
			else if (rd_en & ~empty)
				rd_state <= RD_STATE_READ_CORE;
		end
		endcase
	end


	// ***************************************
	//
	// Output core results.
	//
	// ***************************************

	assign empty = error_r | ~(
		dout_r_equality & rd_state == RD_STATE_OUTPUT_CMP_EQUAL
		| dout_batch_complete_r & rd_state == RD_STATE_OUTPUT_PACKET_DONE & ~pkt_done_rd_busy
	);

	assign pkt_type_out =
		rd_state == RD_STATE_OUTPUT_CMP_EQUAL		? 2'b01 :
		rd_state == RD_STATE_OUTPUT_PACKET_DONE	? 2'b10 :
	2'b0;
	
	assign hash_num_eq = core_dout_r;
	
	always @(posedge CMP_CLK) begin
		// error signal from comparator
		if (|err_cmp_out)
			err_cmp <= 1;
		// bad output from core 
		if (rd_state == RD_STATE_LOOKUP0 & ~(dout_batch_complete_r | dout_r_equality))
			err_core_output <= 1;
		// error in RAM content (or core output)
		if (rd_state == RD_STATE_LOOKUP1 & ~key_valid_ram)
			err_rd_ram <= 1;
	end

	
endmodule
