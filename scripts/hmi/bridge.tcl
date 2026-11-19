##
# JTAG bridge for the dashboard. Run by dashboard.py under quartus_stp:
#   quartus_stp -t bridge.tcl [port]
#
# With a port, the bridge connects to the dashboard on 127.0.0.1:<port> and
# uses that socket both ways. quartus_stp block-buffers stdout when it is a
# pipe (samples arrive seconds late, in ~4 KB bursts), so the socket is the
# normal path; stdin/stdout without a port is kept for testing.
#
# Output: one JSON object per line
#   {"type":"connected","name":...,"has_status":0|1}
#   {"type":"sample","t":<ms>,"nonce":<int>,"gnon":<int>,"status":<int>|-1}
#   {"type":"work_ok"}
#   {"type":"error","message":...}
# Other text on stdout (from jtag_comm.tcl) is not JSON and is ignored.
#
# Input: commands, one per line
#   WORK <stat hex> <dat2 hex>
##

source [file join [file dirname [info script]] .. mine jtag_comm.tcl]

set sample_period_ms 200

if {[llength $argv] > 0} {
	set link [socket 127.0.0.1 [lindex $argv 0]]
	set link_in $link
} else {
	set link_in stdin
	set link stdout
}

proc emit {json} {
	global link
	puts $link $json
	flush $link
}

proc json_string {s} {
	set map [list "\\" "\\\\" "\"" "\\\"" "\n" " " "\r" "" "\t" " "]
	return "\"[string map $map $s]\""
}

proc read_hex_probe {name} {
	return [expr "0x[read_instance $name]"]
}

proc connect {} {
	while {1} {
		if {[catch {fpga_init} result] == 0 && $result != -1} {
			emit "{\"type\":\"connected\",\"name\":[json_string [get_fpga_name]],\"has_status\":[instance_exists STUS]}"
			return
		}
		emit "{\"type\":\"error\",\"message\":[json_string "No board with miner firmware found; retrying"]}"
		after 2000
	}
}

proc handle_command {line} {
	set parts [split [string trim $line]]
	if {[lindex $parts 0] eq "WORK" && [llength $parts] == 3} {
		write_instance "STAT" [lindex $parts 1]
		write_instance "DAT2" [lindex $parts 2]
		emit "{\"type\":\"work_ok\"}"
	} elseif {[string trim $line] ne ""} {
		emit "{\"type\":\"error\",\"message\":[json_string "Unknown command: $line"]}"
	}
}

fconfigure $link_in -blocking 0 -buffering line -translation auto
fconfigure $link -buffering line -translation lf
connect

while {1} {
	if {[catch {
		while {[gets $link_in line] >= 0} {
			handle_command $line
		}
		if {[eof $link_in]} {
			catch {end_insystem_source_probe}
			exit 0
		}

		set status -1
		if {[instance_exists STUS]} {
			set status [read_hex_probe STUS]
		}
		emit "{\"type\":\"sample\",\"t\":[clock milliseconds],\"nonce\":[read_hex_probe NONC],\"gnon\":[read_hex_probe GNON],\"status\":$status}"
	} err]} {
		emit "{\"type\":\"error\",\"message\":[json_string "JTAG link lost: $err"]}"
		catch {end_insystem_source_probe}
		after 1000
		connect
	}
	after $sample_period_ms
}
