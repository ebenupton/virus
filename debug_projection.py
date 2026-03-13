#!/usr/bin/env python3
"""
Exact simulation of the assembly projection code for debugging.

Simulates the 8-bit arithmetic of project_grid for all sub_x values (0..63)
and all rows, checking for adjacent vertices with |dx| > 50.

Uses actual table data from game.bin for urecip15 simulation.
"""

import sys

BINARY = "game.bin"
BASE = 0x0800

ADDRS = {
    "sqr_lo":   0x0800 + 0x08A2,
    "sqr_hi":   0x0800 + 0x09A2,
    "sqr2_lo":  0x0800 + 0x0AA2,
    "sqr2_hi":  0x0800 + 0x0BA2,
    "lerp_lo":  0x0800 + 0x07A0,
    "lerp_hi":  0x0800 + 0x0821,
}

# Grid constants
GRID_COLS = 10
GRID_ROWS = 8
GRID_VTX_X = GRID_COLS + 1  # 11
GRID_VTX_Z = GRID_ROWS + 1  # 9
HALF_COLS = GRID_COLS // 2   # 5
HALF_ROWS = GRID_ROWS // 2   # 4
HALF_GRID_X = (GRID_COLS - 1) * 0x20  # 0x120
HALF_GRID_X_LO = HALF_GRID_X & 0xFF   # 0x20
HALF_GRID_X_HI = HALF_GRID_X >> 8     # 1


def load_table(data, addr, size=256):
    offset = addr - BASE
    return list(data[offset:offset + size])


def quarter_square_hi(a, b, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Simulate unsigned 8x8 quarter-square, return high byte only."""
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


def umul8x8(a, b, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Return (res_hi, res_lo) exactly as assembly does."""
    result = quarter_square_16(a, b, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
    return (result >> 8) & 0xFF, result & 0xFF


def normalise(z):
    """Shared normalisation for urecip15."""
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


def sim_urecip15(z, lerp_lo, lerp_hi, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi):
    """Simulate urecip15 exactly as assembly does. Returns (res_hi, res_lo)."""
    m, f, k = normalise(z)

    if m == 0x80 and f == 0:
        # Power of 2
        result = 0x8000 >> (k - 1)
        return (result >> 8) & 0xFF, result & 0xFF

    i = m & 0x7F
    t_lo = lerp_lo[i]
    t_hi = lerp_hi[i]
    d = (lerp_lo[i] - lerp_lo[i + 1]) & 0xFF

    corr = quarter_square_hi(f, d, sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)

    # x1 = T[i] - corr
    x1_lo = (t_lo - corr) & 0xFF
    borrow = 1 if t_lo < corr else 0
    x1_hi = (t_hi - borrow) & 0xFF

    # Final rescale
    shift = k - 1
    if shift == 0:
        return x1_hi, x1_lo
    elif shift >= 8:
        lo = x1_hi
        rem = shift - 8
        for _ in range(rem):
            lo = lo >> 1
        return 0, lo
    else:
        x1 = (x1_hi << 8) | x1_lo
        result = x1 >> shift
        return (result >> 8) & 0xFF, result & 0xFF


def simulate_projection(cam_x_lo, cam_z_lo_val, cam_z_hi_val, tables):
    """Simulate the full projection for a given camera position.

    Returns list of rows, each row is a list of (sx, sy) tuples.
    Also returns diagnostic info.
    """
    sqr_lo, sqr_hi, sqr2_lo, sqr2_hi, lerp_lo, lerp_hi = tables

    sub_x = cam_x_lo & 0x3F
    sub_z = cam_z_lo_val & 0x3F

    # n_vtx
    if sub_x == 0x20:
        n_vtx = GRID_VTX_X - 1
    else:
        n_vtx = GRID_VTX_X

    # n_rows
    if sub_z == 0x20:
        n_rows = GRID_VTX_Z - 1
    else:
        n_rows = GRID_VTX_Z

    # z_cam for row 0
    if sub_z < 0x20:
        val = (HALF_ROWS + 1) * 0x40
        z_cam = val - sub_z
    else:
        val = (HALF_ROWS + 2) * 0x40
        z_cam = val - sub_z

    z_cam_lo = z_cam & 0xFF
    z_cam_hi = (z_cam >> 8) & 0xFF

    rows = []
    diagnostics = []

    for row in range(n_rows):
        if z_cam_hi & 0x80 or (z_cam_hi == 0 and z_cam_lo == 0):
            # Behind camera - skip row
            vertices = [(64, 159)] * n_vtx
            rows.append(vertices)
            diagnostics.append({"row": row, "skipped": True})
        else:
            # Compute recip = urecip15(z_cam << 2)
            z_shifted = z_cam_lo
            z_shifted = (z_shifted << 1) & 0xFF
            carry1 = (z_cam_lo >> 7) & 1
            math_b = z_shifted
            a = z_cam_hi
            a = ((a << 1) | carry1) & 0xFF  # ROL
            # But actually: z_cam_lo ASL -> math_b, z_cam_hi ROL -> a
            # Then ASL math_b, ROL a again

            # Let me redo this more carefully
            # LDA z_cam_lo; ASL A -> A = (z_cam_lo << 1) & 0xFF, carry = z_cam_lo >> 7
            a_val = z_cam_lo
            a_val = (a_val << 1) & 0xFF
            c1 = (z_cam_lo >> 7) & 1
            math_b_val = a_val  # STA math_b

            # LDA z_cam_hi; ROL A -> A = (z_cam_hi << 1 | c1) & 0xFF
            a_val2 = z_cam_hi
            a_val2 = ((a_val2 << 1) | c1) & 0xFF
            c2 = (z_cam_hi >> 6) & 1  # carry out from ROL (bit 7 of original shifted out? no)
            # Wait: ROL shifts left through carry. Bit 7 goes to carry, carry goes to bit 0
            # A = z_cam_hi. Carry = c1.
            # After ROL: new_carry = (z_cam_hi >> 7) & 1. A = ((z_cam_hi << 1) | c1) & 0xFF
            c2 = (z_cam_hi >> 7) & 1
            a_val2 = ((z_cam_hi << 1) | c1) & 0xFF

            # ASL math_b -> math_b = (math_b << 1) & 0xFF, carry = math_b >> 7
            c3 = (math_b_val >> 7) & 1
            math_b_val = (math_b_val << 1) & 0xFF

            # ROL A -> A = (a_val2 << 1 | c3) & 0xFF
            c4 = (a_val2 >> 7) & 1
            math_a_val = ((a_val2 << 1) | c3) & 0xFF

            # So: z_cam << 2, split into math_a (hi) and math_b (lo)
            z_arg = (z_cam_hi << 8 | z_cam_lo) << 2
            z_arg_hi = (z_arg >> 8) & 0xFF
            z_arg_lo = z_arg & 0xFF

            # Verify
            assert math_a_val == z_arg_hi, f"math_a mismatch: {math_a_val} vs {z_arg_hi}"
            assert math_b_val == z_arg_lo, f"math_b mismatch: {math_b_val} vs {z_arg_lo}"

            z_arg_16 = (math_a_val << 8) | math_b_val
            if z_arg_16 < 3:
                vertices = [(64, 159)] * n_vtx
                rows.append(vertices)
                continue

            rh, rl = sim_urecip15(z_arg_16, lerp_lo, lerp_hi,
                                   sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
            recip_val = rl  # "LDA math_res_lo; STA recip_val"

            # sy computation
            a = recip_val
            a = a >> 1  # LSR
            a = (a + recip_val) & 0xFF  # CLC; ADC recip_val
            carry = (a + recip_val) > 0xFF if False else False
            # Wait, let me redo: LSR A gives recip/2 (no carry issue since LSR clears carry)
            # Then CLC; ADC recip_val. If recip/2 + recip > 255, carry set
            half = recip_val >> 1
            sum_1_5 = half + recip_val
            if sum_1_5 > 255:
                # overflow in recip*1.5 → near clamp
                sy = 159  # placeholder, will be clamped
            else:
                sum_sy = sum_1_5 + 80
                if sum_sy > 255:
                    sy = 159  # near clamp
                else:
                    sy = sum_sy
                    if sy >= 160:
                        sy = 159
            # (simplified - not simulating clamp_near_sy/clamp_far_sy exactly)

            # Step computation
            step_hi = recip_val >> 2
            step_lo = ((recip_val & 0x03) << 6) & 0xFF

            # Run starts at $4000, subtract step HALF_COLS times
            run_lo = 0
            run_hi = 64
            for _ in range(HALF_COLS):
                sub = run_lo - step_lo
                borrow = 1 if sub < 0 else 0
                run_lo = sub & 0xFF
                run_hi = (run_hi - step_hi - borrow) & 0xFF

            # Clamp computation (decomposed)
            mul_hi, mul_lo = umul8x8(HALF_GRID_X_LO, recip_val,
                                      sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
            offset_sum = mul_hi + recip_val  # HALF_GRID_X_HI=1, so add recip once
            if offset_sum > 255:
                clamp_left = 0
                clamp_right = 127
            else:
                offset = offset_sum
                cr = offset + 64
                if cr > 255 or cr >= 128:
                    clamp_right = 127
                else:
                    clamp_right = cr

                cl = 64 - offset
                if cl < 0:
                    clamp_left = 0
                else:
                    clamp_left = cl

            # sub_x offset
            if sub_x != 0:
                if sub_x < 0x20:
                    # run -= sub_x * recip
                    mh, ml = umul8x8(sub_x, recip_val,
                                      sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
                    sub = run_lo - ml
                    borrow = 1 if sub < 0 else 0
                    run_lo = sub & 0xFF
                    run_hi = (run_hi - mh - borrow) & 0xFF
                else:
                    # run += ($40 - sub_x) * recip
                    adj = (sub_x ^ 0x3F) + 1  # = $40 - sub_x
                    mh, ml = umul8x8(adj & 0xFF, recip_val,
                                      sqr_lo, sqr_hi, sqr2_lo, sqr2_hi)
                    add = run_lo + ml
                    carry = 1 if add > 255 else 0
                    run_lo = add & 0xFF
                    run_hi = (run_hi + mh + carry) & 0xFF

            # Column loop
            vertices = []
            cur_run_lo = run_lo
            cur_run_hi = run_hi

            for col_idx in range(n_vtx):
                proj_col = n_vtx - col_idx  # counts down from n_vtx to 1

                sx = cur_run_hi

                # Clamp first/last
                if proj_col == n_vtx:
                    # First vertex (leftmost): max(clamp_left, run_hi)
                    if sx & 0x80:  # BMI - negative
                        sx = clamp_left
                    elif sx < clamp_left:
                        sx = clamp_left
                elif proj_col == 1:
                    # Last vertex (rightmost): min(clamp_right, run_hi)
                    if sx >= clamp_right:
                        sx = clamp_right

                vertices.append((sx, sy))

                # Advance run
                if col_idx < n_vtx - 1:
                    add = cur_run_lo + step_lo
                    carry = 1 if add > 255 else 0
                    cur_run_lo = add & 0xFF
                    cur_run_hi = (cur_run_hi + step_hi + carry) & 0xFF

            rows.append(vertices)

            diag = {
                "row": row,
                "z_cam": (z_cam_hi << 8) | z_cam_lo,
                "recip": recip_val,
                "step": (step_hi << 8) | step_lo,
                "run_start": (run_hi << 8) | run_lo,
                "clamp_left": clamp_left,
                "clamp_right": clamp_right,
                "n_vtx": n_vtx,
            }
            diagnostics.append(diag)

        # Advance z_cam
        z_cam_lo = (z_cam_lo + 0x40) & 0xFF
        if z_cam_lo < 0x40:  # carry
            z_cam_hi = (z_cam_hi + 1) & 0xFF

    return rows, diagnostics


def check_long_segments(rows, diagnostics, sub_x, threshold=50):
    """Check for segments with |dx| > threshold."""
    issues = []
    for row_idx, row_vtx in enumerate(rows):
        for i in range(len(row_vtx) - 1):
            sx0 = row_vtx[i][0]
            sx1 = row_vtx[i + 1][0]
            dx = abs(sx1 - sx0)
            if dx > threshold:
                diag = diagnostics[row_idx] if row_idx < len(diagnostics) else {}
                issues.append({
                    "sub_x": sub_x,
                    "row": row_idx,
                    "vtx": i,
                    "sx0": sx0,
                    "sx1": sx1,
                    "dx": dx,
                    "diag": diag,
                })
    return issues


def main():
    with open(BINARY, "rb") as f:
        data = f.read()

    sqr_lo  = load_table(data, ADDRS["sqr_lo"])
    sqr_hi  = load_table(data, ADDRS["sqr_hi"])
    sqr2_lo = load_table(data, ADDRS["sqr2_lo"])
    sqr2_hi = load_table(data, ADDRS["sqr2_hi"])
    lerp_lo = load_table(data, ADDRS["lerp_lo"], size=129)
    lerp_hi = load_table(data, ADDRS["lerp_hi"], size=129)
    tables = (sqr_lo, sqr_hi, sqr2_lo, sqr2_hi, lerp_lo, lerp_hi)

    # Use a fixed cam_z that matches the initial camera position
    # cam_z = $FDC0 → cam_z_lo = $C0, cam_z_hi = $FD
    # But project_grid uses sub_z from cam_z_lo, so we test various positions

    # Test with the starting camera z ($FDC0) and sweep all sub_x
    cam_z_lo = 0xC0
    cam_z_hi = 0xFD  # not directly used in projection - z_cam derived from sub_z

    all_issues = []

    # Test all sub_x values (0..63)
    for sub_x in range(64):
        cam_x_lo = sub_x  # cam_x_hi doesn't affect projection directly
        rows, diags = simulate_projection(cam_x_lo, cam_z_lo, cam_z_hi, tables)
        issues = check_long_segments(rows, diags, sub_x)
        all_issues.extend(issues)

    if not all_issues:
        print("No long segments found (|dx| > 50) for any sub_x with starting cam_z")
        print("\nTrying different cam_z values...")

        # Try various cam_z values
        for cam_z_lo in range(0, 64, 1):  # sub_z varies 0..63
            for sub_x in range(64):
                cam_x_lo = sub_x
                rows, diags = simulate_projection(cam_x_lo, cam_z_lo, 0xFD, tables)
                issues = check_long_segments(rows, diags, sub_x)
                if issues:
                    all_issues.extend(issues)

    if not all_issues:
        print("No long segments found for any sub_x/sub_z combination!")
        return 0

    # Report findings
    print(f"Found {len(all_issues)} segments with |dx| > 50\n")

    # Group by sub_x
    by_sub_x = {}
    for issue in all_issues:
        sx = issue["sub_x"]
        if sx not in by_sub_x:
            by_sub_x[sx] = []
        by_sub_x[sx].append(issue)

    for sx in sorted(by_sub_x.keys()):
        issues = by_sub_x[sx]
        print(f"=== sub_x = {sx} (${sx:02X}) ===")
        for iss in issues[:5]:  # limit output
            d = iss["diag"]
            print(f"  Row {iss['row']}: vtx[{iss['vtx']}].sx={iss['sx0']} → "
                  f"vtx[{iss['vtx']+1}].sx={iss['sx1']} (dx={iss['dx']})")
            if d and not d.get("skipped"):
                print(f"    z_cam=${d['z_cam']:04X} recip={d['recip']} "
                      f"step=${d['step']:04X} run_start=${d['run_start']:04X}")
                print(f"    clamp=[{d['clamp_left']}, {d['clamp_right']}] n_vtx={d['n_vtx']}")

                # Show all vertex sx values for this row
                rows, _ = simulate_projection(sx, 0xC0, 0xFD,  # use same cam_z
                                               tables)
                if iss['row'] < len(rows):
                    vtx_sx = [v[0] for v in rows[iss['row']]]
                    print(f"    all sx: {vtx_sx}")
        if len(issues) > 5:
            print(f"  ... and {len(issues) - 5} more")
        print()

    # Detailed analysis of worst case
    worst = max(all_issues, key=lambda x: x["dx"])
    print(f"\n=== WORST CASE: sub_x={worst['sub_x']}, row={worst['row']}, "
          f"dx={worst['dx']} ===")
    d = worst["diag"]
    if d and not d.get("skipped"):
        print(f"z_cam=${d['z_cam']:04X}, recip={d['recip']}, "
              f"step=${d['step']:04X}")
        print(f"clamp=[{d['clamp_left']}, {d['clamp_right']}]")

        # Trace through all vertices
        rows, diags = simulate_projection(worst['sub_x'], 0xC0, 0xFD, tables)
        row_vtx = rows[worst['row']]
        print(f"\nAll vertices for this row:")
        for i, (sx, sy) in enumerate(row_vtx):
            marker = " <<<" if i == worst['vtx'] or i == worst['vtx'] + 1 else ""
            print(f"  vtx[{i}]: sx={sx:3d} sy={sy:3d}{marker}")

        # Check: what SHOULD the sx be (true mathematical value)?
        recip = d['recip']
        step_16 = d['step']
        run_start = d['run_start']

        print(f"\n16-bit run trace:")
        run = run_start
        for i in range(d['n_vtx']):
            run_hi = (run >> 8) & 0xFF
            print(f"  vtx[{i}]: run=${run:04X} run_hi=${run_hi:02X}={run_hi}")
            run = (run + step_16) & 0xFFFF

    return 1 if all_issues else 0


if __name__ == "__main__":
    sys.exit(main())
