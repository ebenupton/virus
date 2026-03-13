#!/usr/bin/env python3
"""Analyze Range 2 quantization: current coarse vs improved full K=8."""
import sys, math
sys.path.insert(0, '.')
from validate import (recip_table, recip_lo_table, to_signed8, smul8x8,
                       smul8x8_s7, apply_recip_shift)

# Simulate a sweep of vz from 64 to 100 with vx_temp=30 (typical far object)
vx = 30
print(f"Range 2 analysis: vx_temp={vx}, showing recip_val jumps\n")
print(f"{'vz':>4} {'vzf':>4} | {'cur_rv':>6} {'cur_eff':>7} {'cur_disp':>8} | {'imp_rv':>6} {'imp_rlo':>7} {'imp_eff':>7} {'imp_disp':>8} | {'ideal':>7}")
print("-" * 95)

prev_cur, prev_imp = None, None
for vz_temp in range(66, 100):
    for vz_frac in [0, 128]:
        # Current Range 2 (coarse)
        if vz_temp >= 68:
            half_z = vz_temp >> 1
            quarter_z = half_z >> 1
            cur_sub = 4 if (half_z & 1) else 0
            cur_idx = ((quarter_z - 2) << 3) | cur_sub
            cur_rv = recip_table[cur_idx]
            cur_rlo = 0
            shift = 2
        else:
            # Range 1 for comparison
            carry = vz_temp & 1
            half_int = vz_temp >> 1
            cur_sub = (carry << 2) | (vz_frac >> 6)
            cur_idx = ((half_int - 2) << 3) | cur_sub
            cur_rv = recip_table[cur_idx]
            cur_rlo = recip_lo_table[cur_idx]
            shift = 1

        # Improved Range 2 (full K=8)
        if vz_temp >= 68:
            imp_sub = ((vz_temp & 3) * 2) + (vz_frac >> 7)
            quarter_int = vz_temp >> 2
            imp_idx = ((quarter_int - 2) << 3) | imp_sub
            imp_rv = recip_table[imp_idx]
            imp_rlo = recip_lo_table[imp_idx]
            imp_shift = 2
        else:
            imp_sub = (carry << 2) | (vz_frac >> 6)
            imp_idx = cur_idx
            imp_rv = cur_rv
            imp_rlo = cur_rlo
            imp_shift = 1

        # Compute displacements
        ch, cl = smul8x8(vx, cur_rv)
        ch, cl = apply_recip_shift(ch, cl, shift)
        cur_disp = to_signed8(ch) * 256 + cl

        ih, il = smul8x8(vx, imp_rv)
        ih, il = apply_recip_shift(ih, il, imp_shift)
        # Add recip_lo correction
        crh, crl = smul8x8_s7(vx, imp_rlo)
        crh, crl = apply_recip_shift(crh, crl, imp_shift)
        imp_disp = to_signed8(ih) * 256 + il + to_signed8(crh)

        ideal = 128.0 / (vz_temp + vz_frac/256.0) * vx

        cur_eff = cur_rv / (1 << shift)
        imp_eff = imp_rv / (1 << imp_shift)

        cur_jump = " ***" if prev_cur is not None and abs(cur_disp - prev_cur) > 3 else ""
        imp_jump = " ***" if prev_imp is not None and abs(imp_disp - prev_imp) > 3 else ""

        if vz_temp >= 67 and vz_temp <= 70 or cur_jump or imp_jump:
            print(f"{vz_temp:4d} {vz_frac:4d} | {cur_rv:6d} {cur_eff:7.2f} {cur_disp:8d}{cur_jump:4s} | "
                  f"{imp_rv:6d} {imp_rlo:+7d} {imp_eff:7.2f} {imp_disp:8d}{imp_jump:4s} | {ideal:7.2f}")

        prev_cur = cur_disp
        prev_imp = imp_disp
