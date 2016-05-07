`timescale 1ns / 1ps

//**********************************************************
//
// Packet Aware FIFO (high-speed output).
//
// Features:
//
// * 64-bit input, 16-bit output
// * 1st word Fall-Through
//
// * Does not output on its own (reports EMPTY) when mode_limit == 1.
//   When reg_output_limit asserted:
//   - Reports amount ready for output (output_limit)
//   -- if that's no less than output_limit_min
//   -- incomplete packets don't count
//   - Starts output of that amount
//   - Asserts output_limit_done when finished
//
// * The design is unable for asynchronous operation
//
//**********************************************************

module packet_aware_fifo (
	input rst,
	input CLK,
	//input wr_clk,
	//input rd_clk,
	input [63:0] din,
	input wr_en,
	input rd_en,
	output [15:0] dout,
	output full,
	output empty,
	input pkt_end,
	output err_overflow, // overflow with unpacketed data
	input mode_limit, // turn on output limit
	input reg_output_limit,
	input [15:0] output_limit_min, // don't register output limit if no such amount
	output [15:0] output_limit,
	output output_limit_done
	);

	// ADDR_MSB == 8: 4Kbytes; 9: 8KB; 10: 16KB
	localparam ADDR_MSB = 9;

	reg [ADDR_MSB:0] addra = 0;
	reg [ADDR_MSB:0] last_pkt_end = 0;
	reg [ADDR_MSB:0] output_limit_addr = 0;
	reg [ADDR_MSB:0] output_limit_r = 0;
	reg [ADDR_MSB+2:0] addrb = 0;
	// 1st Word Fall-Through
	reg wft = 0;
	assign empty = rst || ~wft;

	assign output_limit = { {15-ADDR_MSB{1'b0}}, output_limit_r };
	
	assign full = rst || (addra + 1'b1 == addrb[ADDR_MSB+2:2]);
	assign err_overflow = full && last_pkt_end == addrb[ADDR_MSB+2:2];
	wire ena = wr_en && !full;

	wire [ADDR_MSB:0] output_limit_min_cmp =
			(|output_limit_min[15:ADDR_MSB+1]) ?
			{ADDR_MSB+1{1'b1}} : output_limit_min[ADDR_MSB:0];

	always @(posedge CLK) begin
		if (rst) begin
			addra <= 0;
			last_pkt_end <= 0;
			output_limit_addr <= 0;
			output_limit_r <= 0;
		end
		else begin
			if (ena) begin
				addra <= addra + 1'b1;
				if (pkt_end)
					last_pkt_end <= addra + 1'b1;
			end
			
			if (!mode_limit || reg_output_limit) begin
					if (!mode_limit || last_pkt_end - output_limit_addr >= output_limit_min_cmp) begin
						output_limit_addr <= last_pkt_end;
						output_limit_r <= last_pkt_end - output_limit_addr;
					end
					else
						output_limit_r <= 0;
			end
		end // !RESET
	end

	wire ram_empty_or_limit = (output_limit_addr == addrb[ADDR_MSB+2:2]);
	assign output_limit_done = ram_empty_or_limit;
	
	wire enb = (!ram_empty_or_limit && (empty || rd_en));
	reg enb_r = 0;

	wire [15:0] ram_out;		
	reg [15:0] dout_r;
	assign dout = dout_r;
	
	always @(posedge CLK) begin
		if (rst) begin
			addrb <= 0;
			wft <= 0;
			enb_r <= 0;
		end
		else begin
			if (empty || rd_en)
				enb_r <= enb;

			if (enb) begin
				addrb <= addrb + 1'b1;
			end
			
			if (enb_r) begin
				if (!wft || rd_en) begin
					wft <= 1;
					dout_r <= ram_out;
				end
			end // enb_r
			else if (rd_en)
				wft <= 0;
		end // !RESET
	end

	// IP Coregen -> Block RAM
	// True Dual-Port mode
	// Port A: write width 64, depth: 512=4K, 1024=8K, 2048=16K (adjust localparam ADDR_MSB)
	// Port B: width 16
	// Use pins: ena, enb
	bram_tdp_64in_output_fifo bram0(
		.clka(CLK),
		.ena(ena),
		.wea(1'b1),
		.addra(addra),
		.dina(din),
		.douta(), // unused
		.clkb(CLK),
		.enb(enb),
		.web(1'b0),
		.addrb(addrb),
		.dinb({16{1'b0}}), // unused
		.doutb(ram_out)
	);

endmodule
