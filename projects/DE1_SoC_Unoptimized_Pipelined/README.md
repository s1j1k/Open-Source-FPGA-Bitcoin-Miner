DE1-SoC port of the unoptimized pipelined miner (Terasic DE1-SoC,
Cyclone V SoC 5CSEMA5F31C6). Only the FPGA fabric is used; the ARM (HPS)
side is not involved. Communication is over JTAG (In-System Sources and
Probes) through the on-board USB-Blaster II, exactly like the DE2-115
project, so the existing Tcl mining scripts work unchanged.

Differences from DE2_115_Unoptimized_Pipelined:

 * boards/DE1_SoC: device 5CSEMA5F31C6, CLOCK_50 on PIN_AF14.
 * cores/cyclone_v_pll: Cyclone V has no altpll; this uses altera_pll and is
   bypassed when MAIN_CLK_MULTIPLY == MAIN_CLK_DIVIDE.
 * LOOP_LOG2 = 2 (32 stages) at 100 MHz = 25 MH/s. LOOP_LOG2 = 1 needs 37.8k
   ALMs and does not fit the 5CSEMA5 (32,070 ALMs).
 * The JTAG chain has the HPS at @1 and the FPGA at @2;
   scripts/program/program-fpga-board.tcl now finds the FPGA automatically.

Measured results (Quartus Prime Lite 25.1, with the on-board HMI):
19,433 ALMs (61%), timing met at 100 MHz (worst setup slack +0.248 ns, Fmax 102.5 MHz), 25.00 MH/s on hardware,
self-test 2/2 passed.


Requirements
------------

Quartus Prime Lite (free) with Cyclone V device support, plus the
USB-Blaster II driver. See scripts/de1soc/install-quartus.ps1.


Build, program, test (Windows)
------------------------------

    scripts\de1soc\build.bat      compile -> quartus_output\fpgaminer.sof
    scripts\de1soc\program.bat    load into the FPGA over JTAG (volatile)
    scripts\test\selftest.bat     check the miner on real hardware

Use the USB-Blaster II port (mini-USB next to the power jack). JTAG
programming works with any MSEL switch setting; the design is lost on power
off.

selftest feeds the FPGA two known block headers (a share from
testbenches/test_data.txt and the Bitcoin genesis block) and checks that it
reports the known golden nonces. It takes up to ~3 minutes per vector at
25 MH/s because the nonce counter free-runs. scripts/test/test_vectors.py
verifies the vectors offline (no FPGA needed) against a model of the hardware.


Going faster
------------

The 100 MHz build has only ~0.1 ns of slack, so a higher clock needs
pipelining in the round logic rather than a PLL change. With 41% of the device
free, a second hashing core is the other way to scale.
