`timescale 1ns / 1ps

`include "../descrypt/descrypt_core/descrypt.vh"

// *********************************************************
//
// Packet-Based Communication for FPGA Application
//
// Host Software sends data:
// * to different subsystems of FPGA application
// * in sequential packets
//
// see pkt_comm.h for packet format
//
// Naming: in*, out* from the point of view from FPGA application
//
// *********************************************************

module pkt_comm_arbiter #(
	parameter VERSION = 1,
	parameter PKT_MAX_LEN = 16*65536,
	parameter PKT_LEN_MSB = `MSB(PKT_MAX_LEN),
	parameter DISABLE_CHECKSUM = 0
	)(
	input CLK,
	input WORD_GEN_CLK,
	input CORE_CLK,
	input CMP_CLK,

	// read from some internal FIFO (recieved via high-speed interface)
	input [7:0] din,
	output rd_en,
	input empty,

	// write into some internal FIFO (to be send via high-speed interface)
	//output [63:0] dout,
	output [15:0] dout,
	output wr_en,
	input full,
	
	// control input (VCR interface)
	input [7:0] app_mode,
	// status output (VCR interface)
	output [7:0] app_status,
	output [7:0] pkt_comm_status,
	output [7:0] debug2
	);
	

	assign debug2 = app_mode; // save 2 warnings

	localparam DISABLE_TEST_MODES_0_AND_1 = 0;

	//assign rd_en = inpkt_rd_en;
	//assign wr_en = output_fifo_wr_en;
	//assign dout = dout_mode2;
		
	// **************************************************
	//
	// Application modes 0 & 1: send back what received
	// used by simple_test.c and test.c
	//
	// **************************************************
	//assign dout = din;

	// convert 8-bit to 16-bit
	reg [15:0] dout_app_mode01;
	reg dout_app_mode01_ready = 0;
	reg counter = 0;

	assign rd_en =
		DISABLE_TEST_MODES_0_AND_1 | app_mode==2 || app_mode==3 ? inpkt_rd_en :
		app_mode==0 || app_mode==1 ? ~empty & ~full :
		1'b0;
		
	assign wr_en =
		DISABLE_TEST_MODES_0_AND_1 | app_mode==2 ? output_fifo_wr_en :
		app_mode==0 || app_mode==1 ? dout_app_mode01_ready :
		//app_mode==3 ?
		1'b0;
	
	assign dout =
		DISABLE_TEST_MODES_0_AND_1 | app_mode==2 ? dout_app_mode2 :
		app_mode==0 || app_mode==1 ? dout_app_mode01 :
		//app_mode==3 ? 
		16'b0;//64'b0;
		
	if (!DISABLE_TEST_MODES_0_AND_1) begin

		always @(posedge CLK) begin
			if (counter == 0) begin
				dout_app_mode01_ready <= 0;
			end
			if (rd_en && (app_mode == 8'h00 || app_mode == 8'h01) ) begin
				if (counter == 0) begin
					dout_app_mode01[7:0] <= din;
				end
				else if (counter == 1) begin
					dout_app_mode01[15:8] <= din;
					dout_app_mode01_ready <= 1;
				end
				counter <= counter + 1'b1;
			end
		end // CLK

	end // !DISABLE_TEST_MODES_0_AND_1


	assign pkt_comm_status = {
		err_cmp_config, err_word_gen_conf, err_word_list_len, err_word_list_count,
		err_pkt_version, err_inpkt_type, err_inpkt_len, err_inpkt_checksum
	};	


	// **************************************************
	//
	// Application mode 2 & 3: read packets
	// process data base on packet type
	//
	// **************************************************

	localparam PKT_TYPE_WORD_LIST = 1;
	localparam PKT_TYPE_WORD_GEN = 2;
	localparam PKT_TYPE_CMP_CONFIG = 3;

	localparam PKT_MAX_TYPE = 3;

	reg error = 0;
	always @(posedge CLK)
		error <= inpkt_err | err_cmp_config | err_word_gen_conf | err_word_list_len
					| err_word_list_count;	

	wire [`MSB(PKT_MAX_TYPE):0] inpkt_type;
	wire [15:0] inpkt_id;
	
	inpkt_header #(
		.VERSION(VERSION),
		.PKT_MAX_LEN(PKT_MAX_LEN),
		.PKT_MAX_TYPE(PKT_MAX_TYPE),
		.DISABLE_CHECKSUM(DISABLE_CHECKSUM)
	) inpkt_header(
		.CLK(CLK), 
		.din(din), 
		.wr_en(inpkt_rd_en),
		.pkt_type(inpkt_type), .pkt_id(inpkt_id), .pkt_data(inpkt_data),
		.pkt_end(inpkt_end), .pkt_err(inpkt_err),
		.err_pkt_version(err_pkt_version), .err_pkt_type(err_inpkt_type),
		.err_pkt_len(err_inpkt_len), .err_pkt_checksum(err_inpkt_checksum)
	);

	// input packet processing: read enable
	assign inpkt_rd_en = ~empty & ~error
			& (~inpkt_data | word_gen_conf_en | word_list_wr_en | cmp_config_wr_en);


	localparam WORD_MAX_LEN = 8;
	localparam CHAR_BITS = 7;
	localparam RANGES_MAX = 8;


	// **************************************************
	//
	// input packet type WORD_LIST (0x01)
	//
	// **************************************************
	wire word_list_wr_en = ~empty & ~error
			& inpkt_type == PKT_TYPE_WORD_LIST & inpkt_data & ~word_list_full;

	wire [WORD_MAX_LEN * CHAR_BITS - 1:0] word_list_dout;
	wire [`MSB(WORD_MAX_LEN):0] word_len;
	wire [15:0] word_id;

	word_list #(
		.CHAR_BITS(CHAR_BITS), .WORD_MAX_LEN(WORD_MAX_LEN)
	) word_list(
		.wr_clk(CLK), .din(din), 
		.wr_en(word_list_wr_en), .full(word_list_full), .inpkt_end(inpkt_end),

		.rd_clk(WORD_GEN_CLK),
		.dout(word_list_dout), .word_len(word_len), .word_id(word_id), .word_list_end(word_list_end),
		.rd_en(word_list_rd_en), .empty(word_list_empty),
		
		.err_word_list_len(err_word_list_len), .err_word_list_count(err_word_list_count)
	);

	
	// **************************************************
	//
	// input packet type WORD_GEN (0x02)
	//
	// **************************************************
	wire word_gen_conf_en = ~empty & ~error
			& inpkt_type == PKT_TYPE_WORD_GEN & inpkt_data & ~word_gen_conf_full;

	wire word_wr_en = ~word_list_empty & ~word_full;
	assign word_list_rd_en = word_wr_en;
	
	wire [WORD_MAX_LEN * CHAR_BITS - 1:0] word_gen_dout;
	wire [15:0] pkt_id, word_id_out;
	wire [31:0] gen_id;

	word_gen #(
		.CHAR_BITS(CHAR_BITS), .RANGES_MAX(RANGES_MAX), .WORD_MAX_LEN(WORD_MAX_LEN)
	) word_gen(
		.CLK(CLK),
		.din(din), 
		.inpkt_id(inpkt_id), .wr_conf_en(word_gen_conf_en), .conf_full(word_gen_conf_full),
		
		.WORD_GEN_CLK(WORD_GEN_CLK),
		.word_in(word_list_dout), .word_len(word_len), .word_id(word_id), .word_list_end(word_list_end),
		.word_wr_en(word_wr_en), .word_full(word_full),
		
		.rd_en(word_gen_rd_en), .empty(word_gen_empty),
		.dout(word_gen_dout), .pkt_id(pkt_id), .word_id_out(word_id_out), .gen_id(gen_id), .gen_end(gen_end),
		
		.err_word_gen_conf(err_word_gen_conf)
	);
	//
	// OK. Got words along with ID's.
	//
	//wire [32 + 16 + WORD_MAX_LEN * CHAR_BITS -1 :0] word_gen_out =
	//		{ gen_id, word_id_out, word_gen_dout };
	//
	// also [15:0] pkt_id from incoming packet.


	// **************************************************
	//
	// input packet type CMP_CONFIG (0x03)
	//
	// **************************************************
	wire cmp_config_wr_en = ~empty & ~error
			& inpkt_type == PKT_TYPE_CMP_CONFIG & inpkt_data & ~cmp_config_full;
	
	wire [`SALT_MSB:0] salt;
	wire [`RAM_ADDR_MSB-1:0] read_addr_start, addr_diff_start;
	wire [`HASH_MSB:0] hash;
	wire [`RAM_ADDR_MSB:0] hash_addr;
	
	cmp_config cmp_config(
		.wr_clk(CLK), .din(din), .wr_en(cmp_config_wr_en), .full(cmp_config_full),
		
		.rd_clk(CORE_CLK),
		.salt_out(salt), .read_addr_start(read_addr_start), .addr_diff_start(addr_diff_start),
		.hash_out(hash), .hash_valid(hash_valid), .hash_addr_out(hash_addr), .hash_end(hash_end),
		.rd_en(arbiter_cmp_config_wr_en), .empty(cmp_config_empty),
		.new_cmp_config(new_cmp_config), .config_applied(config_applied), 
		.error(err_cmp_config)
	);

	// read from cmp_config
	assign arbiter_cmp_config_wr_en = ~arbiter_cmp_config_full & ~cmp_config_empty;
	
	// read from word_gen
	assign word_gen_rd_en = ~word_gen_empty & ~arbiter_almost_full_r;
	wire extra_reg_wr_en = word_gen_rd_en;

	//
	// It requires extra register word_gen -> arbiter
	//
	reg arbiter_almost_full_r = 0;
	always @(posedge WORD_GEN_CLK)
		arbiter_almost_full_r <= arbiter_almost_full;
	
	reg [WORD_MAX_LEN * CHAR_BITS - 1:0] word_gen_dout_r;
	reg [15:0] pkt_id_r, word_id_out_r;
	reg [31:0] gen_id_r;
	reg gen_end_r;
	reg extra_reg_empty = 1;
	
	always @(posedge WORD_GEN_CLK)
		if (extra_reg_wr_en) begin
			extra_reg_empty <= 0;
			word_gen_dout_r <= word_gen_dout;
			pkt_id_r <= pkt_id; word_id_out_r <= word_id_out;
			gen_id_r <= gen_id; gen_end_r <= gen_end;
		end
		else if (arbiter_wr_en)
			extra_reg_empty <= 1;
	
	wire arbiter_wr_en = ~extra_reg_empty & ~arbiter_full;

	
	//
	// Arbiter
	//
	wire [1:0] pkt_type_outpkt;
	wire [15:0] pkt_id_outpkt, word_id_outpkt;
	wire [`RAM_ADDR_MSB:0] hash_num_eq_outpkt;
	wire [31:0] gen_id_outpkt, num_processed_outpkt;
	
	arbiter arbiter(
		.CLK(WORD_GEN_CLK), .CORE_CLK(CORE_CLK), .CMP_CLK(CMP_CLK),
		//.word(word_gen_dout), .pkt_id(pkt_id), .word_id(word_id_out),
		//.gen_id(gen_id), .gen_end(gen_end),
		.word(word_gen_dout_r), .pkt_id(pkt_id_r), .word_id(word_id_out_r),
		.gen_id(gen_id_r), .gen_end(gen_end_r),
		//.wr_en(arbiter_wr_en), .full(arbiter_full), 
		.wr_en(arbiter_wr_en), .full(arbiter_full), .almost_full(arbiter_almost_full),
		
		.salt(salt), .read_addr_start(read_addr_start), .addr_diff_start(addr_diff_start),
		.hash(hash), .hash_valid(hash_valid), .hash_addr(hash_addr), .hash_end(hash_end),
		.cmp_config_wr_en(arbiter_cmp_config_wr_en), .cmp_config_full(arbiter_cmp_config_full),
		.new_cmp_config(new_cmp_config), .cmp_config_applied(config_applied),
		
		.pkt_type_out(pkt_type_outpkt), .gen_id_out(gen_id_outpkt), .pkt_id_out(pkt_id_outpkt),
		.word_id_out(word_id_outpkt), .num_processed_out(num_processed_outpkt),
		.hash_num_eq(hash_num_eq_outpkt),
		.rd_en(arbiter_rd_en), .empty(arbiter_empty),
		.error(app_status)
	);

	wire [15:0] dout_app_mode2;

	// read from arbiter
	assign arbiter_rd_en = ~arbiter_empty & ~full_outpkt;
	wire wr_en_outpkt = arbiter_rd_en;
	
	outpkt_v2 outpkt(
		.CLK(CMP_CLK), .wr_en(wr_en_outpkt), .full(full_outpkt),
		
		.pkt_type(pkt_type_outpkt),
		.pkt_id(pkt_id_outpkt), // this pkt_id is included into body for reference to original packet
		.gen_id(gen_id_outpkt), .word_id(word_id_outpkt), .num_processed(num_processed_outpkt),
		.hash_num_eq(hash_num_eq_outpkt),
		
		.dout(dout_app_mode2), .rd_en(rd_en_outpkt), .empty(empty_outpkt)
	);

	assign rd_en_outpkt = ~empty_outpkt & ~full;
	assign output_fifo_wr_en = rd_en_outpkt;


endmodule

