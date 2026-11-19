Open-Source FPGA Bitcoin Miner
==============================================

DE1-SoC Port (this fork)
------------------------

This fork ports the miner to the **Terasic DE1-SoC** (Intel/Altera Cyclone V SoC,
5CSEMA5F31C6) and current Quartus Prime Lite tooling (25.1). It adds a hardware
self-test with known-answer vectors. The original project targeted Cyclone IV
boards and Quartus II 10.x from 2011.

**Status: running on hardware.** Verified on a DE1-SoC:

| Metric | Result |
|--------|--------|
| Logic utilization | 19,033 / 32,070 ALMs (59%), 30,365 registers |
| Hash clock | 100 MHz from `altera_pll`. Timing met at all corners: worst-case setup slack +0.109 ns (slow 85 C), Fmax 101.1 MHz |
| Hash rate | 25.00 MH/s measured over JTAG |
| Self-test | 2/2 known-answer vectors passed on the board |
| Independent check | The FPGA also found two nonces that were not planted (`0x9ccdef20`, `0xacbba77f`). Both were confirmed as valid with `hashlib` |

### What changed

| Area | Change |
|------|--------|
| Board support | New `boards/DE1_SoC` pin and device constraints (50 MHz clock on `PIN_AF14`). |
| Clocking | New `cores/cyclone_v_pll`: Cyclone V has no `altpll`, so this wraps `altera_pll`. It keeps the same integer parameters as the Cyclone IV version, so the shared top-level is unchanged. `altera_pll` takes its frequencies as strings, which are generated in SystemVerilog as typed `string` parameters. Plain Verilog bit-vector strings are rejected by Quartus (Error 114000). The PLL is bypassed when no frequency change is needed. |
| Project | `projects/DE1_SoC_Unoptimized_Pipelined`: SHA-256 pipeline with 32 stages per hash (`CONFIG_LOOP_LOG2=2`), clocked at 100 MHz, giving 25 MH/s. The 64-stage configuration needed 37.8k ALMs (118% of the device), so the design trades pipeline depth for clock rate. |
| JTAG / programming | On SoC boards the ARM HPS debug port is first on the JTAG chain (`@1`) and the FPGA is second (`@2`). The original script programmed `@1`. It now finds the FPGA by name, and skips the device prompts when there is only one choice. |
| Tooling | `scripts/de1soc`: one-step build, program and Quartus install scripts, using 64-bit Quartus binaries. |

### Verification approach

The FPGA talks to the host through In-System Sources and Probes over JTAG. The
host writes the midstate (`STAT`) and block-header tail (`DAT2`), and reads back
the golden nonce (`GNON`) and the live nonce counter (`NONC`).

1. **Known-answer vectors, checked against a reference model**
   (`scripts/test/test_vectors.py`). It builds the exact `STAT`/`DAT2` words the
   host writes for two real block headers: a share from the original testbench,
   and the Bitcoin genesis block. A bit-accurate Python model of the RTL datapath
   (word ordering, padding, the double SHA-256 and the golden-ticket comparison)
   then runs on those words. The result is cross-checked against `hashlib`, and a
   negative case (nonce + 1) must fail. Writing this model exposed and fixed a
   padding/byte-order error before it reached hardware.
2. **Hardware self-test** (`scripts/test/selftest.tcl`). It drives the real board
   over JTAG with those vectors and passes only when the reported nonce matches.
   It is designed around the hardware's behaviour:
   - The nonce counter free-runs and isn't reset when new work arrives. The test
     therefore tracks how far the counter has travelled, modulo 2^32, and checks
     the result only once the counter has swept past the expected nonce.
   - Two vectors with different answers run back to back, so a result left over
     from an earlier run cannot produce a false pass.
   - A stalled counter (no hash clock) is detected and reported as its own
     failure. Hash rate is measured live.
3. **Host-side tests without hardware.** The self-test and programming scripts
   were run against a mocked Quartus JTAG API that simulates the DE1-SoC's
   two-device chain. This covered the pass path, the broken-firmware path, the
   stalled-clock path, and FPGA (`@2`) selection.

### Quick start (Windows)

```
scripts\de1soc\install-quartus.ps1   # or install Quartus Prime Lite + Cyclone V + USB-Blaster II driver manually
python scripts\test\test_vectors.py  # offline vector check, no board needed
scripts\de1soc\build.bat             # synthesize, fit, timing analysis -> fpgaminer.sof
scripts\de1soc\program.bat           # load the FPGA over the on-board USB-Blaster II
scripts\test\selftest.bat            # on-hardware known-answer test
```

See `projects/DE1_SoC_Unoptimized_Pipelined/README.md` for configuration and
tuning. *Note:* the `scripts/mine` pool client uses the legacy getwork protocol,
which modern pools no longer serve. This fork is an FPGA design and verification
exercise, not a profitable miner.

--------------------------------------------------------------------------------

*The original project README follows.*

--------------------------------------------------------------------------------
Copyright (C) 2011 fpgaminer@bitcoin-mining.com

See LICENSE.txt


Purpose
-------

To promote the free and open development of an FPGA based Bitcoin mining solution.

http://www.weusecoins.com/

http://bitcoin.org/


Project Status
--------------

Project is fully functional and allows mining of Bitcoins both in a Pool and Solo.
It also supports Namecoins.

**Current Performance:** 109 MHash/s
*On a Terasic DE2-115 Development Board*

*Note: The included default configuration file, and source files, are built for
50 MHash/s performance (downclocked). This is meant to prevent damage to your valuable
chip if you don't provide an appropriate cooling solution.*


Contributors
------------

These people have worked hard to enhance and promote the Open-Source FPGA Bitcoin Miner
project:
*Not listed in any particular order*

**teknohog**
1HkL2iLLQe3KJuNCgKPc8ViZs83NJyyQDM

**OrphanedGland**
1PioyqqFWXbKryxysGqoq5XAu9MTRANCEP

**udif**

**TheSeven**
14Jc8vWq1mPv7vWnP5VquZZgpLEtzW2vja

**makomk**
15XX7BhQcZFUg47S4VKyiLygPTHTs9234J

**newMeat1**
1LbqTCA1cnpbbdKbXzZZfHYMe7teiczQc2


Supported Devices
------------------

Both Xilinx and Altera devices are currently supported. A binary configuration file and tools
are provided for the Terasic DE2-115 Development Board, so it is easy to get up and running
with that board. For other devices, you can modify and compile the correct projects for your
specific development board.


Installation Instructions (for Terasic DE2-115)
-------------------------


### Required Equipment:
* DE2-115 Development Kit (this is *not* a DE2. It has a Cyclone IV EP4CE115.)
* USB Cable
* Windows PC (Linux is also supported, but not documented)
* Altera's Quartus II (installed on PC)


###Instructions:

####Do These Once:

1) *IMPORTANT*: Please remove the clear acrylic cover on your DE2-115 board. This will restrict
air flow and may cause the chip to overheat.

2) Navigate to 'scripts/mine' and follow the instructions in 'config.example.tcl' (open in Notepad or other text editor)

####Do these each time you want to run the miner:

1) Connect the DE2-115 Development Kit to your PC through USB, connect its power, and turn it on.

2) Ensure that the DE2-115's drivers have been installed successfully on your PC.
Consult the DE2-115 User Guide for more information on setting up the DE2-115.

3) Navigate to 'scripts/program' and run 'program-fpga-board.bat'.

4) Follow the instructions provided by the program-fpga-board script.
Select the correct cable and programming file.
Once programming has succeeded, the DE2-115 is now ready to mine!

*Note: This script sometimes fails immediately upon execution. Please try running it again.*

5) Run 'mine.bat'

6) If working correctly, 'mine.bat' will leave a console window open where it reports hashing rate, estimated hashing rate and accepted/rejected share information.

7) Profit!


####Notes:
* You need to re-program the DE2-115 every time it is powered off and on again. Repeat steps 1 through 7 for subsequent uses.
* Your PC needs to stay on and connected to the internet. It is acting like a controller for the FPGA,
feeding it data and getting back valid hashes.


Thank You!
--------------------

--------------------



```
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA1

fpgaminer@bitcoin-mining.com
Donation Address: 1E1XgiJAzm1Wn7ZWuhkryzBoViBJ7CcRCQ

Donations are most welcome! They will be used to buy more equipment. I'm currently trying to get
an ethernet module up and running so the miner can run all on its own.
-----BEGIN PGP SIGNATURE-----
Version: GnuPG v1.4.11 (MingW32)

iQIcBAEBAgAGBQJN1dAzAAoJEFFoGj2A5YKRt/IP/3LaZlEWvdUpAxcs5ANS3fcA
NdKFiIycfnBKtmXjXiHQk4DZY+tbvuPPggzFHBA7k+3wV3WBOF2rjQiorODZff6q
xb6gSVINUXucv/+SDzqx8CtjMa17wzSayiczC03t+IICYs2/atdLAFvbr0LwdbqZ
oBQRgYK4hD39fQzD8v/L26glh3va72ZibuO043uH/WMFgcQseTFHF7QPLJm0k0A/
nx5p0cTtqqSf4g9MQICnNU8MGVrXXOGZU4DeItbJjNcvsomzmibha+9jQ2K8XD8F
KzbdTK+YzvdzcDMaeOgs70SnVEFfUS1ykbdDC850M6qkRP79HBqH7Neq1Rld5ktj
Mrd2hHC4NC0fgMD3hUbTjfIcCZOPwKYvp5oCLYYO1CqzV64Ag0o9qZDr8FS+9Npv
PEbWQpQuZqqtkhppVcCmOv4bl8XWTuQJEoxP8rWkJdfhkDUt5hwQsFrMQB7goXDc
pJZu1wnWdzpgcDyNjkNDp6sqnJGzCgft7o3hPiZO79BZZRLtdRSMHa0RdJJK5zLv
8JqOJCJUFhVZHSKsHyGdJHppjKk/yZbBGLuJUTAfrMk5I/X5b/V9TGiWKoPN3zce
Hdd5LQF5Z881wCgrnPz2dwR5oXMUcWqd//ZAs7Jcnvp6Bz5HWrFH5FBgpfg0K3c6
qBmd3GhQgxnFsBW62dAJ
=Lvja
-----END PGP SIGNATURE-----
```


