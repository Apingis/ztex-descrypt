`timescale 1ns / 1ps

// **********************************************************************
//
// Input clocks:
// * IFCLK_IN 48 MHz.
// * FXCLK_IN 48 MHz.
//
// Output:
// * IFCLK - equal to IFCLK_IN
// * PKT_COMM_CLK - produced from FXCLK_IN
//
// **********************************************************************

module clocks #(
	parameter PKT_COMM_FREQUENCY = 180
	)(
	input IFCLK_IN,
	input FXCLK_IN,
	
	output IFCLK,
	output PKT_COMM_CLK
	//output APP_CLK
	);

	// This would result in a usage of IBUFG
	//assign IFCLK = IFCLK_IN;

	// *******************************************************************
	//
	// DCM_SP - gets IFCLK_IN
	//
	// * Adds some phase backshift, value figured out in experiments
	//
	// *******************************************************************

	DCM_SP #(.CLKDV_DIVIDE    (2.000),
		.CLKFX_DIVIDE          (2),
		.CLKFX_MULTIPLY        (4),
		.CLKIN_DIVIDE_BY_2     ("FALSE"),
		.CLKIN_PERIOD          (20.833),
		.CLKOUT_PHASE_SHIFT    ("FIXED"),
		.CLK_FEEDBACK          ("1X"),
		.DESKEW_ADJUST         ("SYSTEM_SYNCHRONOUS"),//("SOURCE_SYNCHRONOUS"),
		.PHASE_SHIFT           (-48),//-32),
		.STARTUP_WAIT          ("FALSE")
	) DCM_0 (
		// Input clock
		.CLKIN                 (IFCLK_IN),
		.CLKFB                 (dcm0_clkfb),
		// Output clocks
		.CLK0                  (IFCLK),//dcm0_clk0_IFCLK),
		.CLK90                 (),
		.CLK180                (),
		.CLK270                (),
		.CLK2X                 (),//dcm0_clk2x),
		.CLK2X180              (),
		.CLKFX                 (),//dcm0_clkfx),
		.CLKFX180              (),
		.CLKDV                 (),//dcm0_clkdv_IFCLK),
		// Ports for dynamic phase shift
		.PSCLK                 (1'b0),
		.PSEN                  (1'b0),
		.PSINCDEC              (1'b0),
		.PSDONE                (),
		// Other control and status signals
		.LOCKED                (),
		.STATUS                (),
		.RST                   (1'b0),
		// Unused pin- tie low
		.DSSEN                 (1'b0)
	);

	//-------------------------------------
	//
	// DCM #0 Output buffering & feedback
	//
	//-------------------------------------

	//assign dcm0_clkfb = dcm0_clk2x;
	//assign dcm0_clkfb = dcm0_clk0_IFCLK;

	// This adds usage of BUFG, BUFIO2, BUFIO2FB
	assign dcm0_clkfb = IFCLK;
/*
	BUFG bufg0(
		.I(dcm0_clk0_IFCLK),
		.O(IFCLK)
	);
*/
/*
	PLL_BASE #(
		.BANDWIDTH("OPTIMIZED"),
		.CLKFBOUT_MULT(16),
		.CLKOUT0_DIVIDE(16),
		.CLKOUT0_DUTY_CYCLE(0.5),
		.CLK_FEEDBACK("CLKFBOUT"), 
		.COMPENSATION("SOURCE_SYNCHRONOUS"),//("SYSTEM_SYNCHRONOUS"),//"INTERNAL"),
		.DIVCLK_DIVIDE(1),
		.REF_JITTER(0.10),
		.RESET_ON_LOSS_OF_LOCK("FALSE")
	) PLL_0 (
		.CLKFBOUT(pll0_clkfb),
		.CLKOUT0( pll0_clk0_IFCLK ),
		.CLKFBIN(pll0_clkfb),
		.CLKIN(dcm0_clk0_IFCLK),
		.RST(1'b0)
	);
	
	BUFG bufg0(
		.I(pll0_clk0_IFCLK),
		.O(IFCLK)
	);
*/


	// *******************************************************************
	//
	// DCM_CLKGEN - gets FXCLK_IN
	//
	// *******************************************************************

	DCM_CLKGEN #(
		.CLKFXDV_DIVIDE(2),       		// CLKFXDV divide value (2, 4, 8, 16, 32)
		.CLKFX_DIVIDE(4),//D_DEFAULT),  	// Divide value - D - (1-256)
		.CLKFX_MD_MAX(0.0),       		// Specify maximum M/D ratio for timing anlysis
		.CLKFX_MULTIPLY( PKT_COMM_FREQUENCY / 6 ),//M_DEFAULT),   // Multiply value - M - (2-256)
		.CLKIN_PERIOD(0.0),       		// Input clock period specified in nS
		.SPREAD_SPECTRUM("NONE"), 		// Spread Spectrum mode "NONE", "CENTER_LOW_SPREAD", "CENTER_HIGH_SPREAD",
												// "VIDEO_LINK_M0", "VIDEO_LINK_M1" or "VIDEO_LINK_M2" 
		.STARTUP_WAIT("FALSE")    		// Delay config DONE until DCM_CLKGEN LOCKED (TRUE/FALSE)
	) DCM_CLKGEN_1 (
		.CLKFX(),              		// 1-bit output: Generated clock output
		.CLKFX180(),           		// 1-bit output: Generated clock output 180 degree out of phase from CLKFX.
		.CLKFXDV( dcm1_clkfxdv ),    		// 1-bit output: Divided clock output
		.LOCKED(),       		// 1-bit output: Locked output
		.PROGDONE(),  // 1-bit output: Active high output to indicate the successful re-programming
		.STATUS(),             		// 2-bit output: DCM_CLKGEN status
		.CLKIN( FXCLK_IN ),          		// 1-bit input: Input clock
		.FREEZEDCM(1'b0),      		// 1-bit input: Prevents frequency adjustments to input clock
		.PROGCLK(1'b0),    		// 1-bit input: Clock input for M/D reconfiguration
		.PROGDATA(1'b0),  // 1-bit input: Serial data input for M/D reconfiguration
		.PROGEN(1'b0),      // 1-bit input: Active high program enable
		.RST(1'b0)                // 1-bit input: Reset input pin
	);

	PLL_BASE #(
		.BANDWIDTH("OPTIMIZED"),
		.CLKFBOUT_MULT(4),
		.CLKOUT0_DIVIDE(4),
		.CLKOUT0_DUTY_CYCLE(0.5),
		.CLK_FEEDBACK("CLKFBOUT"),//OUT0"), 
		.COMPENSATION("SYSTEM_SYNCHRONOUS"),//INTERNAL"),
		.DIVCLK_DIVIDE(1),
		.REF_JITTER(0.10),
		.RESET_ON_LOSS_OF_LOCK("FALSE")
	) PLL_1 (
		.CLKFBOUT(pll1_clkfb),
		.CLKOUT0( pll1_clk0_PKT_COMM_CLK ),//PKT_COMM_CLK ),
		.CLKOUT1(),
		.CLKOUT2(),
		.CLKOUT3(),
		.CLKOUT4(),
		.CLKOUT5(),
		.LOCKED(),
		.CLKFBIN(pll1_clkfb),//PKT_COMM_CLK),
		.CLKIN(dcm1_clkfxdv),
		.RST(1'b0)//pll_reset)
	);
		
	BUFG bufg1(
		.I(pll1_clk0_PKT_COMM_CLK),
		.O(PKT_COMM_CLK)
	);

endmodule
