#!/usr/bin/env python3
"""
Offline check of the hardware self-test vectors (no FPGA required).

For each vector this script:
  1. Builds getwork-style "midstate" and "data" strings from a raw 80-byte
     block header (the format scripts/mine/jtag_comm.tcl expects).
  2. Converts them exactly as push_work_to_fpga does (reverseHex, then the
     STAT and DAT2 source values).
  3. Runs a bit-accurate model of the fpgaminer_top datapath: state <= STAT,
     data <= {padding, nonce, DAT2[95:0]}, then the second SHA-256 and the
     "hash2[255:224] == 0" golden-ticket check.
  4. Cross-checks the result against hashlib's double SHA-256.

It then prints the STAT/DAT2/expected-nonce values used by selftest.tcl.

Usage: python test_vectors.py
"""
import hashlib
import struct

K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]
IV = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
M = 0xFFFFFFFF


def rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & M


def compress(state, w16):
    """One SHA-256 compression. state: 8 words (H0..H7), w16: 16 words."""
    w = list(w16)
    for i in range(16, 64):
        s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w.append((w[i - 16] + s0 + w[i - 7] + s1) & M)
    a, b, c, d, e, f, g, h = state
    for i in range(64):
        t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) & M
        t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & M
        a, b, c, d, e, f, g, h = (t1 + t2) & M, a, b, c, (d + t1) & M, e, f, g
    return [(x + y) & M for x, y in zip(state, [a, b, c, d, e, f, g, h])]


def swap32_bytes(b):
    """Byte-swap every 4-byte word (getwork's data encoding)."""
    return b"".join(b[i:i + 4][::-1] for i in range(0, len(b), 4))


def reverse_hex(s):
    """Same as reverseHex in scripts/mine/utils.tcl."""
    return bytes.fromhex(s)[::-1].hex()


def getwork_from_header(header):
    assert len(header) == 80
    padded = header + b"\x80" + b"\x00" * 39 + struct.pack(">Q", 640)
    data = swap32_bytes(padded).hex()
    mid = compress(IV, struct.unpack(">16I", header[:64]))
    midstate = b"".join(struct.pack("<I", x) for x in mid).hex()
    return midstate, data


def hardware_model(stat_hex, dat2_hex, nonce):
    """Model of fpgaminer_top: returns (golden?, hash2 words)."""
    stat = int(stat_hex, 16)
    dat2 = int(dat2_hex, 16)
    state = [(stat >> (32 * i)) & M for i in range(8)]       # IDX(0)=H0 ... IDX(7)=H7
    data = (0x000002800000000000000000000000000000000000000000000000000000000000000000000000000000000080000000 << 128) \
        | (nonce << 96) | (dat2 & ((1 << 96) - 1))
    w = [(data >> (32 * i)) & M for i in range(16)]           # rx_w[31:0] is W0
    h1 = compress(state, w)
    w2_bus = (0x0000010000000000000000000000000000000000000000000000000080000000 << 256) \
        | sum(x << (32 * i) for i, x in enumerate(h1))
    w2 = [(w2_bus >> (32 * i)) & M for i in range(16)]
    h2 = compress(IV, w2)
    return h2[7] == 0, h2


VECTORS = [
    # Vector from testbenches/test_data.txt (Bitcoin testnet-era share).
    ("test_data.txt share",
     "000000014cc2c57c7905fd399965282c87fe259e7da366e035dc087a0000141f000000006427b6492f2b052578fb4bc23655ca4e"
     "8b9e2b9b69c88041b2ac8c771571d1be4de695931a2694217a33330e"),
    # Bitcoin genesis block header (getwork data encoding, first 80 bytes).
    ("Bitcoin genesis block", None),
]

GENESIS_HEADER = bytes.fromhex(
    "01000000" + "00" * 32 +
    "3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"
    "29ab5f49" "ffff001d" "1dac2b7c")


def main():
    ok = True
    for name, gw80 in VECTORS:
        header = GENESIS_HEADER if gw80 is None else swap32_bytes(bytes.fromhex(gw80))
        midstate, data = getwork_from_header(header)

        # What push_work_to_fpga writes:
        stat = reverse_hex(midstate)
        dat2 = reverse_hex(data)[64:128]

        # Nonce as the FPGA's counter sees it = header bytes 76..79 big-endian.
        counter = struct.unpack(">I", header[76:80])[0]
        golden, h2 = hardware_model(stat, dat2, counter)

        ref = hashlib.sha256(hashlib.sha256(header).digest()).digest()
        ref_ok = ref[28:32] == b"\x00" * 4
        model_matches_ref = struct.pack(">8I", *h2) == ref

        print(f"== {name}")
        print(f"   block hash    : {ref[::-1].hex()}")
        print(f"   STAT          : {stat}")
        print(f"   DAT2          : {dat2}")
        print(f"   golden nonce  : {counter:08x}  (FPGA counter value)")
        print(f"   model golden  : {golden}   hashlib golden: {ref_ok}   model==hashlib: {model_matches_ref}")
        # A nonce one off must not be golden
        bad, _ = hardware_model(stat, dat2, (counter + 1) & M)
        print(f"   nonce+1 golden: {bad} (expected False)")
        ok &= golden and ref_ok and model_matches_ref and not bad

    print("\nALL VECTORS OK" if ok else "\nVECTOR CHECK FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
