
// Generate a clock to be used by the hashing cores.
//
// Cyclone V version. Cyclone V has no altpll; it uses altera_pll, which
// takes its frequencies as strings ("100.0 MHz"). The strings are built here
// from the same integer parameters the Cyclone IV version takes, so the
// top-level module does not need to know which family it is built for.
//
// This is SystemVerilog so the strings can be typed as `string`: built as
// plain Verilog bit vectors, Quartus passes them to altera_pll as numbers
// and rejects them (Error 114000).
//
// INPUT_FREQUENCY * MULTIPLY_BY / DIVIDE_BY must be a whole number of MHz.
// When MULTIPLY_BY == DIVIDE_BY the PLL is bypassed.

module hashing_pll # (
	parameter INPUT_FREQUENCY = 50,
	parameter DIVIDE_BY = 1,
	parameter MULTIPLY_BY = 1
) (
	input rx_clk,
	output tx_hash_clk
);

	localparam OUTPUT_FREQUENCY = INPUT_FREQUENCY * MULTIPLY_BY / DIVIDE_BY;

	// Integer MHz -> "<n>.0 MHz"
	function automatic string mhz (input integer f);
		string s;
		s = "";
		do begin
			s = {string'(byte'(8'd48 + f % 10)), s};
			f = f / 10;
		end while (f > 0);
		return {s, ".0 MHz"};
	endfunction

	localparam string REFERENCE_STRING = mhz(INPUT_FREQUENCY);
	localparam string OUTPUT_STRING = mhz(OUTPUT_FREQUENCY);

	generate
		if (MULTIPLY_BY == DIVIDE_BY) begin : BYPASS
			assign tx_hash_clk = rx_clk;
		end
		else begin : PLL
			altera_pll # (
				.fractional_vco_multiplier ("false"),
				.reference_clock_frequency (REFERENCE_STRING),
				.operation_mode ("direct"),
				.number_of_clocks (1),
				.output_clock_frequency0 (OUTPUT_STRING),
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
