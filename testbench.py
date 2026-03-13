#!/usr/bin/env python3
"""Comprehensive testbench for game.s coordinate transform pipeline.

Compares the fixed-point (assembly-exact) coordinate transforms against
an ideal floating-point reference, sweeping across all relevant parameters
to characterise maximum deviation from ideality.

Pipeline under test:
  1. Integer subtraction: rel = obj - player_hi
  2. Rotation: view = rotate(rel, angle) via smul8x8 >> 7
  3. Sub-pixel correction: adjust for player_lo fractional position
  4. Corner offset: view ± rotated half-size
  5. Projection: screen_x = 128 + view_x * 128 / view_z
"""

import math
import sys
from collections import defaultdict

# ── Trig tables (matching game.s exactly) ────────────────────────────────

sin_table, cos_table = [], []
for i in range(256):
    a = i * 2 * math.pi / 256
    sin_table.append(max(-127, min(127, round(math.sin(a) * 127))))
    cos_table.append(max(-127, min(127, round(math.cos(a) * 127))))

recip_table = []
for i in range(256):
    z = 2.0 + i / 8.0
    recip_table.append(min(127, round(128.0 / z)))

# ── Fixed-point helpers (matching game.s exactly) ────────────────────────

def to_signed8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v

def smul8x8(a, b):
    """Signed 8×8 → 16-bit (hi, lo). Matches game.s smul8x8."""
    sa, sb = to_signed8(a), to_signed8(b)
    p = sa * sb
    if p < 0:
        p += 0x10000
    return (p >> 8) & 0xFF, p & 0xFF

def smul8x8_s7(a, b):
    """Signed 8×8 → >>7 → (hi, lo). Matches game.s smul8x8 + ASL/ROL."""
    hi, lo = smul8x8(a, b)
    new_lo = (lo << 1) & 0xFF
    carry = (lo >> 7) & 1
    new_hi = ((hi << 1) | carry) & 0xFF
    return new_hi, new_lo


# ══════════════════════════════════════════════════════════════════════════
# Stage 1: Center coordinate transform (rotation + sub-pixel correction)
# ══════════════════════════════════════════════════════════════════════════

def asm_center_transform(obj_x, obj_z, px_hi, px_lo, pz_hi, pz_lo, angle):
    """Fixed-point center coordinate transform matching game.s exactly.

    Returns (center_vx, center_vz, center_vx_frac, center_vz_frac)
    where center_vx/vz are signed 8-bit integers and _frac are 0.8 fractions.
    Returns None if object is behind camera (vz < 3).
    """
    cos_val = cos_table[angle]
    sin_val = sin_table[angle]

    # Integer subtraction (line 569-577)
    rel_x = (obj_x - px_hi) & 0xFF  # unsigned byte
    rel_z = (obj_z - pz_hi) & 0xFF

    # --- view_x = (rel_x * cos + rel_z * sin) >> 7 ---
    hi1, lo1 = smul8x8(rel_x, cos_val)
    hi2, lo2 = smul8x8(rel_z, sin_val)
    sum_lo = (lo1 + lo2) & 0xFF
    carry = 1 if (lo1 + lo2) > 0xFF else 0
    sum_hi = (hi1 + hi2 + carry) & 0xFF
    # >>7 via ASL lo, ROL hi
    vx_frac = (sum_lo << 1) & 0xFF
    c = (sum_lo >> 7) & 1
    temp0 = ((sum_hi << 1) | c) & 0xFF

    # --- view_z = (rel_z * cos - rel_x * sin) >> 7 ---
    hi1, lo1 = smul8x8(rel_z, cos_val)
    hi2, lo2 = smul8x8(rel_x, sin_val)
    diff = ((hi1 << 8) | lo1) - ((hi2 << 8) | lo2)
    if diff < 0:
        diff += 0x10000
    diff_hi = (diff >> 8) & 0xFF
    diff_lo = diff & 0xFF
    vz_frac = (diff_lo << 1) & 0xFF
    c = (diff_lo >> 7) & 1
    temp1 = ((diff_hi << 1) | c) & 0xFF

    # --- Sub-pixel correction ---
    def unsigned_fixup_mul(player_lo, trig_val):
        hi, lo = smul8x8(player_lo, trig_val)
        if player_lo >= 128:
            hi = (hi + trig_val) & 0xFF
        new_lo = (lo << 1) & 0xFF
        c = (lo >> 7) & 1
        new_hi = ((hi << 1) | c) & 0xFF
        carry_out = (hi >> 7) & 1
        return new_hi, carry_out

    # Term 1: subtract (px_lo * cos) >> 7 from view_x
    frac, sign = unsigned_fixup_mul(px_lo, cos_val)
    int_part = 0xFF if sign else 0
    bc = vx_frac - frac
    vx_frac = bc & 0xFF
    borrow = 1 if bc < 0 else 0
    temp0 = (temp0 - int_part - borrow) & 0xFF

    # Term 2: subtract (pz_lo * sin) >> 7 from view_x
    frac, sign = unsigned_fixup_mul(pz_lo, sin_val)
    int_part = 0xFF if sign else 0
    bc = vx_frac - frac
    vx_frac = bc & 0xFF
    borrow = 1 if bc < 0 else 0
    temp0 = (temp0 - int_part - borrow) & 0xFF

    # Term 3: subtract (pz_lo * cos) >> 7 from view_z
    frac, sign = unsigned_fixup_mul(pz_lo, cos_val)
    int_part = 0xFF if sign else 0
    bc = vz_frac - frac
    vz_frac = bc & 0xFF
    borrow = 1 if bc < 0 else 0
    temp1 = (temp1 - int_part - borrow) & 0xFF

    # Term 4: add (px_lo * sin) >> 7 to view_z
    frac, sign = unsigned_fixup_mul(px_lo, sin_val)
    int_part = 0xFF if sign else 0
    ac = vz_frac + frac
    vz_frac = ac & 0xFF
    carry = 1 if ac > 0xFF else 0
    temp1 = (temp1 + int_part + carry) & 0xFF

    return (to_signed8(temp0), to_signed8(temp1), vx_frac, vz_frac)


def ideal_center_transform(obj_x, obj_z, px_hi, px_lo, pz_hi, pz_lo, angle):
    """Ideal floating-point center coordinate transform.

    Returns (view_x, view_z) as floats.
    """
    px = px_hi + px_lo / 256.0
    pz = pz_hi + pz_lo / 256.0
    theta = angle * 2 * math.pi / 256.0
    cos_a = math.cos(theta)
    sin_a = math.sin(theta)

    rel_x = obj_x - px
    rel_z = obj_z - pz

    view_x = rel_x * cos_a + rel_z * sin_a
    view_z = rel_z * cos_a - rel_x * sin_a

    return (view_x, view_z)


# ══════════════════════════════════════════════════════════════════════════
# Stage 2: Corner offset
# ══════════════════════════════════════════════════════════════════════════

def asm_corner_offset(temp0, temp1, vx_frac, vz_frac, h, angle, corner_idx):
    """Apply corner offset in fixed-point. Returns (vx_temp, vz_temp, vx_frac_out, vz_frac_out).

    Corner signs: 0=(-,-), 1=(+,-), 2=(+,+), 3=(-,+)
    """
    cos_val = cos_table[angle]
    sin_val = sin_table[angle]

    rot_hx_hi, rot_hx_lo = smul8x8_s7(h, cos_val)
    rot_kx_hi, rot_kx_lo = smul8x8_s7(h, sin_val)
    # 8.8 negation: rot_hz:rot_hz_frac = -rot_kx:rot_kx_frac
    bc = 0 - rot_kx_lo
    rot_hz_frac = bc & 0xFF
    borrow = 1 if bc < 0 else 0
    rot_hz = (0 - (rot_kx_hi & 0xFF) - borrow) & 0xFF

    corner_signs = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    sx, sz = corner_signs[corner_idx]

    # vx with fractional
    if sx < 0:
        bc = vx_frac - rot_hx_lo
        vx_f = bc & 0xFF
        borrow = 1 if bc < 0 else 0
        vx_int = (temp0 - (rot_hx_hi & 0xFF) - borrow) & 0xFF
    else:
        ac = vx_frac + rot_hx_lo
        vx_f = ac & 0xFF
        carry = 1 if ac > 0xFF else 0
        vx_int = (temp0 + (rot_hx_hi & 0xFF) + carry) & 0xFF

    if sz < 0:
        bc = vx_f - rot_kx_lo
        vx_f = bc & 0xFF
        borrow = 1 if bc < 0 else 0
        vx_int = (vx_int - (rot_kx_hi & 0xFF) - borrow) & 0xFF
    else:
        ac = vx_f + rot_kx_lo
        vx_f = ac & 0xFF
        carry = 1 if ac > 0xFF else 0
        vx_int = (vx_int + (rot_kx_hi & 0xFF) + carry) & 0xFF

    # vz with fractional (8.8 arithmetic, matching game.s)
    # Step 1: apply rot_hz (sx sign)
    if sx < 0:
        bc = vz_frac - rot_hz_frac
        temp2 = bc & 0xFF
        borrow = 1 if bc < 0 else 0
        vz_int_y = ((temp1 & 0xFF) - (rot_hz & 0xFF) - borrow) & 0xFF
    else:
        ac = vz_frac + rot_hz_frac
        temp2 = ac & 0xFF
        carry = 1 if ac > 0xFF else 0
        vz_int_y = ((temp1 & 0xFF) + (rot_hz & 0xFF) + carry) & 0xFF

    # Step 2: apply rot_hx (rot_kz = rot_hx, sz sign)
    if sz < 0:
        bc = temp2 - rot_hx_lo
        vz_f = bc & 0xFF
        borrow = 1 if bc < 0 else 0
        vz_int = (vz_int_y - (rot_hx_hi & 0xFF) - borrow) & 0xFF
    else:
        ac = temp2 + rot_hx_lo
        vz_f = ac & 0xFF
        carry = 1 if ac > 0xFF else 0
        vz_int = (vz_int_y + (rot_hx_hi & 0xFF) + carry) & 0xFF

    return (to_signed8(vx_int), to_signed8(vz_int), vx_f, vz_f)


def ideal_corner_offset(view_x, view_z, h, angle, corner_idx):
    """Ideal floating-point corner offset."""
    theta = angle * 2 * math.pi / 256.0
    cos_a = math.cos(theta)
    sin_a = math.sin(theta)

    corner_signs = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    sx, sz = corner_signs[corner_idx]

    # Local offset (lx, lz) rotated into view space
    lx, lz = sx * h, sz * h
    dvx = lx * cos_a + lz * sin_a
    dvz = lz * cos_a - lx * sin_a

    return (view_x + dvx, view_z + dvz)


# ══════════════════════════════════════════════════════════════════════════
# Stage 3: Projection
# ══════════════════════════════════════════════════════════════════════════

def asm_project_x(vx_temp, vz_temp, vx_frac, vz_frac_val):
    """Fixed-point X projection matching game.s (K=8 recip). Returns screen_x or None."""
    if vz_temp < 2 or vz_temp >= 34:
        return None

    # K=8 index: (vz-2)*8 + (vz_frac>>5)
    idx = ((vz_temp - 2) << 3) | (vz_frac_val >> 5)
    if idx > 255:
        return None
    recip_val = recip_table[idx]

    # Main: vx_temp * recip_val (signed × unsigned)
    main_hi, main_lo = smul8x8(vx_temp, recip_val)

    # displacement = main_hi:main_lo (signed, main_hi is sign byte)
    disp = to_signed8(main_hi) * 256 + main_lo
    screen_x = 128 + disp / 256.0

    # Check overflow
    sx_lo_i = (128 + main_lo) & 0xFF
    carry = 1 if (128 + main_lo) > 0xFF else 0
    sx_hi_i = (main_hi + carry) & 0xFF
    if sx_hi_i != 0 and sx_hi_i != 0xFF:
        return None

    return screen_x


def ideal_project_x(view_x, view_z):
    """Ideal floating-point X projection."""
    if view_z < 2 or view_z >= 34:
        return None
    return 128.0 + view_x * 128.0 / view_z


# ══════════════════════════════════════════════════════════════════════════
# Test: Center Transform Sweep
# ══════════════════════════════════════════════════════════════════════════

def test_center_transform():
    """Sweep center coordinate transform across all parameters."""
    print("=" * 72)
    print("STAGE 1: Center Coordinate Transform")
    print("  asm: view = rotate(obj - player_hi, angle) >>7 + subpixel_correction")
    print("  ideal: view = rotate(obj - player, angle)")
    print("=" * 72)

    max_err_vx = 0.0
    max_err_vz = 0.0
    worst_vx = None
    worst_vz = None
    err_hist_vx = defaultdict(int)
    err_hist_vz = defaultdict(int)

    # Parameter ranges
    # rel positions: sweep -60 to +60 (typical game range)
    rel_range = list(range(-60, 61, 4))
    angles = list(range(0, 256, 1))  # all angles
    frac_vals = list(range(0, 256, 16))  # sample fractional positions

    total = len(rel_range)**2 * len(angles) * len(frac_vals)**2
    count = 0
    progress_step = total // 20

    for rel_x_i in rel_range:
        for rel_z_i in rel_range:
            for angle in angles:
                for px_lo in frac_vals:
                    for pz_lo in frac_vals:
                        # Set up: player at (128, 128) + fractional
                        px_hi = 128
                        pz_hi = 128
                        obj_x = (px_hi + rel_x_i) & 0xFF
                        obj_z = (pz_hi + rel_z_i) & 0xFF

                        # Fixed-point
                        result = asm_center_transform(
                            obj_x, obj_z, px_hi, px_lo, pz_hi, pz_lo, angle)
                        asm_vx = result[0] + result[2] / 256.0
                        asm_vz = result[1] + result[3] / 256.0

                        # Ideal
                        ivx, ivz = ideal_center_transform(
                            obj_x, obj_z, px_hi, px_lo, pz_hi, pz_lo, angle)

                        # Error
                        err_vx = asm_vx - ivx
                        err_vz = asm_vz - ivz

                        # Bucket errors
                        bx = round(abs(err_vx) * 4) / 4  # quarter-unit buckets
                        bz = round(abs(err_vz) * 4) / 4
                        err_hist_vx[bx] += 1
                        err_hist_vz[bz] += 1

                        if abs(err_vx) > abs(max_err_vx):
                            max_err_vx = err_vx
                            worst_vx = (obj_x, obj_z, px_hi, px_lo,
                                        pz_hi, pz_lo, angle,
                                        asm_vx, ivx)

                        if abs(err_vz) > abs(max_err_vz):
                            max_err_vz = err_vz
                            worst_vz = (obj_x, obj_z, px_hi, px_lo,
                                        pz_hi, pz_lo, angle,
                                        asm_vz, ivz)

                        count += 1
                        if progress_step and count % progress_step == 0:
                            pct = count * 100 // total
                            print(f"  [{pct:3d}%] {count}/{total} "
                                  f"max_err_vx={abs(max_err_vx):.4f} "
                                  f"max_err_vz={abs(max_err_vz):.4f}",
                                  end='\r')

    print(f"\n  Swept {count:,} parameter combinations")
    print(f"\n  --- View X error ---")
    print(f"  Max |error|: {abs(max_err_vx):.4f} units")
    if worst_vx:
        print(f"  Worst case: obj=({worst_vx[0]},{worst_vx[1]}) "
              f"player=({worst_vx[2]}.{worst_vx[3]},{worst_vx[4]}.{worst_vx[5]}) "
              f"angle={worst_vx[6]}")
        print(f"    asm={worst_vx[7]:.4f}  ideal={worst_vx[8]:.4f}  "
              f"err={max_err_vx:+.4f}")

    print(f"\n  --- View Z error ---")
    print(f"  Max |error|: {abs(max_err_vz):.4f} units")
    if worst_vz:
        print(f"  Worst case: obj=({worst_vz[0]},{worst_vz[1]}) "
              f"player=({worst_vz[2]}.{worst_vz[3]},{worst_vz[4]}.{worst_vz[5]}) "
              f"angle={worst_vz[6]}")
        print(f"    asm={worst_vz[7]:.4f}  ideal={worst_vz[8]:.4f}  "
              f"err={max_err_vz:+.4f}")

    print(f"\n  --- Error distribution (view X, |err| buckets) ---")
    for bucket in sorted(err_hist_vx.keys()):
        bar = '#' * min(60, err_hist_vx[bucket] * 60 // count)
        pct = err_hist_vx[bucket] * 100.0 / count
        if pct >= 0.01:
            print(f"    |err| <= {bucket:.2f}: {pct:6.2f}%  {bar}")

    print(f"\n  --- Error distribution (view Z, |err| buckets) ---")
    for bucket in sorted(err_hist_vz.keys()):
        bar = '#' * min(60, err_hist_vz[bucket] * 60 // count)
        pct = err_hist_vz[bucket] * 100.0 / count
        if pct >= 0.01:
            print(f"    |err| <= {bucket:.2f}: {pct:6.2f}%  {bar}")

    return abs(max_err_vx), abs(max_err_vz)


# ══════════════════════════════════════════════════════════════════════════
# Test: Trig table error
# ══════════════════════════════════════════════════════════════════════════

def test_trig_tables():
    """Characterize sin/cos table quantization error."""
    print("=" * 72)
    print("STAGE 0: Trig Table Quantization")
    print("=" * 72)

    max_sin_err = 0
    max_cos_err = 0
    max_sin_angle = 0
    max_cos_angle = 0

    for angle in range(256):
        theta = angle * 2 * math.pi / 256
        ideal_sin = math.sin(theta) * 127
        ideal_cos = math.cos(theta) * 127
        err_sin = abs(sin_table[angle] - ideal_sin)
        err_cos = abs(cos_table[angle] - ideal_cos)
        if err_sin > max_sin_err:
            max_sin_err = err_sin
            max_sin_angle = angle
        if err_cos > max_cos_err:
            max_cos_err = err_cos
            max_cos_angle = angle

    # Scale factor error: tables use 127 but ideal sin/cos peak at 1.0
    # So the "scale" is 127, but true peak of sin is 1.0
    # Table gives sin_table[64] = 127, ideal sin(π/2) * 127 = 127.0
    # The >>7 division gives /128, not /127, so there's a 1/128 scale bias
    scale_err = (127.0 / 128.0 - 1.0) * 100

    print(f"  Table scale: 127 (divide by 128 via >>7, true scale = 127/128)")
    print(f"  Scale error: {scale_err:+.2f}% (systematic, affects all multiplies)")
    print(f"  Max sin quantization: {max_sin_err:.3f}/127 at angle={max_sin_angle}")
    print(f"  Max cos quantization: {max_cos_err:.3f}/127 at angle={max_cos_angle}")
    print(f"  Max relative trig error: {max(max_sin_err, max_cos_err)/127*100:.2f}%")
    print()

    # Recip table error
    max_recip_err = 0
    max_recip_z = 0
    print(f"  --- Recip table K=8 (128/z, z=2+i/8) ---")
    for i in range(256):
        z = 2.0 + i / 8.0
        ideal = 128.0 / z
        table_val = recip_table[i]
        err = abs(table_val - ideal)
        if err > max_recip_err:
            max_recip_err = err
            max_recip_z = z
    print(f"  Max |error|: {max_recip_err:.3f} at z={max_recip_z:.2f}")

    # Show recip table at small z (where errors matter most)
    print(f"\n  z     idx  recip  ideal   err   screen_err_at_vx=10")
    for i in range(0, 72):
        z = 2.0 + i / 8.0
        ideal = 128.0 / z
        table_val = recip_table[i]
        err = table_val - ideal
        sx_err = 10 * err
        print(f"  {z:5.2f} {i:3d}   {table_val:3d}   {ideal:5.1f}  {err:+5.2f}  {sx_err:+6.1f} px")


# ══════════════════════════════════════════════════════════════════════════
# Test: Projection error at key Z values
# ══════════════════════════════════════════════════════════════════════════

def test_projection_sweep():
    """Sweep projection across vx and vz to characterize screen-space error.
    Only compares on-screen results (both asm and ideal in 0-255)."""
    print("\n" + "=" * 72)
    print("STAGE 2: Projection Error (screen_x = 128 + vx * recip[vz])")
    print("  Compares integer recip-table projection vs ideal 128*vx/vz")
    print("  Only on-screen results (0-255)")
    print("=" * 72)

    max_err = 0
    worst = None

    print(f"\n  {'vz':>3} {'recip':>5} {'ideal_r':>7} | "
          f"{'max_err':>7} {'at_vx':>5} | "
          f"{'asm_sx':>6} {'idl_sx':>7}")
    print("  " + "-" * 60)

    for vz in range(2, 34):
        # K=8 index for integer vz (frac=0)
        idx = (vz - 2) * 8
        if idx > 255:
            break
        recip_val = recip_table[idx]
        ideal_recip = 128.0 / vz
        z_max_err = 0
        z_worst_vx = 0
        z_asm_sx = 0
        z_idl_sx = 0

        for vx in range(-64, 65):
            hi, lo = smul8x8(vx, recip_val)
            asm_sx = 128.0 + (to_signed8(hi) * 256 + lo) / 256.0
            idl_sx = 128.0 + vx * 128.0 / vz

            # Only compare on-screen
            if not (0 <= asm_sx <= 255 and 0 <= idl_sx <= 255):
                continue

            err = abs(asm_sx - idl_sx)
            if err > z_max_err:
                z_max_err = err
                z_worst_vx = vx
                z_asm_sx = asm_sx
                z_idl_sx = idl_sx

            if err > max_err:
                max_err = err
                worst = (vz, vx, asm_sx, idl_sx)

        if vz <= 20 or vz % 5 == 0:
            print(f"  {vz:3d} {recip_val:5d} {ideal_recip:7.2f} | "
                  f"{z_max_err:7.2f} {z_worst_vx:+5d} | "
                  f"{z_asm_sx:6.1f} {z_idl_sx:7.2f}")

    print(f"\n  Overall max on-screen projection error: {max_err:.2f} pixels")
    if worst:
        print(f"  At vz={worst[0]}, vx={worst[1]}: "
              f"asm={worst[2]:.1f}, ideal={worst[3]:.2f}")


# ══════════════════════════════════════════════════════════════════════════
# Test: Z quantization — recip step sizes
# ══════════════════════════════════════════════════════════════════════════

def test_z_quantization():
    """Analyze K=8 recip table step sizes at eighth-unit Z resolution."""
    print("\n" + "=" * 72)
    print("STAGE 3: Z Quantization (K=8 recip steps → screen-space jumps)")
    print("  Eighth-unit Z resolution: each step = 0.125 in Z")
    print("=" * 72)

    print(f"\n  {'z':>6} {'idx':>4} {'recip':>5} {'delta':>5} | "
          f"{'base_y_jump':>11} {'sx_jump@vx=20':>14} {'sx_jump@vx=40':>14}")
    print("  " + "-" * 72)

    for idx in range(0, 255):
        z = 2.0 + idx / 8.0
        r = recip_table[idx]
        r_next = recip_table[idx + 1]
        delta = r - r_next

        by_jump = 3 * delta

        hi1, lo1 = smul8x8(20, r)
        hi2, lo2 = smul8x8(20, r_next)
        sx_jump_20 = (to_signed8(hi1)*256+lo1 - to_signed8(hi2)*256-lo2) / 256.0

        hi1, lo1 = smul8x8(40, r)
        hi2, lo2 = smul8x8(40, r_next)
        sx_jump_40 = (to_signed8(hi1)*256+lo1 - to_signed8(hi2)*256-lo2) / 256.0

        # Show all entries at small Z, then every 8th (integer Z boundaries)
        if z <= 5.0 or (idx % 8 == 0 and delta > 0):
            print(f"  {z:6.2f} {idx:4d} {r:5d} {delta:+5d} | "
                  f"{by_jump:+11d} px   {sx_jump_20:+10.1f} px   "
                  f"{sx_jump_40:+10.1f} px")


# ══════════════════════════════════════════════════════════════════════════
# Test: Full pipeline (center + corner + projection)
# ══════════════════════════════════════════════════════════════════════════

def test_full_pipeline():
    """Full pipeline sweep: object → screen coordinates.

    Only compares vertices where BOTH asm and ideal are on-screen (0-255).
    Separately characterizes Z-boundary cases.
    """
    print("\n" + "=" * 72)
    print("STAGE 4: Full Pipeline (world → screen)")
    print("  Only comparing vertices where both asm and ideal are on-screen")
    print("  Stratified by view-Z range")
    print("=" * 72)

    # Per-vz-range stats
    z_ranges = [(2, 5), (5, 10), (10, 20), (20, 34)]
    stats = {}
    for lo, hi in z_ranges:
        stats[(lo, hi)] = dict(count=0, max_err=0, worst=None,
                               sum_err=0, z_mismatch=0,
                               err_hist=defaultdict(int))

    total = 0
    total_valid = 0
    total_z_mismatch = 0

    # Sweep parameters
    half_sizes = [3, 4, 5]
    angles = list(range(0, 256, 2))  # every 2nd angle
    # Dense sweep of positions that produce various vz values
    rel_positions = []
    for rx in range(-40, 41, 4):
        for rz in range(2, 70, 2):
            rel_positions.append((rx, rz))
    frac_samples = [0, 32, 64, 96, 128, 160, 192, 224]

    for h in half_sizes:
        for rel_x, rel_z in rel_positions:
            for angle in angles:
                for px_lo in frac_samples:
                    for pz_lo in frac_samples:
                        px_hi, pz_hi = 128, 128
                        obj_x = (px_hi + rel_x) & 0xFF
                        obj_z = (pz_hi + rel_z) & 0xFF

                        # Fixed-point center
                        ct = asm_center_transform(
                            obj_x, obj_z, px_hi, px_lo, pz_hi, pz_lo, angle)
                        asm_cvx, asm_cvz, vx_frac, vz_frac = ct

                        # Ideal center
                        ivx, ivz = ideal_center_transform(
                            obj_x, obj_z, px_hi, px_lo, pz_hi, pz_lo, angle)

                        for corner in range(4):
                            total += 1

                            # Fixed-point corner (now returns 4 values)
                            asm_vx, asm_vz, asm_vxf, asm_vzf = asm_corner_offset(
                                asm_cvx & 0xFF, asm_cvz & 0xFF,
                                vx_frac, vz_frac, h, angle, corner)

                            # Ideal corner
                            icvx, icvz = ideal_corner_offset(
                                ivx, ivz, h, angle, corner)

                            # Skip if either is behind camera or beyond far clip
                            if asm_vz < 2 or asm_vz >= 34 or icvz < 2 or icvz >= 34:
                                continue

                            # Fixed-point projection
                            asm_sx = asm_project_x(asm_vx, asm_vz, asm_vxf,
                                                   asm_vzf)

                            # Ideal projection
                            idl_sx = ideal_project_x(icvx, icvz)

                            if asm_sx is None or idl_sx is None:
                                continue

                            # Only compare if both on screen (0-255)
                            if not (0 <= asm_sx <= 255 and 0 <= idl_sx <= 255):
                                continue

                            total_valid += 1
                            err = abs(asm_sx - idl_sx)

                            # Z mismatch: asm and ideal disagree on integer vz
                            z_mis = (asm_vz != int(icvz))
                            if z_mis:
                                total_z_mismatch += 1

                            # Find which range
                            ideal_vz = icvz
                            for lo, hi in z_ranges:
                                if lo <= ideal_vz < hi:
                                    s = stats[(lo, hi)]
                                    s['count'] += 1
                                    s['sum_err'] += err
                                    if z_mis:
                                        s['z_mismatch'] += 1
                                    bucket = min(20, int(err + 0.5))
                                    s['err_hist'][bucket] += 1
                                    if err > s['max_err']:
                                        s['max_err'] = err
                                        s['worst'] = dict(
                                            h=h, rel_x=rel_x, rel_z=rel_z,
                                            angle=angle, px_lo=px_lo,
                                            pz_lo=pz_lo, corner=corner,
                                            asm_vz=asm_vz, ideal_vz=icvz,
                                            asm_vx=asm_vx, ideal_vx=icvx,
                                            asm_sx=asm_sx, ideal_sx=idl_sx)
                                    break

    print(f"\n  Total vertices evaluated: {total:,}")
    print(f"  Both on-screen: {total_valid:,}")
    print(f"  Z integer mismatch: {total_z_mismatch:,} "
          f"({total_z_mismatch*100/max(1,total_valid):.1f}%)")

    overall_max = 0
    for lo, hi in z_ranges:
        s = stats[(lo, hi)]
        if s['count'] == 0:
            continue
        avg_err = s['sum_err'] / s['count']
        z_mis_pct = s['z_mismatch'] * 100.0 / s['count']

        print(f"\n  --- vz in [{lo}, {hi}) : {s['count']:,} vertices ---")
        print(f"  Max screen error: {s['max_err']:.2f} px  "
              f"Avg: {avg_err:.2f} px  "
              f"Z-mismatch: {z_mis_pct:.1f}%")

        if s['max_err'] > overall_max:
            overall_max = s['max_err']

        if s['worst']:
            w = s['worst']
            print(f"  Worst: h={w['h']} rel=({w['rel_x']},{w['rel_z']}) "
                  f"angle={w['angle']} frac=({w['px_lo']},{w['pz_lo']}) c={w['corner']}")
            print(f"    vz: asm={w['asm_vz']} ideal={w['ideal_vz']:.2f}  "
                  f"vx: asm={w['asm_vx']} ideal={w['ideal_vx']:.2f}")
            print(f"    screen_x: asm={w['asm_sx']:.1f} ideal={w['ideal_sx']:.1f}  "
                  f"err={s['max_err']:.2f}")

        # Histogram
        for bucket in sorted(s['err_hist'].keys()):
            pct = s['err_hist'][bucket] * 100.0 / s['count']
            bar = '#' * min(40, int(pct * 2))
            if bucket < 20:
                print(f"    {bucket:2d} px: {s['err_hist'][bucket]:>8,} "
                      f"({pct:5.1f}%) {bar}")
            else:
                print(f"    20+px: {s['err_hist'][bucket]:>8,} "
                      f"({pct:5.1f}%) {bar}")

    print(f"\n  Overall max on-screen error: {overall_max:.2f} px")


# ══════════════════════════════════════════════════════════════════════════
# Test: smul8x8 >>7 accuracy
# ══════════════════════════════════════════════════════════════════════════

def test_smul8x8_s7():
    """Test smul8x8 + >>7 against ideal for all input pairs."""
    print("\n" + "=" * 72)
    print("STAGE 0b: smul8x8 >>7 accuracy (rotation building block)")
    print("=" * 72)

    max_err = 0
    worst = None
    total = 0

    for a_raw in range(256):
        a = to_signed8(a_raw)
        for b_raw in range(256):
            b = to_signed8(b_raw)
            hi, lo = smul8x8_s7(a_raw, b_raw)
            asm_result = to_signed8(hi) + lo / 256.0
            ideal = a * b / 128.0

            err = abs(asm_result - ideal)
            total += 1

            if err > max_err:
                max_err = err
                worst = (a, b, asm_result, ideal, err)

    print(f"  Swept all {total:,} input pairs")
    print(f"  Max |error|: {max_err:.6f}")
    if worst:
        print(f"  Worst: ({worst[0]}) × ({worst[1]}) / 128 = "
              f"asm {worst[2]:.4f}, ideal {worst[3]:.6f}, "
              f"err {worst[4]:.6f}")
    # The >>7 operation should be exact (just shifts), so error comes from
    # the 127-vs-128 scale factor and rounding in the multiply


# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("Coordinate Transform Testbench")
    print("Comparing fixed-point (game.s) vs ideal (float) arithmetic\n")

    test_trig_tables()
    test_smul8x8_s7()
    test_projection_sweep()
    test_z_quantization()
    test_center_transform()
    test_full_pipeline()

    print("\n" + "=" * 72)
    print("DONE")
    print("=" * 72)

if __name__ == '__main__':
    main()
