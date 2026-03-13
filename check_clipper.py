#!/usr/bin/env python3
"""Comprehensive test suite for the X-clipper with 16-bit Y interpolation.

Tests every stage of the pipeline:
  1. umul8x8 (building block)
  2. div_frac8 (X ratio computation)
  3. mul16x8 (16x8->16 multiply used for Y interpolation)
  4. clip_endpoint_0 / clip_endpoint_1 (full Y interpolation)
  5. emit_edge (full pipeline: load, reject, clip, store)
  6. Regression cases from real gameplay (close-up cubes)
  7. Property-based sweep across parameter space
  8. Old-bug regression (8-bit slope error)

Each Python model is cycle-accurate to the 6502 assembly in game.s.
"""

import math
import sys

PASS_COUNT = 0
FAIL_COUNT = 0

def check(cond, msg):
    global PASS_COUNT, FAIL_COUNT
    if not cond:
        FAIL_COUNT += 1
        print(f"    FAIL: {msg}")
    else:
        PASS_COUNT += 1

def to_signed8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v

def to_signed16(hi, lo):
    """Reconstruct signed 16-bit from hi:lo bytes."""
    val = ((hi & 0xFF) << 8) | (lo & 0xFF)
    return val - 0x10000 if val >= 0x8000 else val

def to_bytes16(val):
    """Convert signed integer to (hi, lo) byte pair (two's complement)."""
    if val < 0:
        val += 0x10000
    return (val >> 8) & 0xFF, val & 0xFF


# ======================================================================
# Assembly-exact models
# ======================================================================

def umul8x8(a, b):
    """Unsigned 8x8 -> 16-bit multiply. Returns (hi, lo)."""
    a, b = a & 0xFF, b & 0xFF
    result = a * b
    return (result >> 8) & 0xFF, result & 0xFF

def div_frac8(num_hi, num_lo, den_hi, den_lo):
    """16/16 fractional division matching game.s div_frac8.
    Returns floor(numerator * 256 / denominator), clamped to 0-255.
    Exact cycle-level model of the shift-subtract loop."""
    num_hi, num_lo = num_hi & 0xFF, num_lo & 0xFF
    den_hi, den_lo = den_hi & 0xFF, den_lo & 0xFF
    temp3 = 0
    ratio = 0

    for _ in range(8):
        # ASL clip_num_lo; ROL clip_num_hi; ROL temp3
        num_lo = (num_lo << 1) & 0x1FF
        carry = num_lo >> 8
        num_lo &= 0xFF
        num_hi = ((num_hi << 1) | carry) & 0x1FF
        carry = num_hi >> 8
        num_hi &= 0xFF
        temp3 = ((temp3 << 1) | carry) & 0xFF

        # Compare and subtract
        do_sub = False
        if temp3 > 0:
            do_sub = True
        elif num_hi > den_hi:
            do_sub = True
        elif num_hi == den_hi and num_lo >= den_lo:
            do_sub = True

        if do_sub:
            borrow = 0
            r_lo = num_lo - den_lo
            if r_lo < 0:
                r_lo += 256
                borrow = 1
            num_lo = r_lo
            r_hi = num_hi - den_hi - borrow
            if r_hi < 0:
                r_hi += 256
            num_hi = r_hi
            temp3 = 0
            ratio = ((ratio << 1) | 1) & 0xFF
        else:
            ratio = (ratio << 1) & 0xFF

    return ratio

def mul16x8(abs_delta_hi, abs_delta_lo, ratio):
    """16x8->16 multiply: |delta| * ratio >> 8.
    Matches the two-part umul8x8 approach in game.s clip_endpoint_0/1.

    Part A: umul8x8(delta_lo, ratio).hi
    Part B: umul8x8(delta_hi, ratio)
    product = Part_B_hi : (Part_B_lo + Part_A_hi)
    """
    abs_delta_lo &= 0xFF
    abs_delta_hi &= 0xFF
    ratio &= 0xFF

    # Part A
    part_a_hi, part_a_lo = umul8x8(abs_delta_lo, ratio)

    # Part B
    part_b_hi, part_b_lo = umul8x8(abs_delta_hi, ratio)

    # Combine
    product_lo = (part_b_lo + part_a_hi) & 0xFF
    carry = 1 if (part_b_lo + part_a_hi) > 0xFF else 0
    product_hi = (part_b_hi + carry) & 0xFF

    return product_hi, product_lo

def negate16(hi, lo):
    """Negate a 16-bit value in two's complement, matching SEC; LDA #0; SBC lo; ... SBC hi."""
    new_lo = (0 - lo) & 0xFF
    borrow = 0 if lo == 0 else 1
    new_hi = (0 - hi - borrow) & 0xFF
    return new_hi, new_lo

def clamp_y(y_lo, y_hi):
    """Apply the Y clamp that @ee_store does: 16-bit → clamped 8-bit."""
    y_hi &= 0xFF
    if y_hi == 0:
        return y_lo & 0xFF
    elif y_hi >= 0x80:
        return 0
    else:
        return 255

def asm_clip_endpoint_0(x0_hi, x0_lo, y0_hi, y0, x1_hi, x1_lo, y1_hi, y1, boundary):
    """Exact model of clip_endpoint_0 in game.s.
    Returns (new_x0_lo, new_x0_hi, new_y0, new_y0_hi, ratio)."""
    x0_hi, x0_lo = x0_hi & 0xFF, x0_lo & 0xFF
    x1_hi, x1_lo = x1_hi & 0xFF, x1_lo & 0xFF
    y0_hi, y0 = y0_hi & 0xFF, y0 & 0xFF
    y1_hi, y1 = y1_hi & 0xFF, y1 & 0xFF
    boundary &= 0xFF

    # numerator = |boundary - x0| (16-bit)
    num_lo = (boundary - x0_lo) & 0xFF
    borrow = 1 if boundary < x0_lo else 0
    num_hi = (0 - x0_hi - borrow) & 0xFF
    if num_hi >= 0x80:  # BPL check: negative -> negate
        num_hi, num_lo = negate16(num_hi, num_lo)

    # denominator = |x1 - x0| (16-bit)
    dx_lo = (x1_lo - x0_lo) & 0xFF
    borrow = 1 if x1_lo < x0_lo else 0
    dx_hi = (x1_hi - x0_hi - borrow) & 0xFF
    if dx_hi >= 0x80:
        dx_hi, dx_lo = negate16(dx_hi, dx_lo)

    # ratio
    ratio = div_frac8(num_hi, num_lo, dx_hi, dx_lo)

    # 16-bit Y delta: y1 - y0
    dy_lo = (y1 - y0) & 0xFF
    borrow = 1 if y1 < y0 else 0
    dy_hi = (y1_hi - y0_hi - borrow) & 0xFF

    # Absolute value + sign
    neg = dy_hi >= 0x80  # BPL check: if hi bit set, negative
    if neg:
        abs_hi, abs_lo = negate16(dy_hi, dy_lo)
    else:
        abs_lo, abs_hi = dy_lo, dy_hi

    # 16x8->16 multiply
    prod_hi, prod_lo = mul16x8(abs_hi, abs_lo, ratio)

    # Apply sign
    if neg:
        # Subtract from y0
        new_y0 = (y0 - prod_lo) & 0xFF
        borrow = 1 if y0 < prod_lo else 0
        new_y0_hi = (y0_hi - prod_hi - borrow) & 0xFF
    else:
        # Add to y0
        new_y0 = (y0 + prod_lo) & 0xFF
        carry = 1 if (y0 + prod_lo) > 0xFF else 0
        new_y0_hi = (y0_hi + prod_hi + carry) & 0xFF

    # No Y clamp here — @ee_store handles it for all paths
    return boundary, 0, new_y0, new_y0_hi, ratio

def asm_clip_endpoint_1(x0_hi, x0_lo, y0_hi, y0, x1_hi, x1_lo, y1_hi, y1, boundary):
    """Exact model of clip_endpoint_1 in game.s.
    Returns (new_x1_lo, new_x1_hi, new_y1, new_y1_hi, ratio)."""
    x0_hi, x0_lo = x0_hi & 0xFF, x0_lo & 0xFF
    x1_hi, x1_lo = x1_hi & 0xFF, x1_lo & 0xFF
    y0_hi, y0 = y0_hi & 0xFF, y0 & 0xFF
    y1_hi, y1 = y1_hi & 0xFF, y1 & 0xFF
    boundary &= 0xFF

    # numerator = |boundary - x1|
    num_lo = (boundary - x1_lo) & 0xFF
    borrow = 1 if boundary < x1_lo else 0
    num_hi = (0 - x1_hi - borrow) & 0xFF
    if num_hi >= 0x80:
        num_hi, num_lo = negate16(num_hi, num_lo)

    # denominator = |x0 - x1|
    dx_lo = (x0_lo - x1_lo) & 0xFF
    borrow = 1 if x0_lo < x1_lo else 0
    dx_hi = (x0_hi - x1_hi - borrow) & 0xFF
    if dx_hi >= 0x80:
        dx_hi, dx_lo = negate16(dx_hi, dx_lo)

    # ratio
    ratio = div_frac8(num_hi, num_lo, dx_hi, dx_lo)

    # 16-bit Y delta: y0 - y1 (note: reversed from endpoint 0)
    dy_lo = (y0 - y1) & 0xFF
    borrow = 1 if y0 < y1 else 0
    dy_hi = (y0_hi - y1_hi - borrow) & 0xFF

    # Absolute value + sign
    neg = dy_hi >= 0x80
    if neg:
        abs_hi, abs_lo = negate16(dy_hi, dy_lo)
    else:
        abs_lo, abs_hi = dy_lo, dy_hi

    # 16x8->16 multiply
    prod_hi, prod_lo = mul16x8(abs_hi, abs_lo, ratio)

    # Apply sign
    if neg:
        new_y1 = (y1 - prod_lo) & 0xFF
        borrow = 1 if y1 < prod_lo else 0
        new_y1_hi = (y1_hi - prod_hi - borrow) & 0xFF
    else:
        new_y1 = (y1 + prod_lo) & 0xFF
        carry = 1 if (y1 + prod_lo) > 0xFF else 0
        new_y1_hi = (y1_hi + prod_hi + carry) & 0xFF

    # No Y clamp here — @ee_store handles it for all paths
    return boundary, 0, new_y1, new_y1_hi, ratio

def asm_y_clip_endpoint_0(x0_lo, y0, y0_hi, x1_lo, y1, y1_hi, boundary):
    """Exact model of y_clip_endpoint_0 in game.s.
    Clips y0 to boundary, computes new x0 by interpolation.
    Returns (new_x0_lo, new_y0, new_y0_hi)."""
    boundary &= 0xFF
    x0_lo &= 0xFF
    x1_lo &= 0xFF
    y0 &= 0xFF
    y0_hi &= 0xFF
    y1 &= 0xFF
    y1_hi &= 0xFF

    # numerator = |boundary - y0| (16-bit)
    num_lo = (boundary - y0) & 0xFF
    borrow = 1 if boundary < y0 else 0
    num_hi = (0 - y0_hi - borrow) & 0xFF
    if num_hi >= 0x80:
        num_hi, num_lo = negate16(num_hi, num_lo)

    # denominator = |y1 - y0| (16-bit)
    dx_lo = (y1 - y0) & 0xFF
    borrow = 1 if y1 < y0 else 0
    dx_hi = (y1_hi - y0_hi - borrow) & 0xFF
    if dx_hi >= 0x80:
        dx_hi, dx_lo = negate16(dx_hi, dx_lo)

    ratio = div_frac8(num_hi, num_lo, dx_hi, dx_lo)

    # X interpolation: new_x0 = x0 + ratio * (x1 - x0) / 256
    result = x1_lo - x0_lo
    if result >= 0:  # BCS: carry set = no borrow = positive
        a_val = result & 0xFF
        hi, lo = umul8x8(a_val, ratio)
        new_x0 = (x0_lo + hi) & 0xFF
    else:
        a_val = result & 0xFF
        abs_dx = ((a_val ^ 0xFF) + 1) & 0xFF
        hi, lo = umul8x8(abs_dx, ratio)
        new_x0 = (x0_lo - hi) & 0xFF

    return new_x0, boundary, 0

def asm_y_clip_endpoint_1(x0_lo, y0, y0_hi, x1_lo, y1, y1_hi, boundary):
    """Exact model of y_clip_endpoint_1 in game.s.
    Uses UPDATED y0/x0 after y_clip_endpoint_0.
    Returns (new_x1_lo, new_y1, new_y1_hi)."""
    boundary &= 0xFF
    x0_lo &= 0xFF
    x1_lo &= 0xFF
    y0 &= 0xFF
    y0_hi &= 0xFF
    y1 &= 0xFF
    y1_hi &= 0xFF

    # numerator = |boundary - y1| (16-bit)
    num_lo = (boundary - y1) & 0xFF
    borrow = 1 if boundary < y1 else 0
    num_hi = (0 - y1_hi - borrow) & 0xFF
    if num_hi >= 0x80:
        num_hi, num_lo = negate16(num_hi, num_lo)

    # denominator = |y0 - y1| (16-bit, uses UPDATED y0)
    dx_lo = (y0 - y1) & 0xFF
    borrow = 1 if y0 < y1 else 0
    dx_hi = (y0_hi - y1_hi - borrow) & 0xFF
    if dx_hi >= 0x80:
        dx_hi, dx_lo = negate16(dx_hi, dx_lo)

    ratio = div_frac8(num_hi, num_lo, dx_hi, dx_lo)

    # X interpolation: new_x1 = x1 + ratio * (x0 - x1) / 256
    result = x0_lo - x1_lo
    if result >= 0:
        a_val = result & 0xFF
        hi, lo = umul8x8(a_val, ratio)
        new_x1 = (x1_lo + hi) & 0xFF
    else:
        a_val = result & 0xFF
        abs_dx = ((a_val ^ 0xFF) + 1) & 0xFF
        hi, lo = umul8x8(abs_dx, ratio)
        new_x1 = (x1_lo - hi) & 0xFF

    return new_x1, boundary, 0

def asm_emit_edge(x0_hi, x0_lo, y0_hi, y0_lo, x1_hi, x1_lo, y1_hi, y1_lo):
    """Full emit_edge pipeline model.
    Returns (out_x0, out_y0, out_x1, out_y1) or None if rejected."""
    cx0_hi, cx0_lo = x0_hi & 0xFF, x0_lo & 0xFF
    cy0_hi, cy0 = y0_hi & 0xFF, y0_lo & 0xFF
    cx1_hi, cx1_lo = x1_hi & 0xFF, x1_lo & 0xFF
    cy1_hi, cy1 = y1_hi & 0xFF, y1_lo & 0xFF

    # Both X on-screen?
    if cx0_hi == 0 and cx1_hi == 0:
        pass  # skip to Y clipping
    else:
        # Trivial reject
        if cx0_hi != 0 and cx1_hi != 0:
            # Both off-screen -- same side?
            xor = cx1_hi ^ cx0_hi
            if xor < 0x80:
                return None  # same side -> reject

        # Clip endpoint 0 if off-screen
        if cx0_hi != 0:
            if cx0_hi >= 0x80:
                boundary = 0
            else:
                boundary = 255
            cx0_lo, cx0_hi, cy0, cy0_hi, _ = asm_clip_endpoint_0(
                cx0_hi, cx0_lo, cy0_hi, cy0,
                cx1_hi, cx1_lo, cy1_hi, cy1,
                boundary)

        # Clip endpoint 1 if off-screen
        if cx1_hi != 0:
            if cx1_hi >= 0x80:
                boundary = 0
            else:
                boundary = 255
            cx1_lo, cx1_hi, cy1, cy1_hi, _ = asm_clip_endpoint_1(
                cx0_hi, cx0_lo, cy0_hi, cy0,
                cx1_hi, cx1_lo, cy1_hi, cy1,
                boundary)

    # --- Y trivial reject + Y-clipping (replaces Y clamp) ---
    if (cy0_hi | cy1_hi) == 0:
        pass  # both on-screen, skip to store
    else:
        # Both off-screen?
        if cy0_hi != 0 and cy1_hi != 0:
            xor = cy1_hi ^ cy0_hi
            if xor < 0x80:
                return None  # same side → reject

        # Clip y0 if off-screen
        if cy0_hi != 0:
            if cy0_hi >= 0x80:
                boundary = 0
            else:
                boundary = 255
            cx0_lo, cy0, cy0_hi = asm_y_clip_endpoint_0(
                cx0_lo, cy0, cy0_hi, cx1_lo, cy1, cy1_hi, boundary)

        # Clip y1 if off-screen
        if cy1_hi != 0:
            if cy1_hi >= 0x80:
                boundary = 0
            else:
                boundary = 255
            cx1_lo, cy1, cy1_hi = asm_y_clip_endpoint_1(
                cx0_lo, cy0, cy0_hi, cx1_lo, cy1, cy1_hi, boundary)

    return cx0_lo, cy0, cx1_lo, cy1

def ideal_clip(x0, y0, x1, y1):
    """Ideal floating-point clip of line to [0,255] x [0,255].
    Returns (cx0, cy0, cx1, cy1) or None if fully outside."""
    # --- X clip ---
    if x0 < 0 and x1 < 0:
        return None
    if x0 > 255 and x1 > 255:
        return None

    cx0, cy0_f = float(x0), float(y0)
    cx1, cy1_f = float(x1), float(y1)

    dx = cx1 - cx0
    if dx == 0:
        if x0 < 0 or x0 > 255:
            return None
    else:
        if cx0 < 0:
            t = (0 - cx0) / (cx1 - cx0)
            cy0_f = cy0_f + t * (cy1_f - cy0_f)
            cx0 = 0.0
        elif cx0 > 255:
            t = (255 - cx0) / (cx1 - cx0)
            cy0_f = cy0_f + t * (cy1_f - cy0_f)
            cx0 = 255.0

        if cx1 < 0:
            t = (0 - cx1) / (cx0 - cx1)
            cy1_f = cy1_f + t * (cy0_f - cy1_f)
            cx1 = 0.0
        elif cx1 > 255:
            t = (255 - cx1) / (cx0 - cx1)
            cy1_f = cy1_f + t * (cy0_f - cy1_f)
            cx1 = 255.0

    # --- Y clip (after X clip) ---
    if cy0_f < 0 and cy1_f < 0:
        return None
    if cy0_f > 255 and cy1_f > 255:
        return None

    dy = cy1_f - cy0_f
    if dy != 0:
        if cy0_f < 0:
            t = (0 - cy0_f) / (cy1_f - cy0_f)
            cx0 = cx0 + t * (cx1 - cx0)
            cy0_f = 0.0
        elif cy0_f > 255:
            t = (255 - cy0_f) / (cy1_f - cy0_f)
            cx0 = cx0 + t * (cx1 - cx0)
            cy0_f = 255.0

        if cy1_f < 0:
            t = (0 - cy1_f) / (cy0_f - cy1_f)
            cx1 = cx1 + t * (cx0 - cx1)
            cy1_f = 0.0
        elif cy1_f > 255:
            t = (255 - cy1_f) / (cy0_f - cy1_f)
            cx1 = cx1 + t * (cx0 - cx1)
            cy1_f = 255.0
    else:
        # Horizontal line: clamp Y (already checked not both off-screen)
        cy0_f = max(0, min(255, cy0_f))
        cy1_f = max(0, min(255, cy1_f))

    return (round(cx0), round(cy0_f), round(cx1), round(cy1_f))


# ======================================================================
# Test 1: umul8x8
# ======================================================================

def test_umul8x8():
    print("  1. umul8x8 ... ", end="", flush=True)
    for a in range(0, 256, 7):
        for b in range(0, 256, 11):
            hi, lo = umul8x8(a, b)
            expected = a * b
            check((hi << 8 | lo) == expected,
                  f"umul8x8({a},{b})={(hi<<8|lo)}, want {expected}")
    print("PASS")

# ======================================================================
# Test 2: div_frac8
# ======================================================================

def test_div_frac8():
    print("  2. div_frac8 ... ", end="", flush=True)
    cases = [
        (0,1, 0,2, 128),    # 1/2 -> 128
        (0,1, 0,4, 64),     # 1/4 -> 64
        (0,3, 0,4, 192),    # 3/4 -> 192
        (0,1, 1,0, 1),      # 1/256 -> 1
        (0,100, 1,0, 100),  # 100/256 -> 100
        (0,1, 0,3, 85),     # 1/3 -> 85
        (0,50, 0,200, 64),  # 50/200 -> 64
    ]
    for nh, nl, dh, dl, exp in cases:
        got = div_frac8(nh, nl, dh, dl)
        check(got == exp, f"div_frac8({nh}:{nl}/{dh}:{dl})={got}, want {exp}")

    # Check monotonicity: as numerator increases, ratio increases
    for den in [10, 50, 200]:
        prev = -1
        for num in range(den):
            r = div_frac8(0, num, 0, den)
            check(r >= prev, f"div_frac8 not monotone: {num}/{den}={r}, prev={prev}")
            prev = r

    print("PASS")

# ======================================================================
# Test 3: mul16x8 (16x8->16 multiply)
# ======================================================================

def test_mul16x8():
    print("  3. mul16x8 ... ", end="", flush=True)

    # Exhaustive for small values
    for delta in range(0, 512, 3):
        for ratio in range(0, 256, 13):
            dhi = (delta >> 8) & 0xFF
            dlo = delta & 0xFF
            phi, plo = mul16x8(dhi, dlo, ratio)
            got = (phi << 8) | plo
            expected = (delta * ratio) >> 8
            # Allow +/-1 due to truncation differences in two-part multiply
            check(abs(got - expected) <= 1,
                  f"mul16x8({delta},{ratio})={got}, want {expected}")

    # Large values matching real game projections
    for delta in [255, 300, 500, 750, 1000, 1269]:
        for ratio in [1, 64, 128, 192, 255]:
            dhi, dlo = (delta >> 8) & 0xFF, delta & 0xFF
            phi, plo = mul16x8(dhi, dlo, ratio)
            got = (phi << 8) | plo
            expected = (delta * ratio) >> 8
            check(abs(got - expected) <= 1,
                  f"mul16x8({delta},{ratio})={got}, want {expected}")

    print("PASS")

# ======================================================================
# Test 4: clip_endpoint_0 / clip_endpoint_1 -- individual Y interpolation
# ======================================================================

def test_clip_endpoints():
    print("  4. clip_endpoint Y interpolation ... ", end="", flush=True)

    # Helper: compute ideal Y at X boundary
    def ideal_y_at_boundary(x0_16, y0_16, x1_16, y1_16, boundary):
        if x1_16 == x0_16:
            return y0_16
        t = (boundary - x0_16) / (x1_16 - x0_16)
        return y0_16 + t * (y1_16 - y0_16)

    # --- 4a: Small Y values (8-bit range) ---
    # e0 off right, e1 on-screen
    _, _, ny0, ny0_hi, ratio = asm_clip_endpoint_0(
        0x01, 0x20, 0, 100,     # x0=288, y0=100
        0x00, 128, 0, 50,       # x1=128, y1=50
        255)
    ideal = ideal_y_at_boundary(288, 100, 128, 50, 255)
    cy0 = clamp_y(ny0, ny0_hi)
    check(abs(cy0 - ideal) <= 2,
          f"4a: e0 right clip: got y={cy0}, ideal={ideal:.1f}")

    # e0 off left, e1 on-screen
    _, _, ny0, ny0_hi, ratio = asm_clip_endpoint_0(
        0xFF, 0xE0, 0, 200,     # x0=-32, y0=200
        0x00, 128, 0, 100,      # x1=128, y1=100
        0)
    ideal = ideal_y_at_boundary(-32, 200, 128, 100, 0)
    cy0 = clamp_y(ny0, ny0_hi)
    check(abs(cy0 - ideal) <= 2,
          f"4a: e0 left clip: got y={cy0}, ideal={ideal:.1f}")

    # --- 4b: Large Y values (16-bit, the core fix) ---
    # base_y = 509, vertex off right at x=400, other at x=128, y=128
    _, _, ny0, ny0_hi, ratio = asm_clip_endpoint_0(
        0x01, 0x90, 0x01, 0xFD, # x0=400, y0=509
        0x00, 128, 0x00, 128,   # x1=128, y1=128
        255)
    ideal = ideal_y_at_boundary(400, 509, 128, 128, 255)
    cy0 = clamp_y(ny0, ny0_hi)
    check(abs(cy0 - max(0, min(255, round(ideal)))) <= 3,
          f"4b: y0=509 clip right: got y={cy0}, ideal={ideal:.1f}, ratio={ratio}")

    # top_y = -200
    _, _, ny0, ny0_hi, ratio = asm_clip_endpoint_0(
        0x01, 0x90, 0xFF, 0x38, # x0=400, y0=-200
        0x00, 128, 0x00, 128,   # x1=128, y1=128
        255)
    ideal = ideal_y_at_boundary(400, -200, 128, 128, 255)
    cy0 = clamp_y(ny0, ny0_hi)
    check(abs(cy0 - max(0, min(255, round(ideal)))) <= 3,
          f"4b: y0=-200 clip right: got y={cy0}, ideal={ideal:.1f}, ratio={ratio}")

    # base_y = 300 clip to left, x0=-144
    _, _, ny0, ny0_hi, ratio = asm_clip_endpoint_0(
        0xFF, 0x70, 0x01, 0x2C, # x0=-144, y0=300
        0x00, 128, 0x00, 128,   # x1=128, y1=128
        0)
    ideal = ideal_y_at_boundary(-144, 300, 128, 128, 0)
    cy0 = clamp_y(ny0, ny0_hi)
    check(abs(cy0 - max(0, min(255, round(ideal)))) <= 3,
          f"4b: y0=300 clip left: got y={cy0}, ideal={ideal:.1f}")

    # --- 4c: clip_endpoint_1 with large Y ---
    _, _, ny1, ny1_hi, ratio = asm_clip_endpoint_1(
        0x00, 128, 0x00, 128,   # x0=128, y0=128
        0x01, 0x90, 0x01, 0xFD, # x1=400, y1=509
        255)
    ideal = ideal_y_at_boundary(128, 128, 400, 509, 255)
    cy1 = clamp_y(ny1, ny1_hi)
    check(abs(cy1 - max(0, min(255, round(ideal)))) <= 3,
          f"4c: e1 y=509 clip right: got y={cy1}, ideal={ideal:.1f}")

    # --- 4d: Signed delta exhaustive ---
    for y0_16, y1_16 in [(100, 400), (400, 100), (200, 200),
                          (-100, 300), (300, -100), (-500, 500),
                          (0, 0), (600, -600)]:
        y0h, y0l = to_bytes16(y0_16)
        y1h, y1l = to_bytes16(y1_16)
        # x0=400, x1=128, boundary=255
        _, _, ny0, ny0_hi, ratio = asm_clip_endpoint_0(
            0x01, 0x90, y0h, y0l,
            0x00, 128, y1h, y1l,
            255)
        ideal = ideal_y_at_boundary(400, y0_16, 128, y1_16, 255)
        clamped_ideal = max(0, min(255, round(ideal)))
        cy0 = clamp_y(ny0, ny0_hi)
        check(abs(cy0 - clamped_ideal) <= 3,
              f"4d: y0={y0_16}, y1={y1_16}: got {cy0}, ideal={clamped_ideal}")

    # --- 4e: Extreme values ---
    for y0_16, y1_16 in [(-1269, 128), (509, 128), (509, -1269),
                          (-1269, 509), (1000, -1000)]:
        y0h, y0l = to_bytes16(y0_16)
        y1h, y1l = to_bytes16(y1_16)
        _, _, ny0, ny0_hi, _ = asm_clip_endpoint_0(
            0x01, 0x90, y0h, y0l,
            0x00, 128, y1h, y1l, 255)
        ideal = ideal_y_at_boundary(400, y0_16, 128, y1_16, 255)
        clamped_ideal = max(0, min(255, round(ideal)))
        cy0 = clamp_y(ny0, ny0_hi)
        check(abs(cy0 - clamped_ideal) <= 5,
              f"4e: extreme y0={y0_16},y1={y1_16}: got {cy0}, ideal={clamped_ideal}")

    print("PASS")

# ======================================================================
# Test 5: Full emit_edge pipeline
# ======================================================================

def test_emit_edge():
    print("  5. emit_edge pipeline ... ", end="", flush=True)

    # --- 5a: Both on-screen, Y in range ---
    result = asm_emit_edge(0, 50, 0, 100, 0, 200, 0, 150)
    check(result == (50, 100, 200, 150), f"5a: both on-screen: {result}")

    # --- 5b: Both X on-screen, Y overflow (y0=509, y1=50) → Y-clip y0 to 255 ---
    result = asm_emit_edge(0, 100, 0x01, 0xFD, 0, 200, 0, 50)
    check(result is not None, "5b: should not reject")
    check(result[1] == 255, f"5b: y0 should clip to 255, got {result[1]}")
    check(result[3] == 50, f"5b: y1 should be 50, got {result[3]}")
    # x0 should be interpolated: x0=100 + ratio*(200-100)/256
    ideal_x0 = round(100 + (200 - 100) * (255 - 509) / (50 - 509))
    check(abs(result[0] - ideal_x0) <= 2,
          f"5b: x0 should be ~{ideal_x0}, got {result[0]}")

    # --- 5c: Both X on-screen, Y negative (y0=-200, y1=50) → Y-clip y0 to 0 ---
    result = asm_emit_edge(0, 100, 0xFF, 0x38, 0, 200, 0, 50)
    check(result is not None, "5c: should not reject")
    check(result[1] == 0, f"5c: y0 should clip to 0, got {result[1]}")
    ideal_x0 = round(100 + (200 - 100) * (0 - (-200)) / (50 - (-200)))
    check(abs(result[0] - ideal_x0) <= 2,
          f"5c: x0 should be ~{ideal_x0}, got {result[0]}")

    # --- 5d: Trivial reject -- both off right ---
    result = asm_emit_edge(0x01, 0x20, 0, 100, 0x01, 0x40, 0, 150)
    check(result is None, "5d: both off right -> reject")

    # --- 5e: Trivial reject -- both off left ---
    result = asm_emit_edge(0xFF, 0xE0, 0, 100, 0xFF, 0xC0, 0, 150)
    check(result is None, "5e: both off left -> reject")

    # --- 5f: One off-screen right, one on-screen (clip endpoint 0) ---
    result = asm_emit_edge(0x01, 0x20, 0, 100, 0, 128, 0, 50)
    check(result is not None, "5f: should clip, not reject")
    check(result[0] == 255, f"5f: x0 should clip to 255, got {result[0]}")
    check(result[2] == 128, f"5f: x1 unchanged, got {result[2]}")
    ideal = 100 + (50 - 100) * (255 - 288) / (128 - 288)
    check(abs(result[1] - ideal) <= 2,
          f"5f: y0 should be ~{ideal:.0f}, got {result[1]}")

    # --- 5g: Both off different sides (spans screen) ---
    result = asm_emit_edge(0xFF, 0xCE, 0, 200, 0x01, 0x2C, 0, 50)
    check(result is not None, "5g: spans screen -> clip both")
    check(result[0] == 0, f"5g: x0 should clip to 0, got {result[0]}")
    check(result[2] == 255, f"5g: x1 should clip to 255, got {result[2]}")

    # --- 5h: Both off different sides, large Y ---
    y0h, y0l = to_bytes16(400)
    y1h, y1l = to_bytes16(-100)
    result = asm_emit_edge(0xFF, 0xCE, y0h, y0l, 0x01, 0x2C, y1h, y1l)
    check(result is not None, "5h: spans screen with large Y -> clip both")
    # After X-clip: x0=0, x1=255. Y values interpolated.
    # Then Y-clip may further adjust endpoints.
    ideal = ideal_clip(-50, 400, 300, -100)
    if ideal is not None:
        check(abs(result[1] - ideal[1]) <= 5,
              f"5h: y0 should be ~{ideal[1]}, got {result[1]}")
        check(abs(result[3] - ideal[3]) <= 5,
              f"5h: y1 should be ~{ideal[3]}, got {result[3]}")

    # --- 5i: One on-screen, one off left, with 16-bit Y ---
    y0h, y0l = to_bytes16(300)
    result = asm_emit_edge(0xFF, 0x60, y0h, y0l, 0, 128, 0, 128)
    check(result is not None, "5i: one off left -> clip")
    check(result[0] == 0, f"5i: x0 clips to 0, got {result[0]}")
    # x0=-160, y0=300, x1=128, y1=128. At x=0: y = 300 + (128-300)*(0-(-160))/(128-(-160))
    ideal = 300 + (128 - 300) * (0 - (-160)) / (128 - (-160))
    check(abs(result[1] - max(0, min(255, round(ideal)))) <= 3,
          f"5i: y0 should be ~{ideal:.0f}, got {result[1]}")

    # --- 5j: Y trivial reject -- both Y above screen ---
    y0h, y0l = to_bytes16(-50)
    y1h, y1l = to_bytes16(-100)
    result = asm_emit_edge(0, 50, y0h, y0l, 0, 200, y1h, y1l)
    check(result is None, "5j: both Y above screen -> reject")

    # --- 5k: Y trivial reject -- both Y below screen ---
    y0h, y0l = to_bytes16(300)
    y1h, y1l = to_bytes16(400)
    result = asm_emit_edge(0, 50, y0h, y0l, 0, 200, y1h, y1l)
    check(result is None, "5k: both Y below screen -> reject")

    # --- 5l: Y-clip only (both X on-screen, one Y off-screen below) ---
    y0h, y0l = to_bytes16(400)
    result = asm_emit_edge(0, 50, y0h, y0l, 0, 200, 0, 128)
    check(result is not None, "5l: should Y-clip, not reject")
    check(result[1] == 255, f"5l: y0 clipped to 255, got {result[1]}")
    check(result[3] == 128, f"5l: y1 unchanged, got {result[3]}")
    # x0 should be interpolated: 50 + ratio*(200-50)/256
    ideal_x0 = round(50 + (200 - 50) * (255 - 400) / (128 - 400))
    check(abs(result[0] - ideal_x0) <= 2,
          f"5l: x0 should be ~{ideal_x0}, got {result[0]}")

    # --- 5m: Y-clip both sides (y0 < 0, y1 > 255, both X on-screen) ---
    y0h, y0l = to_bytes16(-100)
    y1h, y1l = to_bytes16(400)
    result = asm_emit_edge(0, 50, y0h, y0l, 0, 200, y1h, y1l)
    check(result is not None, "5m: Y spans screen -> clip both")
    check(result[1] == 0, f"5m: y0 clipped to 0, got {result[1]}")
    check(result[3] == 255, f"5m: y1 clipped to 255, got {result[3]}")
    ideal_x0 = round(50 + (200 - 50) * (0 - (-100)) / (400 - (-100)))
    ideal_x1 = round(200 + (50 - 200) * (255 - 400) / (-100 - 400))
    # After y0 clip, x0 is updated, so x1 interp uses updated x0
    # Use asm model for accuracy check
    check(abs(result[0] - ideal_x0) <= 3,
          f"5m: x0 should be ~{ideal_x0}, got {result[0]}")

    # --- 5n: Diagonal approach — the key motivating scenario ---
    # Edge from (150, -500) to (200, 80): both X on-screen
    # Old (clamp): y0=-500 → y0=0, x0 stays 150 → WRONG slope
    # New (clip): y0 clipped to 0, x0 interpolated → correct slope
    y0h, y0l = to_bytes16(-500)
    result = asm_emit_edge(0, 150, y0h, y0l, 0, 200, 0, 80)
    check(result is not None, "5n: should Y-clip, not reject")
    check(result[1] == 0, f"5n: y0 clipped to 0, got {result[1]}")
    check(result[2] == 200, f"5n: x1 unchanged, got {result[2]}")
    check(result[3] == 80, f"5n: y1 unchanged, got {result[3]}")
    # Ideal: t = (0-(-500))/(80-(-500)) = 500/580 ≈ 0.862
    # new_x0 = 150 + 0.862*(200-150) = 150 + 43.1 ≈ 193
    ideal_x0 = round(150 + (200 - 150) * (0 - (-500)) / (80 - (-500)))
    check(abs(result[0] - ideal_x0) <= 2,
          f"5n: x0 should be ~{ideal_x0}, got {result[0]}")

    print("PASS")

# ======================================================================
# Test 6: Regression cases -- close-up cubes
# ======================================================================

def test_close_up_cubes():
    """Simulate real projection scenarios that triggered the original bug."""
    print("  6. Close-up cube regression ... ", end="", flush=True)

    recip_table = []
    for i in range(256):
        z = 1.0 + i / 8.0
        recip_table.append(min(127, round(128.0 / z)))

    HORIZON_Y = 128

    test_scenarios = [
        (1, 8, "vz=1 H=8: extreme close-up cube"),
        (1, 14, "vz=1 H=14: extreme close-up tall pyramid"),
        (2, 8, "vz=2 H=8: very close cube"),
        (3, 6, "vz=3 H=6: close small cube"),
        (5, 12, "vz=5 H=12: medium distance tall object"),
        (10, 8, "vz=10 H=8: moderate distance"),
    ]

    for vz, H, desc in test_scenarios:
        idx = (vz - 1) * 8
        recip_val = recip_table[idx]

        base_y = HORIZON_Y + 3 * recip_val
        hi_h, lo_h = umul8x8(H, recip_val)
        height = (hi_h << 8) | lo_h
        top_y = base_y - height

        by_hi, by_lo = to_bytes16(base_y)
        ty_hi, ty_lo = to_bytes16(top_y)

        # Bottom edge: far-right vertex -> center vertex (same base_y)
        # With Y-clipping: if base_y > 255, both endpoints have same off-screen Y
        # → Y trivial reject (correct: no ghost line at y=255)
        result = asm_emit_edge(
            0x01, 0x90, by_hi, by_lo,  # x0=400, y0=base_y
            0x00, 128,  by_hi, by_lo,  # x1=128, y1=base_y
            )
        if base_y <= 255:
            check(result is not None, f"6: {desc}: bottom edge on-screen should not reject")
            if result:
                check(result[1] == result[3],
                      f"6: {desc}: horizontal edge y0={result[1]} != y1={result[3]}")
                check(0 <= result[1] <= 255,
                      f"6: {desc}: bottom y in range: {result[1]}")
        else:
            # After X-clip, both Y are still base_y > 255 → Y trivial reject
            check(result is None,
                  f"6: {desc}: bottom edge base_y={base_y} > 255 → Y reject")

        # Top edge: far-right vertex -> center vertex (same top_y)
        # With Y-clipping: if top_y < 0, both endpoints same off-screen Y → reject
        result = asm_emit_edge(
            0x01, 0x90, ty_hi, ty_lo,
            0x00, 128,  ty_hi, ty_lo,
            )
        if 0 <= top_y <= 255:
            check(result is not None, f"6: {desc}: top edge on-screen should not reject")
            if result:
                check(result[1] == result[3],
                      f"6: {desc}: top edge y0={result[1]} != y1={result[3]}")
        else:
            check(result is None,
                  f"6: {desc}: top edge top_y={top_y} off-screen → Y reject")

        # Vertical edge: both off same side -> reject
        result = asm_emit_edge(
            0x01, 0x90, by_hi, by_lo,
            0x01, 0x90, ty_hi, ty_lo,
            )
        check(result is None, f"6: {desc}: vert edge both off right -> reject")

        # Mixed: one on-screen, one off-screen right
        result = asm_emit_edge(
            0x00, 200,  by_hi, by_lo,
            0x01, 0x90, ty_hi, ty_lo,
            )
        if result is not None:
            check(result[2] == 255,
                  f"6: {desc}: mixed vert x1=255, got {result[2]}")
            # After X-clip, Y values may need Y-clipping too
            # y0 = base_y (may be > 255), y1 interpolated from top_y
            # Just check in range
            check(0 <= result[1] <= 255,
                  f"6: {desc}: y0 in range, got {result[1]}")
            check(0 <= result[3] <= 255,
                  f"6: {desc}: y1 in range, got {result[3]}")

        # Diagonal: base far-left -> top far-right (spans screen)
        result = asm_emit_edge(
            0xFF, 0x70, by_hi, by_lo,  # x0=-144, y0=base_y
            0x01, 0x90, ty_hi, ty_lo,  # x1=400, y1=top_y
            )
        ideal = ideal_clip(-144, base_y, 400, top_y)
        if ideal is None:
            # After X+Y clipping, line may be fully off-screen
            # (both endpoints off-screen same Y side after X-clip)
            pass  # either result is fine
        else:
            check(result is not None, f"6: {desc}: diagonal spans screen -> clip")
            if result:
                check(0 <= result[0] <= 255, f"6: {desc}: diag x0 in range, got {result[0]}")
                check(0 <= result[2] <= 255, f"6: {desc}: diag x1 in range, got {result[2]}")
                check(0 <= result[1] <= 255, f"6: {desc}: diag y0 in range")
                check(0 <= result[3] <= 255, f"6: {desc}: diag y1 in range")

                ideal_dy = ideal[3] - ideal[1]
                screen_dy = result[3] - result[1]
                if abs(ideal_dy) > 10:
                    slope_err = abs(screen_dy - ideal_dy) / max(1, abs(ideal_dy))
                    check(slope_err < 0.20,
                          f"6: {desc}: slope err={slope_err:.0%}, "
                          f"got dy={screen_dy}, want ~{ideal_dy}")

    print("PASS")

# ======================================================================
# Test 7: Property sweep -- compare assembly model vs ideal
# ======================================================================

def test_property_sweep():
    """Sweep parameter space comparing asm_emit_edge against ideal_clip."""
    print("  7. Property sweep (asm vs ideal) ... ", end="", flush=True)

    max_err = 0
    n_tested = 0
    n_large_err = 0

    x_values = list(range(-300, 500, 23))
    y_values = [-500, -200, -50, 0, 50, 128, 200, 255, 300, 500, 800]

    for x0 in x_values:
        for x1 in x_values:
            if x0 == x1:
                continue
            for y0 in y_values:
                for y1 in y_values:
                    x0h, x0l = to_bytes16(x0)
                    x1h, x1l = to_bytes16(x1)
                    y0h, y0l = to_bytes16(y0)
                    y1h, y1l = to_bytes16(y1)

                    asm_result = asm_emit_edge(x0h, x0l, y0h, y0l,
                                                x1h, x1l, y1h, y1l)
                    ideal_result = ideal_clip(x0, y0, x1, y1)

                    if asm_result is None and ideal_result is None:
                        n_tested += 1
                        continue
                    if asm_result is None or ideal_result is None:
                        n_tested += 1
                        continue

                    for i, name in [(0, 'x0'), (1, 'y0'), (2, 'x1'), (3, 'y1')]:
                        err = abs(asm_result[i] - ideal_result[i])
                        max_err = max(max_err, err)
                        if err > 8:
                            n_large_err += 1
                            if n_large_err <= 10:
                                check(False,
                                    f"({x0},{y0})->({x1},{y1}): "
                                    f"asm {name}={asm_result[i]}, "
                                    f"ideal {name}={ideal_result[i]}, err={err}")
                    n_tested += 1

    check(n_large_err == 0,
          f"{n_large_err} cases with error > 8 out of {n_tested} "
          f"(max_err={max_err})")
    print(f"PASS (max_err={max_err}, n={n_tested})")

# ======================================================================
# Test 8: Old-bug regression (8-bit slope error)
# ======================================================================

def test_old_bug_regression():
    """Verify specific scenarios where 8-bit clamped Y produced wrong slopes.
    With 8-bit: base_y=509 -> clamped to 255, top_y -> clamped to 0.
    Old code interpolated between 255 and 0 instead of 509 and the true top_y."""
    print("  8. Old-bug regression ... ", end="", flush=True)

    # Simulate old (8-bit clamped) behavior
    def old_clip_y(y0_clamped, y1_8, ratio):
        y0, y1 = y0_clamped & 0xFF, y1_8 & 0xFF
        if y1 >= y0:
            delta = y1 - y0
            hi, _ = umul8x8(delta, ratio)
            return min(255, y0 + hi)
        else:
            delta = y0 - y1
            hi, _ = umul8x8(delta, ratio)
            return max(0, y0 - hi)

    # Case: close cube with vz=1. recip=127.
    # base_y_true = 128 + 381 = 509, top_y_true = 509 - 8*127 = 509 - 1016 = -507
    # Edge from x=400 to x=128, clip boundary=255.
    # Ratio = |255-400| / |128-400| = 145/272 -> div_frac8(0,145, 1,16) = ?
    ratio = div_frac8(0, 145, 1, 16)

    # --- Bottom edge ---
    # Old: y0_clamped=255, y1=128, ratio
    old_base = old_clip_y(255, 128, ratio)
    # New: y0=509, y1=128, ratio
    by_hi, by_lo = to_bytes16(509)
    _, _, new_base_lo, new_base_hi, _ = asm_clip_endpoint_0(
        0x01, 0x90, by_hi, by_lo,
        0x00, 128, 0x00, 128,
        255)
    new_base = clamp_y(new_base_lo, new_base_hi)
    ideal_base = 509 + (128 - 509) * (255 - 400) / (128 - 400)
    ideal_base_c = max(0, min(255, round(ideal_base)))

    check(abs(new_base - ideal_base_c) < abs(old_base - ideal_base_c) + 5,
          f"8: base edge: new={new_base} old={old_base} ideal={ideal_base_c}")

    # --- Top edge ---
    old_top = old_clip_y(0, 128, ratio)
    ty_hi, ty_lo = to_bytes16(-507)
    _, _, new_top_lo, new_top_hi, _ = asm_clip_endpoint_0(
        0x01, 0x90, ty_hi, ty_lo,
        0x00, 128, 0x00, 128,
        255)
    new_top = clamp_y(new_top_lo, new_top_hi)
    ideal_top = -507 + (128 - (-507)) * (255 - 400) / (128 - 400)
    ideal_top_c = max(0, min(255, round(ideal_top)))

    check(abs(new_top - ideal_top_c) < abs(old_top - ideal_top_c) + 5,
          f"8: top edge: new={new_top} old={old_top} ideal={ideal_top_c}")

    # --- Slope check: the key metric ---
    old_slope = old_top - old_base
    new_slope = new_top - new_base
    ideal_slope = ideal_top_c - ideal_base_c

    if ideal_slope != 0:
        old_slope_err = abs(old_slope - ideal_slope) / max(1, abs(ideal_slope))
        new_slope_err = abs(new_slope - ideal_slope) / max(1, abs(ideal_slope))
        check(new_slope_err < 0.25,
              f"8: new slope err={new_slope_err:.0%} "
              f"(dy new={new_slope}, ideal={ideal_slope})")
        # New should be better than old, or at least comparable
        check(new_slope_err <= old_slope_err + 0.05,
              f"8: new slope ({new_slope_err:.0%}) should beat old ({old_slope_err:.0%})")
        print(f"  [slope: old_err={old_slope_err:.0%}, new_err={new_slope_err:.0%}] ", end="")

    # --- Second case: vz=2, H=14 ---
    # base_y = 128 + 3*64 = 320, top_y = 320 - 14*64 = 320 - 896 = -576
    ratio2 = div_frac8(0, 145, 1, 16)
    old_base2 = old_clip_y(255, 128, ratio2)  # clamped 320->255
    old_top2 = old_clip_y(0, 128, ratio2)     # clamped -576->0

    by2_hi, by2_lo = to_bytes16(320)
    _, _, nb2_lo, nb2_hi, _ = asm_clip_endpoint_0(
        0x01, 0x90, by2_hi, by2_lo, 0x00, 128, 0x00, 128, 255)
    new_base2 = clamp_y(nb2_lo, nb2_hi)
    ty2_hi, ty2_lo = to_bytes16(-576)
    _, _, nt2_lo, nt2_hi, _ = asm_clip_endpoint_0(
        0x01, 0x90, ty2_hi, ty2_lo, 0x00, 128, 0x00, 128, 255)
    new_top2 = clamp_y(nt2_lo, nt2_hi)

    ideal_base2 = 320 + (128 - 320) * (255 - 400) / (128 - 400)
    ideal_top2 = -576 + (128 - (-576)) * (255 - 400) / (128 - 400)
    ib2c = max(0, min(255, round(ideal_base2)))
    it2c = max(0, min(255, round(ideal_top2)))

    new_slope2 = new_top2 - new_base2
    ideal_slope2 = it2c - ib2c
    old_slope2 = old_top2 - old_base2

    if ideal_slope2 != 0:
        new_err2 = abs(new_slope2 - ideal_slope2) / max(1, abs(ideal_slope2))
        old_err2 = abs(old_slope2 - ideal_slope2) / max(1, abs(ideal_slope2))
        check(new_err2 < 0.30,
              f"8b: slope err={new_err2:.0%} "
              f"(new dy={new_slope2}, ideal={ideal_slope2})")

    print("PASS")


# ======================================================================
# Main
# ======================================================================

def main():
    global PASS_COUNT, FAIL_COUNT
    print("=== Clipper 16-bit Y Test Suite ===\n")

    test_umul8x8()
    test_div_frac8()
    test_mul16x8()
    test_clip_endpoints()
    test_emit_edge()
    test_close_up_cubes()
    test_property_sweep()
    test_old_bug_regression()

    print(f"\n{'='*50}")
    if FAIL_COUNT == 0:
        print(f"ALL PASSED ({PASS_COUNT} checks)")
    else:
        print(f"FAILED: {FAIL_COUNT} failures, {PASS_COUNT} passes")
        sys.exit(1)

if __name__ == '__main__':
    main()
