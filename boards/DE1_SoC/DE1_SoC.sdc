##
#
# Copyright (c) 2011-2012 fpgaminer@bitcoin-mining.com
#
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
##

create_clock -period 20.000 -name MAIN_CLK MAIN_CLK

derive_pll_clocks
derive_clock_uncertainty



# Operator interface I/O: slide switches, LEDs and 7-segment displays are
# static, human-speed signals; no timing relationship to any clock.
set hmi_inputs [get_ports -nowarn {SW[*]}]
set hmi_outputs [get_ports -nowarn {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
if {[get_collection_size $hmi_inputs] > 0} { set_false_path -from $hmi_inputs }
if {[get_collection_size $hmi_outputs] > 0} { set_false_path -to $hmi_outputs }
