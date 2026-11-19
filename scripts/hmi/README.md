# Operator interface (HMI)

Two layers, both reading the same firmware:

## On-board (DE1-SoC, `cores/hmi/board_hmi.v`)

| Control / indicator | Meaning |
|---|---|
| HEX5–HEX0, SW0 down | Measured hash rate in kH/s (e.g. ` 25000`); `HALt` when halted |
| HEX5–HEX0, SW0 up | Low 24 bits of the last golden nonce (hex) |
| LEDR0 | Hash heartbeat (nonce bit 24). Stops if hashing stops |
| LEDR1 | Board heartbeat from the 50 MHz oscillator |
| LEDR2 | Halted |
| LEDR3 | New work received from the host |
| LEDR4 | Golden nonce found |
| LEDR9–LEDR5 | Golden nonces found, mod 32 (binary) |
| SW9 up | Operator halt: stops the nonce counter |

The hash rate is **measured** in hardware rather than derived from the configured
clock. A 1 ms window is timed from the board oscillator, independent of the PLL,
and the nonce counter's advance across it is the rate. A PLL or pipeline fault
therefore shows up on the display.

While halted, and for 255 cycles after resuming, the golden-ticket check is
masked. The reported nonce is computed as *current nonce minus a fixed pipeline
offset*, which is only valid while the counter advances steadily. Without the
mask, a halt could report a wrong nonce.

## PC dashboard (`dashboard.py` + `dashboard.html`)

```
scripts\hmi\dashboard.bat            # with the board connected and programmed
python scripts\hmi\dashboard.py --demo   # simulated board, no hardware needed
```

It opens http://127.0.0.1:8080 and binds to the local machine only.

- **Data path:** `bridge.tcl` runs under `quartus_stp` and streams the JTAG
  source/probe values (`NONC`, `GNON`, `STUS`) as JSON every 200 ms. It accepts
  `WORK` commands on stdin.
- **Independent verification:** every golden nonce the FPGA reports is re-hashed
  in Python (double SHA-256) against the work that was sent, and marked
  *Verified* or *Failed*.
- **Alarms** use the reserved status colours and always carry an icon and a label:

  | Alarm | Level | Raised when |
  |---|---|---|
  | Board not connected | Critical | No JTAG samples for 3 s |
  | Nonce counter stalled | Critical | Counter not advancing and not halted |
  | Failed verification | Critical | A reported nonce does not hash below target. Latches until acknowledged |
  | Hash rate out of tolerance | Serious | More than ±5% from expected (default 25 MH/s) |
  | Halted by operator | Warning | SW9 up |

  Alarms are logged on raise and clear. **Acknowledge** marks them acknowledged
  and releases the latched failed-verification alarm.
- **Work:** random headers (live search, about one golden nonce every 3 minutes at
  25 MH/s), or the test-share or genesis headers with known answers.
