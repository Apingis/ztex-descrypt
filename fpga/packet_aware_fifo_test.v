`timescale 1ns / 1ps

module packet_aware_fifo_test();
	reg [63:0] din;
	reg wr_en;
	reg wr_clk;
	wire full;
	reg pkt_end;
	
	wire [15:0] dout;
	wire empty;
	reg rd_clk;
	reg rd_en;

	wire [15:0] output_size,debug1;
	
	packet_aware_fifo uut(
		.rst(1'b0),
		.wr_clk(wr_clk),
		.rd_clk(rd_clk),
		.din(din),
		.wr_en(wr_en),
		.rd_en(rd_en), // wired to Cypress IO,
		.dout(dout), // wired to Cypress IO,
		.full(full),
		.empty(empty), // wired to Cypress IO
		.pkt_end(1'b1),
		.output_size(output_size),
		.debug1(debug1)
	);

	initial begin
		pkt_end <= 1;
		#40;
		wr_en <= 1;
		
		din <= 64'h0001_0002_0003_0004;
		#20;
		din <= 64'h000a_000b_000c_000d;
		#20;
		wr_en <= 0;
	end

	initial begin
		rd_en <= 0;
		#200;
		rd_en <= 1;
	end
	

	initial begin
		wr_clk <= 0;
		#5;
		while (1) begin
			wr_clk <= ~wr_clk; #10;
		end
	end

	initial begin
		rd_clk <= 0;
		#5;
		while (1) begin
			rd_clk <= ~rd_clk; #10;
		end
	end

endmodule
