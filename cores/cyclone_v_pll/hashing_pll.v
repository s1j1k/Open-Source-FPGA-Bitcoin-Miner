
// Generate a clock to be used by the hashing cores.
//
// Cyclone V version. Cyclone V has no altpll; it uses altera_pll, which
// takes its frequencies as strings ("100.0 MHz"). The strings are built here
// from the same integer parameters the Cyclone IV version takes, so the
// top-level module does not need to know which family it is built for.
//
// Limits: INPUT_FREQUENCY must be 10-99 MHz, and
// INPUT_FREQUENCY * MULTIPLY_BY / DIVIDE_BY must be a whole number of MHz
// between 10 and 999. When MULTIPLY_BY == DIVIDE_BY the PLL is bypassed.

module hashing_pll # (
	parameter INPUT_FREQUENCY = 50,
	parameter DIVIDE_BY = 1,
	parameter MULTIPLY_BY = 1
) (
	input rx_clk,
	output tx_hash_clk
);

	localparam OUTPUT_FREQUENCY = INPUT_FREQUENCY * MULTIPLY_BY / DIVIDE_BY;

	// ASCII digits of the input and output frequencies
	localparam [7:0] IN_D1 = 8'd48 + (INPUT_FREQUENCY / 10) % 10;
	localparam [7:0] IN_D0 = 8'd48 + INPUT_FREQUENCY % 10;
	localparam [7:0] OUT_D2 = 8'd48 + (OUTPUT_FREQUENCY / 100) % 10;
	localparam [7:0] OUT_D1 = 8'd48 + (OUTPUT_FREQUENCY / 10) % 10;
	localparam [7:0] OUT_D0 = 8'd48 + OUTPUT_FREQUENCY % 10;

	localparam REFERENCE_STRING = {IN_D1, IN_D0, ".0 MHz"};

	generate
		if (MULTIPLY_BY == DIVIDE_BY) begin : BYPASS
			assign tx_hash_clk = rx_clk;
		end
		else if (OUTPUT_FREQUENCY >= 100) begin : PLL3
			altera_pll # (
				.fractional_vco_multiplier ("false"),
				.reference_clock_frequency (REFERENCE_STRING),
				.operation_mode ("direct"),
				.number_of_clocks (1),
				.output_clock_frequency0 ({OUT_D2, OUT_D1, OUT_D0, ".0 MHz"}),
				.phase_shift0 ("0 ps"),
				.duty_cycle0 (50),
				.pll_type ("General"),
				.pll_subtype ("General")
			) altera_pll_i (
				.rst (1'b0),
				.outclk (tx_hash_clk),
				.locked (),
				.fboutclk (),
				.fbclk (1'b0),
				.refclk (rx_clk)
			);
		end
		else begin : PLL2
			altera_pll # (
				.fractional_vco_multiplier ("false"),
				.reference_clock_frequency (REFERENCE_STRING),
				.operation_mode ("direct"),
				.number_of_clocks (1),
				.output_clock_frequency0 ({OUT_D1, OUT_D0, ".0 MHz"}),
				.phase_shift0 ("0 ps"),
				.duty_cycle0 (50),
				.pll_type ("General"),
				.pll_subtype ("General")
			) altera_pll_i (
				.rst (1'b0),
				.outclk (tx_hash_clk),
				.locked (),
				.fboutclk (),
				.fbclk (1'b0),
				.refclk (rx_clk)
			);
		end
	endgenerate

endmodule
