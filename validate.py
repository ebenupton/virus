#!/usr/bin/env python3
"""Reference model for game.s 3D pipeline — divergence analysis + unit tests.

Compares emulator output against:
  1. Ideal (float) projection
  2. Assembly-exact simulation (integer arithmetic matching game.s)

Unit tests verify individual assembly routines:
  - umul8x8: unsigned 8×8 multiply
  - div_frac8: 16÷16 fractional division
  - clip_endpoint: Y interpolation (unsigned dy)
  - move_forward: camera direction
"""

import math
import re
import subprocess
import sys

# ── Tables (same as game.s) ──────────────────────────────────────────────

sin_table, cos_table = [], []
for i in range(256):
    a = i * 2 * math.pi / 256
    sin_table.append(max(-127, min(127, round(math.sin(a)*127))))
    cos_table.append(max(-127, min(127, round(math.cos(a)*127))))

recip_table, recip_lo_table = [], []
for i in range(256):
    z = 1.0 + i / 8.0
    val = min(127, round(128.0 / z))
    recip_table.append(val)
    err = 128.0 / z - val
    recip_lo_table.append(max(-64, min(63, round(err * 128))))

objects = [
    (128, 90, 0, 4, 8), (145, 100, 0, 3, 6), (110, 95, 1, 3, 12),
    (130, 130, 0, 5, 7), (160, 110, 1, 4, 14), (115, 80, 0, 3, 5),
]
CAMERA_Y, HORIZON_Y = 3, 128
NEAR_CLIP = 1

# ── Assembly-exact arithmetic helpers ────────────────────────────────────

def to_signed8(v):
    """Interpret byte as signed (-128..127)."""
    v &= 0xFF
    return v - 256 if v >= 128 else v

def to_unsigned8(v):
    """Wrap to unsigned byte."""
    return v & 0xFF

def umul8x8(a, b):
    """Unsigned 8×8 → 16-bit multiply matching game.s umul8x8.
    Returns (hi, lo)."""
    a, b = a & 0xFF, b & 0xFF
    result = a * b
    return (result >> 8) & 0xFF, result & 0xFF

def smul8x8(a, b):
    """Signed 8x8 multiply → 16-bit result (hi, lo)."""
    sa = to_signed8(a)
    sb = to_signed8(b)
    product = sa * sb
    # Convert to unsigned 16-bit
    if product < 0:
        product += 0x10000
    return (product >> 8) & 0xFF, product & 0xFF

def smul8x8_s7(a, b):
    """Signed 8x8 multiply → >>7 → (hi, lo) = (math_res_hi, math_res_lo)."""
    hi, lo = smul8x8(a, b)
    # ASL lo; ROL hi  (= <<1, which is the same as the original >>7)
    new_lo = (lo << 1) & 0xFF
    carry = (lo >> 7) & 1
    new_hi = ((hi << 1) | carry) & 0xFF
    return new_hi, new_lo

def apply_recip_shift(hi, lo, shift):
    """Arithmetic right-shift a 16-bit value (hi:lo) by shift bits.
    Matches apply_recip_shift in game.s (CMP #$80 / ROR / ROR)."""
    for _ in range(shift):
        sign = (hi >> 7) & 1
        lo = ((hi & 1) << 7) | (lo >> 1)
        hi = (sign << 7) | (hi >> 1)
    return hi & 0xFF, lo & 0xFF

def div_frac8(num_hi, num_lo, den_hi, den_lo):
    """16÷16 fractional division matching game.s div_frac8.
    Returns floor(numerator * 256 / denominator), clamped to 0-255."""
    num_hi, num_lo = num_hi & 0xFF, num_lo & 0xFF
    den_hi, den_lo = den_hi & 0xFF, den_lo & 0xFF
    temp3 = 0  # overflow bit
    ratio = 0

    for _ in range(8):
        # R <<= 1 (17-bit shift: temp3:num_hi:num_lo)
        num_lo = (num_lo << 1) & 0x1FF
        carry = num_lo >> 8
        num_lo &= 0xFF
        num_hi = ((num_hi << 1) | carry) & 0x1FF
        carry = num_hi >> 8
        num_hi &= 0xFF
        temp3 = ((temp3 << 1) | carry) & 0xFF

        # Compare R with D
        do_sub = False
        if temp3 > 0:
            do_sub = True
        elif num_hi > den_hi:
            do_sub = True
        elif num_hi == den_hi and num_lo >= den_lo:
            do_sub = True

        if do_sub:
            # R -= D
            borrow = 0
            result_lo = num_lo - den_lo
            if result_lo < 0:
                result_lo += 256
                borrow = 1
            num_lo = result_lo
            result_hi = num_hi - den_hi - borrow
            if result_hi < 0:
                result_hi += 256
            num_hi = result_hi
            temp3 = 0
            # quotient bit = 1
            ratio = ((ratio << 1) | 1) & 0xFF
        else:
            # quotient bit = 0
            ratio = (ratio << 1) & 0xFF

    return ratio

def clip_endpoint_y(y_from, y_to, ratio):
    """Compute interpolated Y for clip endpoint (FIXED: unsigned comparison).
    Models the corrected game.s clip_endpoint_0/1 Y interpolation.
    new_y_from = y_from + sign(y_to - y_from) * |y_to - y_from| * ratio / 256
    """
    y_from, y_to, ratio = y_from & 0xFF, y_to & 0xFF, ratio & 0xFF

    if y_to >= y_from:
        # positive delta: y_to >= y_from (unsigned)
        delta = y_to - y_from
        hi, lo = umul8x8(delta, ratio)
        result = y_from + hi
        if result > 255:
            return 255
        return result
    else:
        # negative delta: y_to < y_from (unsigned)
        delta = y_from - y_to
        hi, lo = umul8x8(delta, ratio)
        result = y_from - hi
        if result < 0:
            return 0
        return result

def clip_endpoint_y_16bit(y_from, y_from_hi, y_to, y_to_hi, ratio):
    """16-bit Y interpolation matching the new game.s clip_endpoint_0/1.
    y_from/y_to are 16-bit signed (hi:lo), ratio is 0.8 fraction.
    Returns clamped 8-bit result.
    """
    ratio = ratio & 0xFF
    # Reconstruct signed 16-bit values
    y_from_16 = (to_signed8(y_from_hi) << 8) | (y_from & 0xFF)
    y_to_16 = (to_signed8(y_to_hi) << 8) | (y_to & 0xFF)

    # 16-bit signed delta
    delta = y_to_16 - y_from_16
    neg = delta < 0
    abs_delta = abs(delta)

    # 16×8→16 multiply: |delta| * ratio >> 8
    delta_lo = abs_delta & 0xFF
    delta_hi = (abs_delta >> 8) & 0xFF
    part_a_hi, _ = umul8x8(delta_lo, ratio)  # only need hi byte
    part_b_hi, part_b_lo = umul8x8(delta_hi, ratio)
    product_lo = (part_b_lo + part_a_hi) & 0xFF
    product_hi = (part_b_hi + (1 if (part_b_lo + part_a_hi) > 0xFF else 0)) & 0xFF
    product = (product_hi << 8) | product_lo

    if neg:
        result_16 = y_from_16 - product
    else:
        result_16 = y_from_16 + product

    # Clamp to [0, 255]
    return max(0, min(255, result_16))

def clip_endpoint_y_buggy(y_from, y_to, ratio):
    """OLD BUGGY version: uses BPL (signed check) on unsigned dy.
    Fails when |dy| > 127."""
    y_from, y_to, ratio = y_from & 0xFF, y_to & 0xFF, ratio & 0xFF
    dy = (y_to - y_from) & 0xFF

    if dy < 128:  # BPL: dy appears positive
        hi, lo = umul8x8(dy, ratio)
        result = y_from + hi
        if result > 255:
            return 255
        return result
    else:  # BMI: dy appears negative, negate
        abs_dy = ((dy ^ 0xFF) + 1) & 0xFF
        hi, lo = umul8x8(abs_dy, ratio)
        result = y_from - hi
        if result < 0:
            return 0
        return result

def move_forward_fixed(px_hi, px_lo, pz_hi, pz_lo, angle):
    """Compute one step of move_forward (FIXED: subtract sin for X).
    Returns (new_px_hi, new_px_lo, new_pz_hi, new_pz_lo)."""
    sin_val = sin_table[angle]
    cos_val = cos_table[angle]

    # sin/2 via arithmetic shift right
    sin_byte = sin_val & 0xFF
    carry = 1 if sin_byte >= 0x80 else 0
    sin_half = ((sin_byte >> 1) | (carry << 7)) & 0xFF

    # X: subtract sin/2 (camera forward is -sin direction)
    new_x_lo = (px_lo - sin_half) & 0xFF
    borrow = 1 if px_lo < sin_half else 0
    new_x_hi = (px_hi - borrow) & 0xFF
    # Sign extension: if sin was negative, subtracting $FF high byte = INC
    if sin_val < 0:
        new_x_hi = (new_x_hi + 1) & 0xFF

    # cos/2 via arithmetic shift right
    cos_byte = cos_val & 0xFF
    carry = 1 if cos_byte >= 0x80 else 0
    cos_half = ((cos_byte >> 1) | (carry << 7)) & 0xFF

    # Z: add cos/2
    new_z_lo = (pz_lo + cos_half) & 0xFF
    carry_out = 1 if (pz_lo + cos_half) > 0xFF else 0
    new_z_hi = (pz_hi + carry_out) & 0xFF
    if cos_val < 0:
        new_z_hi = (new_z_hi - 1) & 0xFF

    return new_x_hi, new_x_lo, new_z_hi, new_z_lo

def move_forward_buggy(px_hi, px_lo, pz_hi, pz_lo, angle):
    """OLD BUGGY version: adds sin/2 to X instead of subtracting."""
    sin_val = sin_table[angle]
    cos_val = cos_table[angle]

    sin_byte = sin_val & 0xFF
    carry = 1 if sin_byte >= 0x80 else 0
    sin_half = ((sin_byte >> 1) | (carry << 7)) & 0xFF

    # X: add sin/2 (WRONG — should subtract)
    new_x_lo = (px_lo + sin_half) & 0xFF
    carry_out = 1 if (px_lo + sin_half) > 0xFF else 0
    new_x_hi = (px_hi + carry_out) & 0xFF
    if sin_val < 0:
        new_x_hi = (new_x_hi - 1) & 0xFF

    cos_byte = cos_val & 0xFF
    carry = 1 if cos_byte >= 0x80 else 0
    cos_half = ((cos_byte >> 1) | (carry << 7)) & 0xFF

    new_z_lo = (pz_lo + cos_half) & 0xFF
    carry_out = 1 if (pz_lo + cos_half) > 0xFF else 0
    new_z_hi = (pz_hi + carry_out) & 0xFF
    if cos_val < 0:
        new_z_hi = (new_z_hi - 1) & 0xFF

    return new_x_hi, new_x_lo, new_z_hi, new_z_lo


# ══════════════════════════════════════════════════════════════════════════
# Unit Tests
# ══════════════════════════════════════════════════════════════════════════

def test_umul8x8():
    """Test unsigned 8×8 multiply against Python reference."""
    print("  test_umul8x8 ... ", end="")
    cases = [
        (0, 0), (1, 1), (255, 255), (128, 2), (200, 200),
        (0, 255), (255, 0), (127, 127), (1, 255), (100, 100),
        (150, 170), (64, 4), (37, 211),
    ]
    for a, b in cases:
        hi, lo = umul8x8(a, b)
        result = (hi << 8) | lo
        expected = a * b
        assert result == expected, f"umul8x8({a}, {b}) = {result}, expected {expected}"
    print("PASS")

def test_div_frac8():
    """Test 16÷16 fractional division against Python reference."""
    print("  test_div_frac8 ... ", end="")
    cases = [
        # (num_hi, num_lo, den_hi, den_lo, expected_ratio)
        # 1/2 = 0.5 → 128
        (0, 1, 0, 2, 128),
        # 1/4 = 0.25 → 64
        (0, 1, 0, 4, 64),
        # 3/4 = 0.75 → 192
        (0, 3, 0, 4, 192),
        # 1/256 → 1
        (0, 1, 1, 0, 1),
        # 100/256 → floor(100*256/256) = 100
        (0, 100, 1, 0, 100),
        # 1/3 → floor(256/3) = 85
        (0, 1, 0, 3, 85),
        # 255/256 → floor(255*256/256) = 255
        (0, 255, 1, 0, 255),
        # 50/200 → floor(50*256/200) = 64
        (0, 50, 0, 200, 64),
    ]
    for num_hi, num_lo, den_hi, den_lo, expected in cases:
        result = div_frac8(num_hi, num_lo, den_hi, den_lo)
        assert result == expected, (
            f"div_frac8({num_hi}:{num_lo} / {den_hi}:{den_lo}) = {result}, "
            f"expected {expected}")
    print("PASS")

def test_clip_endpoint_y():
    """Test clipper Y interpolation — especially |dy| > 127 cases."""
    print("  test_clip_endpoint_y ... ", end="")
    failures = []

    # Cases where |dy| <= 127: both old and new should agree
    small_dy_cases = [
        (50, 100, 128),   # dy=50, ratio=0.5 → y=50+25=75
        (100, 50, 128),   # dy=-50, ratio=0.5 → y=100-25=75
        (0, 127, 255),    # dy=127, ratio≈1 → y≈127
        (200, 100, 64),   # dy=-100, ratio=0.25 → y=200-25=175
    ]
    for y_from, y_to, ratio in small_dy_cases:
        fixed = clip_endpoint_y(y_from, y_to, ratio)
        buggy = clip_endpoint_y_buggy(y_from, y_to, ratio)
        assert fixed == buggy, (
            f"Small dy: y_from={y_from}, y_to={y_to}, ratio={ratio}: "
            f"fixed={fixed}, buggy={buggy} — should agree!")

    # Cases where |dy| > 127: old code gets it WRONG
    # y_from=50, y_to=200 → dy=150 (unsigned positive)
    # Old code: 150 as byte → $96 → N=1 → treated as negative → negate → 106
    #   → y = 50 - 106*ratio/256 (WRONG: should ADD)
    # New code: CMP → 200 >= 50 → positive → y = 50 + 150*ratio/256
    big_dy_cases = [
        # (y_from, y_to, ratio, expected_fixed, expected_buggy_wrong)
        # 50→200: dy=150=$96, buggy negates to 106, 50-106*128/256=50-53=-3→clamp 0
        (50, 200, 128, 50 + (150 * 128 >> 8), 0),    # fixed=125, buggy=0(clamped)
        # 10→250: dy=240=$F0, buggy negates to 16, 10-16*64/256=10-4=6
        (10, 250, 64,  10 + (240 * 64 >> 8),  6),     # fixed=70, buggy=6
        # 200→50: dy=206=$CE, buggy sees as positive 206(wait, dy=50-200=106=$6A<128→positive!)
        # Actually: dy = (50-200)&0xFF = 56? No: 50-200 = -150 → &0xFF = 106 = $6A
        # $6A < $80 → BPL taken → treated as positive → 200 + 106*128/256 = 200+53 = 253
        (200, 50, 128, 200 - (150 * 128 >> 8), 253),  # fixed=125, buggy=253
    ]
    for y_from, y_to, ratio, exp_fixed, exp_buggy in big_dy_cases:
        fixed = clip_endpoint_y(y_from, y_to, ratio)
        buggy = clip_endpoint_y_buggy(y_from, y_to, ratio)

        # Verify fixed matches expected
        assert fixed == exp_fixed, (
            f"FIXED wrong: y_from={y_from}, y_to={y_to}, ratio={ratio}: "
            f"got {fixed}, expected {exp_fixed}")

        # Verify buggy is DIFFERENT (confirms the bug exists)
        assert buggy == exp_buggy, (
            f"BUGGY unexpected: y_from={y_from}, y_to={y_to}, ratio={ratio}: "
            f"got {buggy}, expected {exp_buggy}")

        # Verify fixed ≠ buggy for large dy (the bug)
        assert fixed != buggy, (
            f"Expected mismatch for |dy|>127: y_from={y_from}, y_to={y_to}")

    # Verify interpolation makes geometric sense (new_y between y_from and y_to)
    for y_from in range(0, 256, 17):
        for y_to in range(0, 256, 19):
            for ratio in [0, 64, 128, 192, 255]:
                result = clip_endpoint_y(y_from, y_to, ratio)
                lo = min(y_from, y_to)
                hi = max(y_from, y_to)
                assert lo <= result <= hi or result == 0 or result == 255, (
                    f"Out of range: y_from={y_from}, y_to={y_to}, ratio={ratio}, "
                    f"result={result}, expected in [{lo},{hi}]")

    print("PASS")

def test_clip_endpoint_y_16bit():
    """Test 16-bit Y interpolation — large Y deltas from close-up vertices."""
    print("  test_clip_endpoint_y_16bit ... ", end="")

    # Case 1: base_y = 509 ($01FD), top_y = -1269, ratio=128 (50%)
    # Simulates a cube directly in front at vz=1
    # Endpoint 0 at y=509: new_y = 509 + (-1269 - 509)*128/256 = 509 - 889 = -380 → clamp 0
    r = clip_endpoint_y_16bit(0xFD, 0x01, 0x00, 0x00, 128)
    # With y_to=0 (on-screen), ratio=128: new_y = 509 + (0-509)*128/256 ≈ 509-254 = 255
    assert 200 <= r <= 255, f"Case 1: got {r}, expected ~255"

    # Case 2: base_y = 300 ($012C), y_to = 50, ratio = 128
    # new_y = 300 + (50-300)*128/256 = 300 - 125 = 175
    r = clip_endpoint_y_16bit(0x2C, 0x01, 50, 0x00, 128)
    assert 170 <= r <= 180, f"Case 2: got {r}, expected ~175"

    # Case 3: top_y = -200 (= $FF38), y_to = 100, ratio = 64
    # new_y = -200 + (100-(-200))*64/256 = -200 + 75 = -125 → clamp 0
    r = clip_endpoint_y_16bit(0x38, 0xFF, 100, 0x00, 64)
    assert r == 0, f"Case 3: got {r}, expected 0"

    # Case 4: Both on-screen (should match 8-bit version)
    r16 = clip_endpoint_y_16bit(50, 0x00, 200, 0x00, 128)
    r8 = clip_endpoint_y(50, 200, 128)
    assert r16 == r8, f"Case 4: 16-bit={r16}, 8-bit={r8}, should match"

    # Case 5: y_from = 400 ($0190), y_to = 100, ratio = 192
    # new_y = 400 + (100-400)*192/256 = 400 - 225 = 175
    r = clip_endpoint_y_16bit(0x90, 0x01, 100, 0x00, 192)
    assert 170 <= r <= 180, f"Case 5: got {r}, expected ~175"

    print("PASS")

def test_movement():
    """Test forward movement direction at key angles."""
    print("  test_movement ... ", end="")

    # Start at (128, 128), move forward at various angles
    # Camera forward in world space should be (-sin(θ), cos(θ))
    test_angles = [
        # angle, expected_dx_sign, expected_dz_sign
        (0,    0,  1),    # angle=0: sin=0, cos=127 → forward is (0, +Z)
        (64,  -1,  0),    # angle=64: sin=127, cos=0 → forward is (-X, 0)
        (128,  0, -1),    # angle=128: sin=0, cos=-127 → forward is (0, -Z)
        (192,  1,  0),    # angle=192: sin=-127, cos=0 → forward is (+X, 0)
    ]

    for angle, exp_dx_sign, exp_dz_sign in test_angles:
        fx_hi, fx_lo, fz_hi, fz_lo = move_forward_fixed(128, 0, 128, 0, angle)
        bx_hi, bx_lo, bz_hi, bz_lo = move_forward_buggy(128, 0, 128, 0, angle)

        # Convert to signed displacement
        f_dx = to_signed8(fx_hi - 128) * 256 + fx_lo
        f_dz = to_signed8(fz_hi - 128) * 256 + fz_lo
        b_dx = to_signed8(bx_hi - 128) * 256 + bx_lo
        b_dz = to_signed8(bz_hi - 128) * 256 + bz_lo

        # Check fixed version has correct direction
        if exp_dx_sign != 0:
            actual_sign = 1 if f_dx > 0 else (-1 if f_dx < 0 else 0)
            assert actual_sign == exp_dx_sign, (
                f"FIXED angle={angle}: X displacement {f_dx}, "
                f"expected sign {exp_dx_sign}")
        if exp_dz_sign != 0:
            actual_sign = 1 if f_dz > 0 else (-1 if f_dz < 0 else 0)
            assert actual_sign == exp_dz_sign, (
                f"FIXED angle={angle}: Z displacement {f_dz}, "
                f"expected sign {exp_dz_sign}")

        # At angle=64 and 192 where the bug is visible,
        # verify buggy version has WRONG X sign
        if angle == 64:
            assert b_dx > 0, (
                f"BUGGY angle=64: X displacement {b_dx} should be positive (wrong)")
            assert f_dx < 0, (
                f"FIXED angle=64: X displacement {f_dx} should be negative (correct)")
        elif angle == 192:
            assert b_dx < 0, (
                f"BUGGY angle=192: X displacement {b_dx} should be negative (wrong)")
            assert f_dx > 0, (
                f"FIXED angle=192: X displacement {f_dx} should be positive (correct)")

    # Verify movement vector points same way as camera for many angles
    for angle in range(256):
        sin_val = sin_table[angle]
        cos_val = cos_table[angle]
        if sin_val == 0 and cos_val == 0:
            continue

        fx_hi, fx_lo, fz_hi, fz_lo = move_forward_fixed(128, 0, 128, 0, angle)
        dx = to_signed8(fx_hi - 128) * 256 + fx_lo
        dz = to_signed8(fz_hi - 128) * 256 + fz_lo

        # Camera forward direction is (-sin, +cos)
        # Dot product of movement with camera forward should be positive
        dot = dx * (-sin_val) + dz * cos_val
        assert dot >= 0, (
            f"angle={angle}: movement ({dx},{dz}) not aligned with "
            f"camera forward ({-sin_val},{cos_val}), dot={dot}")

    print("PASS")


# ══════════════════════════════════════════════════════════════════════════
# Assembly-exact simulation of one corner
# ══════════════════════════════════════════════════════════════════════════

def asm_simulate_corner(pxhi, pxlo, pzhi, pzlo, angle, obj_idx, corner_idx):
    """Simulate game.s projection for one corner of one object.

    Returns dict with intermediate values and final screen coords,
    or None if vertex is behind camera / off-screen.
    """
    obj = objects[obj_idx]
    wx, wz, otype, h, H = obj

    # --- process_object: translate ---
    rel_x = to_signed8((wx - pxhi) & 0xFF)
    rel_z = to_signed8((wz - pzhi) & 0xFF)

    cos_val = cos_table[angle]
    sin_val = sin_table[angle]

    # --- view_x = (rel_x*cos + rel_z*sin) >> 7 (16-bit) ---
    hi1, lo1 = smul8x8(rel_x, cos_val)
    hi2, lo2 = smul8x8(rel_z, sin_val)

    # 16-bit add
    sum_lo = (lo1 + lo2) & 0xFF
    carry = 1 if (lo1 + lo2) > 0xFF else 0
    sum_hi = (hi1 + hi2 + carry) & 0xFF

    # >>7: ASL lo, ROL hi
    new_lo = (sum_lo << 1) & 0xFF
    c = (sum_lo >> 7) & 1
    temp0 = ((sum_hi << 1) | c) & 0xFF  # center_vx integer
    center_vx_frac = new_lo

    # --- view_z = (rel_z*cos - rel_x*sin) >> 7 (16-bit) ---
    hi1, lo1 = smul8x8(rel_z, cos_val)
    hi2, lo2 = smul8x8(rel_x, sin_val)

    # 16-bit subtract
    diff = ((hi1 << 8) | lo1) - ((hi2 << 8) | lo2)
    if diff < 0: diff += 0x10000
    diff_hi = (diff >> 8) & 0xFF
    diff_lo = diff & 0xFF

    # >>7
    new_lo = (diff_lo << 1) & 0xFF
    c = (diff_lo >> 7) & 1
    temp1 = ((diff_hi << 1) | c) & 0xFF  # center_vz integer
    center_vz_frac = new_lo

    # --- Sub-pixel position correction ---
    def unsigned_fixup_mul(player_lo, trig_val):
        """smul8x8 with unsigned fixup if player_lo >= 128, then >>7."""
        hi, lo = smul8x8(player_lo, trig_val)
        if player_lo >= 128:
            hi = (hi + trig_val) & 0xFF
        # >>7: ASL lo, ROL hi
        new_lo = (lo << 1) & 0xFF
        c = (lo >> 7) & 1
        new_hi = ((hi << 1) | c) & 0xFF
        carry_out = (hi >> 7) & 1  # sign from ROL
        return new_hi, carry_out  # frac_part, sign (0=pos, 1=neg)

    # Term 1: subtract (pxlo * cos) >> 7 from view_x
    frac, sign = unsigned_fixup_mul(pxlo, cos_val)
    int_part = 0xFF if sign else 0
    borrow_check = center_vx_frac - frac
    center_vx_frac = borrow_check & 0xFF
    borrow = 1 if borrow_check < 0 else 0
    temp0 = (temp0 - int_part - borrow) & 0xFF

    # Term 2: subtract (pzlo * sin) >> 7 from view_x
    frac, sign = unsigned_fixup_mul(pzlo, sin_val)
    int_part = 0xFF if sign else 0
    borrow_check = center_vx_frac - frac
    center_vx_frac = borrow_check & 0xFF
    borrow = 1 if borrow_check < 0 else 0
    temp0 = (temp0 - int_part - borrow) & 0xFF

    # Term 3: subtract (pzlo * cos) >> 7 from view_z
    frac, sign = unsigned_fixup_mul(pzlo, cos_val)
    int_part = 0xFF if sign else 0
    borrow_check = center_vz_frac - frac
    center_vz_frac = borrow_check & 0xFF
    borrow = 1 if borrow_check < 0 else 0
    temp1 = (temp1 - int_part - borrow) & 0xFF

    # Term 4: add (pxlo * sin) >> 7 to view_z
    frac, sign = unsigned_fixup_mul(pxlo, sin_val)
    int_part = 0xFF if sign else 0
    add_check = center_vz_frac + frac
    center_vz_frac = add_check & 0xFF
    carry = 1 if add_check > 0xFF else 0
    temp1 = (temp1 + int_part + carry) & 0xFF

    center_vx = to_signed8(temp0)
    center_vz = to_signed8(temp1)

    if center_vz < 3:
        return None

    # --- Corner offsets ---
    # rot_hx = (h * cos) >> 7
    rot_hx_hi, rot_hx_lo = smul8x8_s7(h, cos_val)
    rot_hx = to_signed8(rot_hx_hi)
    rot_hx_frac = rot_hx_lo

    # rot_kx = (h * sin) >> 7
    rot_kx_hi, rot_kx_lo = smul8x8_s7(h, sin_val)
    rot_kx = to_signed8(rot_kx_hi)
    rot_kx_frac = rot_kx_lo

    # 8.8 negation: rot_hz:rot_hz_frac = -rot_kx:rot_kx_frac
    bc = 0 - rot_kx_frac
    rot_hz_frac = bc & 0xFF
    borrow = 1 if bc < 0 else 0
    rot_hz = (0 - (rot_kx_hi & 0xFF) - borrow) & 0xFF

    # Corner signs: [(-,-), (+,-), (+,+), (-,+)]
    corner_signs = [(-1,-1), (1,-1), (1,1), (-1,1)]
    sx, sz = corner_signs[corner_idx]

    # vx_temp with fractional arithmetic
    if sx < 0:
        borrow_check = center_vx_frac - rot_hx_frac
        vx_frac = borrow_check & 0xFF
        borrow = 1 if borrow_check < 0 else 0
        vx_int = (temp0 - (rot_hx_hi & 0xFF) - borrow) & 0xFF
    else:
        add_check = center_vx_frac + rot_hx_frac
        vx_frac = add_check & 0xFF
        carry = 1 if add_check > 0xFF else 0
        vx_int = (temp0 + (rot_hx_hi & 0xFF) + carry) & 0xFF

    if sz < 0:
        borrow_check = vx_frac - rot_kx_frac
        vx_frac = borrow_check & 0xFF
        borrow = 1 if borrow_check < 0 else 0
        vx_int = (vx_int - (rot_kx_hi & 0xFF) - borrow) & 0xFF
    else:
        add_check = vx_frac + rot_kx_frac
        vx_frac = add_check & 0xFF
        carry = 1 if add_check > 0xFF else 0
        vx_int = (vx_int + (rot_kx_hi & 0xFF) + carry) & 0xFF

    vx_temp = to_signed8(vx_int)

    # vz_temp with fractional arithmetic (8.8, matching game.s)
    # Step 1: apply rot_hz (sx sign)
    if sx < 0:
        bc_val = center_vz_frac - rot_hz_frac
        temp2_val = bc_val & 0xFF
        borrow = 1 if bc_val < 0 else 0
        vz_int_y = (temp1 - (rot_hz & 0xFF) - borrow) & 0xFF
    else:
        ac_val = center_vz_frac + rot_hz_frac
        temp2_val = ac_val & 0xFF
        carry = 1 if ac_val > 0xFF else 0
        vz_int_y = (temp1 + (rot_hz & 0xFF) + carry) & 0xFF

    # Step 2: apply rot_hx (rot_kz = rot_hx, sz sign)
    if sz < 0:
        bc_val = temp2_val - rot_hx_frac
        vz_frac_val = bc_val & 0xFF
        borrow = 1 if bc_val < 0 else 0
        vz_int = (vz_int_y - (rot_hx_hi & 0xFF) - borrow) & 0xFF
    else:
        ac_val = temp2_val + rot_hx_frac
        vz_frac_val = ac_val & 0xFF
        carry = 1 if ac_val > 0xFF else 0
        vz_int = (vz_int_y + (rot_hx_hi & 0xFF) + carry) & 0xFF

    vz_temp = to_signed8(vz_int)

    if vz_temp < NEAR_CLIP or vz_temp >= 128:
        return None

    # --- Extended-range recip lookup (matches recip_lookup in game.s) ---
    if vz_temp >= 66:
        # Range 2: z in [66, 128), quarter z with full K=8 fractional precision, shift=2
        recip_shift = 2
        quarter_int = vz_temp >> 2
        sub_idx = ((vz_temp & 3) << 1) | (vz_frac_val >> 7)
        idx = ((quarter_int - 1) << 3) | sub_idx
        recip_lo_val = recip_lo_table[idx]
    elif vz_temp >= 33:
        # Range 1: z in [33, 66), halve z with full K=8 fractional precision, shift=1
        recip_shift = 1
        carry = vz_temp & 1
        half_int = vz_temp >> 1
        sub_idx = (carry << 2) | (vz_frac_val >> 6)
        idx = ((half_int - 1) << 3) | sub_idx
        recip_lo_val = recip_lo_table[idx]
    else:
        # Range 0: z in [1, 33), direct lookup
        recip_shift = 0
        idx = ((vz_temp - 1) << 3) | (vz_frac_val >> 5)
        recip_lo_val = recip_lo_table[idx]
    if idx > 255:
        return None
    recip_val = recip_table[idx]

    # --- Project X ---
    main_hi, main_lo = smul8x8(vx_temp, recip_val)
    main_hi, main_lo = apply_recip_shift(main_hi, main_lo, recip_shift)

    corr_hi, corr_lo = smul8x8_s7(vx_temp, recip_lo_val)
    corr_hi, corr_lo = apply_recip_shift(corr_hi, corr_lo, recip_shift)
    corr_signed = to_signed8(corr_hi)
    sign_ext = 0xFF if corr_signed < 0 else 0

    disp_lo = (main_lo + corr_hi) & 0xFF
    carry = 1 if (main_lo + corr_hi) > 0xFF else 0
    disp_hi = (main_hi + sign_ext + carry) & 0xFF

    vxf_half = vx_frac >> 1
    vxf_hi, vxf_lo = smul8x8_s7(vxf_half, recip_val)
    vxf_hi, vxf_lo = apply_recip_shift(vxf_hi, vxf_lo, recip_shift)

    disp_lo_2 = (disp_lo + vxf_hi) & 0xFF
    carry = 1 if (disp_lo + vxf_hi) > 0xFF else 0
    disp_hi_2 = (disp_hi + carry) & 0xFF

    sx_lo = (128 + disp_lo_2) & 0xFF
    sx_carry = 1 if (128 + disp_lo_2) > 0xFF else 0
    sx_hi = (disp_hi_2 + sx_carry) & 0xFF

    if sx_hi != 0:
        return None
    screen_x = sx_lo

    # --- Project base Y (16-bit unclamped) ---
    three_recip = recip_val * 3  # 9-bit value
    # Apply recip_shift (16-bit)
    for _ in range(recip_shift):
        three_recip >>= 1
    # Add HORIZON_Y
    base_y_16 = three_recip + HORIZON_Y
    # recip_lo correction (signed)
    by_corr_hi, by_corr_lo = smul8x8_s7(CAMERA_Y, recip_lo_val)
    by_corr_hi, by_corr_lo = apply_recip_shift(by_corr_hi, by_corr_lo, recip_shift)
    base_y_16 += to_signed8(by_corr_hi)

    # --- Project top Y (16-bit unclamped) ---
    th, tl = smul8x8(H, recip_val)
    th, tl = apply_recip_shift(th, tl, recip_shift)
    main_height_16 = (th << 8) | tl
    # Fractional correction
    hc_hi, hc_lo = smul8x8_s7(H, recip_lo_val)
    hc_hi, hc_lo = apply_recip_shift(hc_hi, hc_lo, recip_shift)
    total_height_16 = main_height_16 + to_signed8(hc_hi)
    top_y_16 = base_y_16 - total_height_16

    # Clamp to 8-bit for final screen coordinates
    base_y = max(0, min(255, base_y_16))
    top_y = max(0, min(255, top_y_16))

    return dict(
        center_vx=center_vx, center_vz=center_vz,
        center_vx_frac=center_vx_frac, center_vz_frac=center_vz_frac,
        vx_temp=vx_temp, vz_temp=vz_temp, vx_frac=vx_frac,
        vz_frac=vz_frac_val,
        recip_val=recip_val, recip_lo_val=recip_lo_val,
        recip_idx=idx, recip_shift=recip_shift,
        screen_x=screen_x, base_y=base_y, top_y=top_y,
        base_y_16=base_y_16, top_y_16=top_y_16,
        disp_main=(to_signed8(main_hi) * 256 + main_lo) if main_hi < 128 else (main_hi - 256) * 256 + main_lo,
    )

# ── Ideal float projection ──────────────────────────────────────────────

def ideal_corner(px, pz, angle, obj_idx, corner_idx):
    """Compute ideal (float) projected coordinates for one corner."""
    obj = objects[obj_idx]
    wx, wz, otype, h, H = obj
    ca, sa = cos_table[angle]/127, sin_table[angle]/127
    rx, rz = wx - px, wz - pz
    vx = rx*ca + rz*sa
    vz = rz*ca - rx*sa

    corner_signs = [(-1,-1), (1,-1), (1,1), (-1,1)]
    csx, csz = corner_signs[corner_idx]
    lx, lz = csx*h, csz*h
    cvx = vx + lx*ca + lz*sa
    cvz = vz + lz*ca - lx*sa

    if cvz < NEAR_CLIP or cvz >= 128:
        return None
    r = 128.0/cvz
    screen_x = 128 + cvx * r
    base_y = HORIZON_Y + CAMERA_Y * r
    top_y = base_y - H * r
    return dict(screen_x=screen_x, base_y=base_y, top_y=top_y, cvx=cvx, cvz=cvz, recip=r)

# ── Main ─────────────────────────────────────────────────────────────────

def run_tests():
    """Run all unit tests."""
    print("=== Unit Tests ===")
    test_umul8x8()
    test_div_frac8()
    test_clip_endpoint_y()
    test_clip_endpoint_y_16bit()
    test_movement()
    print("All unit tests PASSED\n")

def run_e2e():
    """Run end-to-end emulator comparison (requires built game.bin)."""
    print("=== End-to-End Comparison ===")
    print("Running emulator...")
    with open('/dev/null','w') as dn:
        r = subprocess.run(['./emu','game.bin','--headless','80','--keys','4','--log'],
                          stdout=dn, stderr=subprocess.PIPE, text=True)
    lines = r.stderr.strip().split('\n')

    # Parse frames
    frames = []
    seen = set()
    for line in lines:
        m = re.match(r'F (\d+) angle=(\d+) px=(\d+)\.(\d+) pz=(\d+)\.(\d+) nlines=(\d+)', line)
        if not m: continue
        f = int(m.group(1)); nlines = int(m.group(7))
        if nlines < 7: continue
        pxhi,pxlo,pzhi,pzlo = int(m.group(3)),int(m.group(4)),int(m.group(5)),int(m.group(6))
        angle = int(m.group(2))
        key = (pxhi,pxlo,pzhi,pzlo,angle)
        if key in seen: continue
        seen.add(key)
        lms = re.findall(r'L(\d+)\((\d+),(\d+),(\d+),(\d+)\)', line)
        obj0 = [(int(x[1]),int(x[2]),int(x[3]),int(x[4])) for x in lms if 3<=int(x[0])<=6]
        frames.append(dict(f=f, pxhi=pxhi, pxlo=pxlo, pzhi=pzhi, pzlo=pzlo,
                          angle=angle, obj0=obj0, line=line))

    # Header
    print(f"\n{'F':>3} {'pz':>8} | {'emu_x':>5} {'sim_x':>5} {'idl_x':>6} {'e-s':>4} {'e-i':>5} |"
          f" {'emu_by':>6} {'sim_by':>6} {'idl_by':>7} {'e-s':>4} {'e-i':>5} |"
          f" {'emu_ty':>6} {'sim_ty':>6} {'idl_ty':>7} {'e-s':>4} {'e-i':>5} |"
          f" {'recip':>5} {'vz':>3} {'vzf':>3} {'idx':>3}")
    print("-"*140)

    for fi in frames:
        px = fi['pxhi'] + fi['pxlo']/256
        pz = fi['pzhi'] + fi['pzlo']/256

        ic = ideal_corner(px, pz, fi['angle'], 0, 0)
        if not ic: continue

        sim = asm_simulate_corner(fi['pxhi'], fi['pxlo'], fi['pzhi'], fi['pzlo'],
                                   fi['angle'], 0, 0)
        if not sim: continue

        if len(fi['obj0']) < 4: continue
        emu_x = fi['obj0'][0][0]
        emu_by = fi['obj0'][0][1]
        emu_ty = fi['obj0'][1][1]

        ex_s = emu_x - sim['screen_x']
        ex_i = emu_x - ic['screen_x']
        eby_s = emu_by - sim['base_y']
        eby_i = emu_by - ic['base_y']
        ety_s = emu_ty - sim['top_y']
        ety_i = emu_ty - ic['top_y']

        print(f"F{fi['f']:2d} {fi['pzhi']:3d}.{fi['pzlo']:<3d} |"
              f" {emu_x:5d} {sim['screen_x']:5d} {ic['screen_x']:6.1f} {ex_s:+4d} {ex_i:+5.1f} |"
              f" {emu_by:6d} {sim['base_y']:6d} {ic['base_y']:7.1f} {eby_s:+4d} {eby_i:+5.1f} |"
              f" {emu_ty:6d} {sim['top_y']:6d} {ic['top_y']:7.1f} {ety_s:+4d} {ety_i:+5.1f} |"
              f" r={sim['recip_val']:3d} z={sim['vz_temp']:2d} vf={sim['vz_frac']:3d}"
              f" i={sim['recip_idx']:3d}")

def main():
    run_tests()
    if '--e2e' in sys.argv:
        run_e2e()

if __name__ == '__main__':
    main()
