##
# Hardware self-test for the virtual-wire mining firmware (STAT/DAT2/GNON/NONC).
#
# Run with:  quartus_stp -t selftest.tcl      (or selftest.bat)
#
# Loads known block headers into the FPGA and checks that it reports the
# known golden nonce. The FPGA's nonce counter free-runs and is not reset when
# new work arrives, so the test follows NONC until the counter has swept past
# the expected nonce, then checks GNON. Worst case is one full 2^32 sweep per
# vector (~172 s at 25 MH/s, ~86 s at 50 MH/s).
#
# Two vectors with different nonces are run back to back so that a GNON value
# left over from an earlier run cannot produce a false pass.
#
# The STAT/DAT2 values are exactly what push_work_to_fpga would write for the
# corresponding getwork data; they are generated and verified against a model
# of the hardware and hashlib by test_vectors.py.
##

source ../mine/jtag_comm.tcl

# name, STAT (midstate), DAT2 (tail of block header), expected golden nonce
set vectors {
	{"test_data.txt share"
	 228ea4732a3c9ba860c009cda7252b9161a5e75ec8c582a5f106abb3af41f790
	 000000000000000000000000800000000e33337a2194261a9395e64dbed17115
	 0e33337a}
	{"Bitcoin genesis block"
	 4719f91b96b187364f0103c8c3c8d8e91e59caa890ccac7d6358bff0bc909a33
	 000000000000000000000000800000001dac2b7cffff001d29ab5f494b1e5e4a
	 1dac2b7c}
}

# Extra nonces to sweep past the expected one before checking GNON, to cover
# pipeline latency and JTAG read lag.
set margin 0x100000
# Give up if the counter is not moving at all.
set stall_timeout_ms 5000

proc hex_to_int {h} {
	return [expr "0x$h"]
}

proc run_vector {name stat dat2 expected_hex} {
	global margin stall_timeout_ms

	set expected [hex_to_int $expected_hex]
	puts "=== $name (expecting golden nonce 0x$expected_hex)"

	write_instance "STAT" $stat
	write_instance "DAT2" $dat2

	set start [hex_to_int [read_instance NONC]]
	set prev $start
	set travelled 0
	set needed [expr {(($expected - $start) & 0xFFFFFFFF) + $margin}]
	set limit [expr {0x100000000 + $margin}]
	set last_gnon [read_instance GNON]
	set t0 [clock milliseconds]
	set t_last_move $t0
	set t_report $t0
	set reported_travelled 0

	while {$travelled < $needed} {
		set now_nonce [hex_to_int [read_instance NONC]]
		set delta [expr {($now_nonce - $prev) & 0xFFFFFFFF}]
		set prev $now_nonce
		incr travelled $delta
		set now [clock milliseconds]

		if {$delta != 0} {
			set t_last_move $now
		} elseif {$now - $t_last_move > $stall_timeout_ms} {
			puts stderr "FAIL: nonce counter stopped at 0x[format %08x $now_nonce]; is the hash clock running?"
			return 0
		}

		set gnon [read_instance GNON]
		if {$gnon ne $last_gnon} {
			puts "    GNON changed: 0x$gnon"
			set last_gnon $gnon
		}

		if {$now - $t_report >= 5000} {
			set rate [expr {($travelled - $reported_travelled) / (($now - $t_report) * 1000.0)}]
			set pct [expr {100.0 * $travelled / $needed}]
			puts [format "    %.2f MH/s, %5.1f%% of the way to the expected nonce" $rate $pct]
			set t_report $now
			set reported_travelled $travelled
		}

		if {$travelled > $limit} {
			break
		}
	}

	set gnon [hex_to_int [read_instance GNON]]
	set secs [expr {([clock milliseconds] - $t0) / 1000.0}]
	set avg [expr {$secs > 0 ? $travelled / ($secs * 1000000.0) : 0}]

	if {$gnon == $expected} {
		puts [format "PASS: found 0x%08x after %.1f s (average %.2f MH/s)\n" $gnon $secs $avg]
		return 1
	}
	puts stderr [format "FAIL: GNON is 0x%08x, expected 0x%s (swept %s nonces in %.1f s)\n" $gnon $expected_hex $travelled $secs]
	return 0
}


puts " --- FPGA Miner Self-Test --- \n"

if {[fpga_init] == -1} {
	puts stderr "No mining FPGA found. Program the board first (scripts/de1soc/program.bat)."
	qexit -error
}
puts "Mining FPGA found: [get_fpga_name]\n"

if {![instance_exists NONC]} {
	puts stderr "This firmware has no NONC probe; the self-test needs it."
	qexit -error
}

set passed 0
foreach v $vectors {
	lassign $v name stat dat2 expected
	incr passed [run_vector $name $stat $dat2 $expected]
}

end_insystem_source_probe

set total [llength $vectors]
if {$passed == $total} {
	puts "SELF-TEST PASSED ($passed/$total)"
	qexit -success
} else {
	puts stderr "SELF-TEST FAILED ($passed/$total passed)"
	qexit -error
}
