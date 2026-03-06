#!/usr/bin/env python3
"""
Exhaustive verification of math routines against the assembled binary.

Reads the actual table data from game.bin and simulates umul8x8, smul8x8,
and urecip15 for every possible input, checking correctness against Python
reference values.

  umul8x8:   256 x 256 = 65536 unsigned pairs
  smul8x8:   256 x 256 = 65536 signed pairs
  urecip15:  32765 values (z = 3..32767)
"""

import sys

BINARY = "game.bin"
BASE = 0x0800  # load address

# Table addresses from listing (BASE + relocatable offset)
ADDRS = {
    "sqr_lo":   0x0F4F,
    "sqr_hi":   0x104F,
    "sqr2_lo":  0x114F,
    "sqr2_hi":  0x124F,
    "lerp_lo":  0x0E4D,
    "lerp_hi":  0x0ECE,
}


def load_table(data, addr, size=256):
    offset = addr - BASE
    return list(data[offset:offset + size])


def quarter_square_hi(a, b, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Simulate unsigned 8x8 quarter-square, return high byte only.

    Matches the assembly: SEC; LDA sqr_lo,Y; SBC sqr_lo,X; (discard lo);
    LDA sqr_hi,Y; SBC sqr_hi,X; (keep hi).
    """
    raw = a - b
    diff = raw & 0xFF
    if raw < 0:
        diff = ((~raw) + 1) & 0xFF

    s = a + b
    sum_lo = s & 0xFF
    carry = s > 255

    if carry:
        lo_sub = sqr2_lo[sum_lo] - sqr_lo[diff]
        borrow = 1 if lo_sub < 0 else 0
        res_hi = (sqr2_hi[sum_lo] - sqr_hi[diff] - borrow) & 0xFF
    else:
        lo_sub = sqr_lo[sum_lo] - sqr_lo[diff]
        borrow = 1 if lo_sub < 0 else 0
        res_hi = (sqr_hi[sum_lo] - sqr_hi[diff] - borrow) & 0xFF

    return res_hi


def quarter_square_16(a, b, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Simulate unsigned 8x8 quarter-square, return full 16-bit result."""
    raw = a - b
    diff = raw & 0xFF
    if raw < 0:
        diff = ((~raw) + 1) & 0xFF

    s = a + b
    sum_lo = s & 0xFF
    carry = s > 255

    if carry:
        lo_sub = sqr2_lo[sum_lo] - sqr_lo[diff]
        res_lo = lo_sub & 0xFF
        borrow = 1 if lo_sub < 0 else 0
        res_hi = (sqr2_hi[sum_lo] - sqr_hi[diff] - borrow) & 0xFF
    else:
        lo_sub = sqr_lo[sum_lo] - sqr_lo[diff]
        res_lo = lo_sub & 0xFF
        borrow = 1 if lo_sub < 0 else 0
        res_hi = (sqr_hi[sum_lo] - sqr_hi[diff] - borrow) & 0xFF

    return (res_hi << 8) | res_lo


def test_umul8x8(sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Test unsigned 8x8->16 quarter-square multiply for all 65536 pairs."""
    errors = 0
    for a in range(256):
        for b in range(256):
            expected = a * b
            result = quarter_square_16(a, b, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
            if result != expected:
                if errors < 10:
                    print(f"  umul8x8 FAIL: {a} * {b} = {result}, expected {expected}")
                errors += 1
    return errors


def test_smul8x8(sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Test signed 8x8->16 quarter-square multiply for all 65536 pairs."""
    errors = 0
    for a_u in range(256):
        a_s = a_u if a_u < 128 else a_u - 256
        for b_u in range(256):
            b_s = b_u if b_u < 128 else b_u - 256
            expected_u = (a_s * b_s) & 0xFFFF

            # Unsigned quarter-square
            result = quarter_square_16(a_u, b_u, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
            res_hi = (result >> 8) & 0xFF

            # Sign correction
            if a_s < 0:
                res_hi = (res_hi - b_u) & 0xFF
            if b_s < 0:
                res_hi = (res_hi - a_u) & 0xFF

            result = (res_hi << 8) | (result & 0xFF)
            if result != expected_u:
                if errors < 10:
                    print(f"  smul8x8 FAIL: {a_s} * {b_s} = ${result:04X}, "
                          f"expected ${expected_u:04X}")
                errors += 1
    return errors


def normalise(z):
    """Shared normalisation: returns (m, f, k) where m = Z_hi, f = Z_lo."""
    z_hi = (z >> 8) & 0xFF
    z_lo = z & 0xFF

    if z_hi == 0:
        a = z_lo
        k = 7
        if not (a & 0x80):
            while True:
                k -= 1
                a = (a << 1) & 0xFF
                if a & 0x80:
                    break
        return a, 0, k
    else:
        a = z_hi
        mb = z_lo
        k = 15
        while True:
            k -= 1
            carry = (mb >> 7) & 1
            mb = (mb << 1) & 0xFF
            a = ((a << 1) | carry) & 0xFF
            if a & 0x80:
                break
        return a, mb, k


def test_urecip15(lerp_lo, lerp_hi, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Test linear-interpolation urecip15 for all z in [3, 32767].

    Simulates the exact assembly algorithm: normalise, table lookup,
    one quarter-square multiply (high byte only), subtract, shift.
    """
    errors = 0
    off_by_one = 0
    for z in range(3, 32768):
        expected = 65536 // z
        m, f, k = normalise(z)

        if m == 0x80 and f == 0:
            result = 0x8000 >> (k - 1)
        else:
            i = m & 0x7F  # m - 128

            # T[i] from split tables
            t_lo = lerp_lo[i]
            t_hi = lerp_hi[i]

            # D = T[i] - T[i+1], low byte of 16-bit subtract (fits in 8 bits)
            d = (lerp_lo[i] - lerp_lo[i + 1]) & 0xFF

            # corr = hi(f * D) via quarter-square (high byte only)
            corr = quarter_square_hi(f, d, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)

            # x1 = T[i] - corr (16-bit minus 8-bit)
            x1_lo = (t_lo - corr) & 0xFF
            borrow = 1 if t_lo < corr else 0
            x1_hi = (t_hi - borrow) & 0xFF

            # Final rescale: Q = x1 >> (k - 1)
            shift = k - 1
            if shift == 0:
                result = (x1_hi << 8) | x1_lo
            elif shift >= 8:
                lo = x1_hi
                rem = shift - 8
                for _ in range(rem):
                    lo = lo >> 1
                result = lo
            else:
                x1 = (x1_hi << 8) | x1_lo
                result = x1 >> shift

        if result != expected:
            if result == expected + 1:
                off_by_one += 1
            else:
                if errors < 20:
                    print(f"  urecip15 FAIL: z={z} (${z:04X}), k={k}, m={m}, f={f}, "
                          f"got {result}, expected {expected}, diff={result - expected:+d}")
                errors += 1

    return errors, off_by_one


def verify_tables(data, addrs):
    """Verify all lookup tables against expected values."""
    sqr_lo  = load_table(data, addrs["sqr_lo"])
    sqr_hi  = load_table(data, addrs["sqr_hi"])
    sqr2_lo = load_table(data, addrs["sqr2_lo"])
    sqr2_hi = load_table(data, addrs["sqr2_hi"])
    lerp_lo = load_table(data, addrs["lerp_lo"], size=129)
    lerp_hi = load_table(data, addrs["lerp_hi"], size=129)

    errs = 0
    for i in range(256):
        exp_lo = (i * i // 4) & 0xFF
        exp_hi = (i * i // 4) >> 8
        if sqr_lo[i] != exp_lo:
            print(f"  sqr_lo[{i}] = ${sqr_lo[i]:02X}, expected ${exp_lo:02X}")
            errs += 1
        if sqr_hi[i] != exp_hi:
            print(f"  sqr_hi[{i}] = ${sqr_hi[i]:02X}, expected ${exp_hi:02X}")
            errs += 1
        n = i + 256
        exp2_lo = (n * n // 4) & 0xFF
        exp2_hi = (n * n // 4) >> 8
        if sqr2_lo[i] != exp2_lo:
            print(f"  sqr2_lo[{i}] = ${sqr2_lo[i]:02X}, expected ${exp2_lo:02X}")
            errs += 1
        if sqr2_hi[i] != exp2_hi:
            print(f"  sqr2_hi[{i}] = ${sqr2_hi[i]:02X}, expected ${exp2_hi:02X}")
            errs += 1

    for i in range(129):
        exp = round(2**22 / (128 + i))
        exp_lo = exp & 0xFF
        exp_hi = (exp >> 8) & 0xFF
        if lerp_lo[i] != exp_lo:
            print(f"  lerp_recip_lo[{i}] = ${lerp_lo[i]:02X}, expected ${exp_lo:02X}")
            errs += 1
        if lerp_hi[i] != exp_hi:
            print(f"  lerp_recip_hi[{i}] = ${lerp_hi[i]:02X}, expected ${exp_hi:02X}")
            errs += 1

    return errs, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi, lerp_lo, lerp_hi


def main():
    with open(BINARY, "rb") as f:
        data = f.read()

    print("Verifying tables...")
    errs, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi, lerp_lo, lerp_hi = \
        verify_tables(data, ADDRS)

    if errs:
        print(f"FAIL: {errs} table errors")
        return 1
    print("  Tables OK")

    print("Testing umul8x8 (65536 pairs)...")
    e1 = test_umul8x8(sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
    if e1:
        print(f"  FAIL: {e1} errors")
    else:
        print("  PASS: all 65536 pairs correct")

    print("Testing smul8x8 (65536 pairs)...")
    e2 = test_smul8x8(sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
    if e2:
        print(f"  FAIL: {e2} errors")
    else:
        print("  PASS: all 65536 pairs correct")

    print("Testing urecip15 (32765 values, z=3..32767)...")
    e3, w3 = test_urecip15(lerp_lo, lerp_hi,
                            sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)

    if e3:
        print(f"  FAIL: {e3} errors")
    else:
        print("  PASS: no errors beyond off-by-one")
    if w3:
        print(f"  WARNING: {w3} off-by-one values (result = expected + 1)")

    total = e1 + e2 + e3
    if total == 0:
        print(f"\nAll tests passed (131072 multiply pairs + 32765 divisions"
              f"{f', {w3} div off-by-one warnings' if w3 else ''})")
    else:
        print(f"\nFAILED: {total} total errors")
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
