`timescale 1ns / 1ps

`include "descrypt_core/descrypt.vh"

module wrapper_v2 #(
	parameter N_CORES = -1,
	parameter [N_CORES*16+15 : 0] CORES_CONF = 0,
	parameter NUM_CRYPT_INSTANCES = 16
	)(
	input CORE_CLK,
	input [`DIN_MSB:0] din,
	input [`RAM_ADDR_MSB+1:0] addr_in,
	
	input [N_CORES-1 :0] wr_en,
	output [N_CORES-1 :0] crypt_ready,
	output [N_CORES-1 :0] core_idle,
	output [N_CORES-1 :0] err_core,
	
	input CMP_CLK,
	output reg [N_CORES * (`RAM_ADDR_MSB+1) - 1 :0] dout,
	output reg [N_CORES * (`MSB(NUM_CRYPT_INSTANCES-1)+1) - 1 :0] dout_instance,
	output reg [N_CORES-1 :0] dout_equal,
	output reg [N_CORES-1 :0] dout_key_valid,
	output reg [N_CORES * (`NUM_BATCHES_MSB+1) - 1 :0] dout_batch_num,
	output reg [N_CORES * (`NUM_PKTS_MSB+1) - 1 :0] dout_pkt_num,
	output reg [N_CORES-1 :0] dout_batch_complete,
	output reg [N_CORES-1 :0] err_cmp = 0,

	input [N_CORES-1 :0] rd_en,
	output [N_CORES-1 :0] empty
	);

	// Input register stages (broadcast)
	(* SHREG_EXTRACT="NO", EQUIVALENT_REGISTER_REMOVAL="NO" *)
	reg [`DIN_MSB:0] din_r1, din_r2;
	(* SHREG_EXTRACT="NO", EQUIVALENT_REGISTER_REMOVAL="NO" *)
	reg [`RAM_ADDR_MSB+1:0] addr_in_r1, addr_in_r2;
	
	always @(posedge CORE_CLK) begin
		din_r1 <= din;
		addr_in_r1 <= addr_in;
		
		din_r2 <= din_r1;
		addr_in_r2 <= addr_in_r1;
	end
			
	

	genvar i;
	generate
	for (i=0; i < N_CORES; i=i+1) begin:core_gen

		localparam INPUT_R_STAGES = CORES_CONF[i*16+3 : i*16+2];
		localparam OUTPUT_R_STAGES = CORES_CONF[i*16+1 : i*16+0];

		// Input register stages
		(* SHREG_EXTRACT="NO" *) reg wr_en_r1 = 0, wr_en_r2 = 0;
		
		// Status signals from the core @ CORE_CLK
		(* SHREG_EXTRACT="NO" *) reg crypt_ready_r1, crypt_ready_r2;
		(* SHREG_EXTRACT="NO" *) reg core_idle_r1, core_idle_r2;
		(* SHREG_EXTRACT="NO" *) reg err_core_r1 = 0, err_core_r2 = 0;

		always @(posedge CORE_CLK) begin
			wr_en_r1 <= wr_en[i];
			crypt_ready_r1 <= crypt_ready_in; // ready to get a batch keys
			err_core_r1 <= core_error;
			// no data in descrypt instances and in the comparator;
			// there still might be valid data in output register.
			core_idle_r1 <= crypt_ready_in & cmp_ready;
			
			wr_en_r2 <= wr_en_r1;
			crypt_ready_r2 <= crypt_ready_r1;
			core_idle_r2 <= core_idle_r1;
			err_core_r2 <= err_core_r1;
		end

		assign crypt_ready[i] = INPUT_R_STAGES==1 ? crypt_ready_r1 : crypt_ready_r2;
		assign core_idle[i] = INPUT_R_STAGES==1 ? core_idle_r1 : core_idle_r2;
		assign err_core[i] = INPUT_R_STAGES==1 ? err_core_r1 : err_core_r2;

		
		// Output from the core @ CMP_CLK
		reg dout_full_r1 = 0, dout_full_r2 = 0; // Output register is full.
		
		wire [`RAM_ADDR_MSB:0] core_dout;
		wire [`NUM_BATCHES_MSB:0] core_dout_batch_num;
		wire [`MSB(NUM_CRYPT_INSTANCES-1):0] core_dout_instance;
		wire [`NUM_PKTS_MSB:0] core_dout_pkt_num;

		(* KEEP_HIERARCHY="true" *)
		descrypt_core_v5 core(
			.CORE_CLK(CORE_CLK),
			.din(INPUT_R_STAGES==1 ? din_r1 : din_r2),
			.addr_in(INPUT_R_STAGES==1 ? addr_in_r1 : addr_in_r2),
			.wr_en(INPUT_R_STAGES==1 ? wr_en_r1 : wr_en_r2),
			.crypt_ready(crypt_ready_in), .cmp_ready_sync(cmp_ready),
			
			.CMP_CLK(CMP_CLK),
			.dout_full(INPUT_R_STAGES==1 ? dout_full_r1 : dout_full_r2),
			.dout(core_dout),
			.dout_instance(core_dout_instance),
			.dout_equal(core_dout_equal),
			.dout_key_valid(core_dout_key_valid),
			.dout_batch_num(core_dout_batch_num),
			.dout_pkt_num(core_dout_pkt_num),
			.dout_batch_complete(core_dout_batch_complete),
			.dout_wr_en(core_dout_wr_en),
			.core_error(core_error),
			.cmp_error(cmp_error)
		);

		//
		// Extra register stage for output (CMP_CLK)
		//
		(* SHREG_EXTRACT="NO" *) reg [`RAM_ADDR_MSB:0] dout_r2;
		(* SHREG_EXTRACT="NO" *) reg [`MSB(NUM_CRYPT_INSTANCES-1):0] dout_instance_r2;
		(* SHREG_EXTRACT="NO" *) reg dout_equal_r2;
		(* SHREG_EXTRACT="NO" *) reg dout_key_valid_r2;
		(* SHREG_EXTRACT="NO" *) reg [`NUM_BATCHES_MSB:0] dout_batch_num_r2;
		(* SHREG_EXTRACT="NO" *) reg [`NUM_PKTS_MSB:0] dout_pkt_num_r2;
		(* SHREG_EXTRACT="NO" *) reg dout_batch_complete_r2;
		(* SHREG_EXTRACT="NO" *) reg err_cmp_r2 = 0;

		always @(posedge CMP_CLK) begin
			if (INPUT_R_STAGES == 2 & core_dout_wr_en) begin
				dout_full_r2 <= 1;
				dout_r2 <= core_dout;
				dout_instance_r2 <= core_dout_instance;
				dout_equal_r2 <= core_dout_equal;
				dout_key_valid_r2 <= core_dout_key_valid;
				dout_batch_num_r2 <= core_dout_batch_num;
				dout_pkt_num_r2 <= core_dout_pkt_num;
				dout_batch_complete_r2 <= core_dout_batch_complete;
				err_cmp_r2 <= cmp_error;
			end
			else if (INPUT_R_STAGES == 2 & rd_en_internal) begin
				dout_full_r2 <= 0;
			end
		end

		wire rd_en_internal = ~dout_full_r1 & dout_full_r2;

		always @(posedge CMP_CLK) begin
			if (INPUT_R_STAGES == 1 & core_dout_wr_en | INPUT_R_STAGES == 2 & rd_en_internal) begin
				dout_full_r1 <= 1;
				dout[(i+1) * (`RAM_ADDR_MSB+1)-1 -:`RAM_ADDR_MSB+1]
						<= INPUT_R_STAGES == 1 ? core_dout : dout_r2;
				
				dout_instance[(i+1) * (`MSB(NUM_CRYPT_INSTANCES-1)+1)-1 -:`MSB(NUM_CRYPT_INSTANCES-1)+1]
						<= INPUT_R_STAGES == 1 ? core_dout_instance : dout_instance_r2;
				
				dout_equal[i] <= INPUT_R_STAGES == 1 ? core_dout_equal : dout_equal_r2;
				dout_key_valid[i] <= INPUT_R_STAGES == 1 ? core_dout_key_valid : dout_key_valid_r2;
				dout_batch_num[(i+1) * (`NUM_BATCHES_MSB+1)-1 -:`NUM_BATCHES_MSB+1]
						<= INPUT_R_STAGES == 1 ? core_dout_batch_num : dout_batch_num_r2;
				
				dout_pkt_num [(i+1) * (`NUM_PKTS_MSB+1)-1 -:`NUM_PKTS_MSB+1]
						<= INPUT_R_STAGES == 1 ? core_dout_pkt_num : dout_pkt_num_r2;
				
				dout_batch_complete[i] <= INPUT_R_STAGES == 1 ? core_dout_batch_complete : dout_batch_complete_r2;
				err_cmp[i] <= INPUT_R_STAGES == 1 ? cmp_error : err_cmp_r2;
			end
			else if (rd_en[i]) begin
				dout_full_r1 <= 0;
			end
		end

		assign empty[i] = ~dout_full_r1;

	end
	endgenerate


endmodule

/*
// It removes equivalent instances.
module in_r(
	input CLK,
	input [`DIN_MSB:0] din,
	input [`RAM_ADDR_MSB+1:0] addr_in,
	(* SHREG_EXTRACT="NO", EQUIVALENT_REGISTER_REMOVAL="NO" *)
	output reg [`DIN_MSB:0] dout,
	(* SHREG_EXTRACT="NO", EQUIVALENT_REGISTER_REMOVAL="NO" *)
	output reg [`RAM_ADDR_MSB+1:0] addr_out
	);
	
	always @(posedge CLK) begin
		dout <= din;
		addr_out <= addr_in;
	end

endmodule
*/