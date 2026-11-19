
// On-board operator interface for boards with 6 seven-segment displays,
// 10 LEDs and 10 slide switches (Terasic DE1-SoC layout).
//
// Displays (HEX5..HEX0, active low):
//   SW0 down : measured hash rate in kH/s, e.g. " 25000"; "HALt" when halted
//   SW0 up   : low 24 bits of the last golden nonce, in hex
//
// LEDs:
//   LEDR0    : hash heartbeat (nonce bit 24); stops if hashing stops
//   LEDR1    : board heartbeat from MAIN_CLK; stops if the FPGA is unconfigured
//   LEDR2    : halted by SW9
//   LEDR3    : new work received from the host (pulse-stretched)
//   LEDR4    : golden nonce found (pulse-stretched)
//   LEDR9..5 : number of golden nonces found, mod 32
//
// SW9 up halts hashing (operator stop). The halt output is synchronised to
// hash_clk.
//
// The hash rate is measured, not computed: a 1 ms window is timed from
// MAIN_CLK (independent of the PLL) and the nonce counter's advance across
// each window is nonces per millisecond, i.e. kH/s.

module board_hmi # (
	parameter MAIN_CLK_MHZ = 50
) (
	input main_clk,
	input hash_clk,

	input [31:0] nonce,
	input [31:0] golden_nonce,
	input golden_found,        // one hash_clk pulse per golden nonce
	input new_work,            // one hash_clk pulse when work changes

	input [9:0] sw,
	output reg [9:0] ledr = 10'd0,
	output reg [6:0] hex0 = 7'h7F,
	output reg [6:0] hex1 = 7'h7F,
	output reg [6:0] hex2 = 7'h7F,
	output reg [6:0] hex3 = 7'h7F,
	output reg [6:0] hex4 = 7'h7F,
	output reg [6:0] hex5 = 7'h7F,

	output halt,
	output reg [15:0] found_count = 16'd0
);

	//// Switch synchronisers
	reg [9:0] sw_meta = 10'd0, sw_sync = 10'd0;
	always @ (posedge hash_clk) begin
		sw_meta <= sw;
		sw_sync <= sw_meta;
	end
	assign halt = sw_sync[9];
	wire show_golden = sw_sync[0];


	//// 1 ms timebase and board heartbeat (MAIN_CLK domain)
	localparam MS_CYCLES = MAIN_CLK_MHZ * 1000;
	reg [16:0] ms_cnt = 17'd0;
	reg ms_toggle = 1'b0;
	reg [25:0] main_heartbeat = 26'd0;

	always @ (posedge main_clk) begin
		main_heartbeat <= main_heartbeat + 26'd1;
		if (ms_cnt == MS_CYCLES - 1) begin
			ms_cnt <= 17'd0;
			ms_toggle <= ~ms_toggle;
		end else
			ms_cnt <= ms_cnt + 17'd1;
	end


	//// Hash rate: nonce advance per 1 ms window (hash_clk domain)
	reg [2:0] ms_sync = 3'd0;
	reg [31:0] nonce_at_window = 32'd0;
	reg [19:0] window_delta = 20'd0;
	reg [7:0] window_count = 8'd0;
	reg bcd_start = 1'b0;

	always @ (posedge hash_clk) begin
		ms_sync <= {ms_sync[1:0], ms_toggle};
		bcd_start <= 1'b0;

		if (ms_sync[2] ^ ms_sync[1]) begin
			window_delta <= (nonce - nonce_at_window > 32'd999999) ? 20'd999999 : nonce - nonce_at_window;
			nonce_at_window <= nonce;
			window_count <= window_count + 8'd1;
			// Refresh the display about 4 times a second
			bcd_start <= (window_count == 8'd0);
		end
	end


	//// Binary to BCD (sequential double dabble, 20 cycles per conversion)
	reg [19:0] bcd_bin = 20'd0;
	reg [23:0] bcd_work = 24'd0;
	reg [23:0] rate_bcd = 24'd0;
	reg [4:0] bcd_steps = 5'd0;

	wire [23:0] bcd_adjusted;
	genvar d;
	generate
		for (d = 0; d < 6; d = d + 1) begin : DABBLE
			assign bcd_adjusted[4*d +: 4] = (bcd_work[4*d +: 4] >= 4'd5) ? bcd_work[4*d +: 4] + 4'd3 : bcd_work[4*d +: 4];
		end
	endgenerate

	wire [23:0] bcd_next = {bcd_adjusted[22:0], bcd_bin[19]};

	always @ (posedge hash_clk) begin
		if (bcd_start) begin
			bcd_bin <= window_delta;
			bcd_work <= 24'd0;
			bcd_steps <= 5'd20;
		end else if (bcd_steps != 5'd0) begin
			bcd_work <= bcd_next;
			bcd_bin <= {bcd_bin[18:0], 1'b0};
			bcd_steps <= bcd_steps - 5'd1;
			if (bcd_steps == 5'd1)
				rate_bcd <= bcd_next;
		end
	end


	//// Event flashes and found counter
	reg [24:0] work_flash = 25'd0, golden_flash = 25'd0;

	always @ (posedge hash_clk) begin
		if (new_work)
			work_flash <= {25{1'b1}};
		else if (work_flash != 25'd0)
			work_flash <= work_flash - 25'd1;

		if (golden_found) begin
			golden_flash <= {25{1'b1}};
			found_count <= found_count + 16'd1;
		end else if (golden_flash != 25'd0)
			golden_flash <= golden_flash - 25'd1;
	end


	//// Seven-segment encoding (active low, bit 0 = segment a)
	function [6:0] seg_hex (input [3:0] v);
		case (v)
			4'h0: seg_hex = 7'b1000000;  4'h1: seg_hex = 7'b1111001;
			4'h2: seg_hex = 7'b0100100;  4'h3: seg_hex = 7'b0110000;
			4'h4: seg_hex = 7'b0011001;  4'h5: seg_hex = 7'b0010010;
			4'h6: seg_hex = 7'b0000010;  4'h7: seg_hex = 7'b1111000;
			4'h8: seg_hex = 7'b0000000;  4'h9: seg_hex = 7'b0010000;
			4'hA: seg_hex = 7'b0001000;  4'hB: seg_hex = 7'b0000011;
			4'hC: seg_hex = 7'b1000110;  4'hD: seg_hex = 7'b0100001;
			4'hE: seg_hex = 7'b0000110;  default: seg_hex = 7'b0001110;
		endcase
	endfunction

	localparam [6:0] SEG_BLANK = 7'b1111111;
	localparam [6:0] SEG_H = 7'b0001001, SEG_A = 7'b0001000, SEG_L = 7'b1000111, SEG_T = 7'b0000111;

	// Leading-zero blanking for the rate (the units digit is always shown)
	wire [5:0] nonzero_or_lower;
	assign nonzero_or_lower[5] = rate_bcd[23:20] != 4'd0;
	assign nonzero_or_lower[4] = nonzero_or_lower[5] | (rate_bcd[19:16] != 4'd0);
	assign nonzero_or_lower[3] = nonzero_or_lower[4] | (rate_bcd[15:12] != 4'd0);
	assign nonzero_or_lower[2] = nonzero_or_lower[3] | (rate_bcd[11:8] != 4'd0);
	assign nonzero_or_lower[1] = nonzero_or_lower[2] | (rate_bcd[7:4] != 4'd0);
	assign nonzero_or_lower[0] = 1'b1;

	function [6:0] rate_digit (input [3:0] v, input show);
		rate_digit = show ? seg_hex(v) : SEG_BLANK;
	endfunction

	always @ (posedge hash_clk) begin
		if (show_golden) begin
			hex5 <= seg_hex(golden_nonce[23:20]);
			hex4 <= seg_hex(golden_nonce[19:16]);
			hex3 <= seg_hex(golden_nonce[15:12]);
			hex2 <= seg_hex(golden_nonce[11:8]);
			hex1 <= seg_hex(golden_nonce[7:4]);
			hex0 <= seg_hex(golden_nonce[3:0]);
		end else if (halt) begin
			hex5 <= SEG_H;
			hex4 <= SEG_A;
			hex3 <= SEG_L;
			hex2 <= SEG_T;
			hex1 <= SEG_BLANK;
			hex0 <= SEG_BLANK;
		end else begin
			hex5 <= rate_digit(rate_bcd[23:20], nonzero_or_lower[5]);
			hex4 <= rate_digit(rate_bcd[19:16], nonzero_or_lower[4]);
			hex3 <= rate_digit(rate_bcd[15:12], nonzero_or_lower[3]);
			hex2 <= rate_digit(rate_bcd[11:8], nonzero_or_lower[2]);
			hex1 <= rate_digit(rate_bcd[7:4], nonzero_or_lower[1]);
			hex0 <= rate_digit(rate_bcd[3:0], nonzero_or_lower[0]);
		end

		ledr <= {found_count[4:0], golden_flash != 25'd0, work_flash != 25'd0, halt, main_heartbeat[25], nonce[24]};
	end

endmodule
