#!/usr/bin/env python3
"""Bit-exactness sampler for the Virus engine.

Reverse-engineered state: the ship lives in ZP_GAME (zp_layout.inc) —
ship_x/y/z as 8.8 fixed point at ZP_GAME+16..21, ship_yaw at ZP_GAME+8;
the chase camera derives from it each frame. This tool injects ship
states over a broad grid via the emulator's --poke hook, runs a few
frames per sample, and records an FNV-1a64 hash of both screen buffers
per frame (--hash).

    python3 sample_states.py --golden          # write goldens.json
    python3 sample_states.py --check           # compare current build
    python3 sample_states.py --check --quick   # 1/8th of the grid

Any code change must keep every hash identical (the doom-engine
discipline: measured cycles may change, pixels may not).
"""
import argparse, json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)

INJECT_FRAME = 5          # after init/attract settle
FRAMES = INJECT_FRAME + 5 # hash the injected frame + 4 successors
GOLDEN = 'goldens.json'


def zp_addrs():
    """Derive injection addresses from the CURRENT sources, so a ZP
    relayout in an optimisation pass retargets the pokes automatically."""
    base = None
    for line in open('zp_layout.inc'):
        m = re.match(r'ZP_GAME\s*=\s*\$([0-9A-Fa-f]+)', line)
        if m:
            base = int(m.group(1), 16)
    assert base is not None, 'ZP_GAME not found'
    offs = {}
    src = open('game.s').read() + open('game_zp.inc').read()
    for name in ('ship_x_lo', 'ship_x_hi', 'ship_y_lo', 'ship_y_hi',
                 'ship_z_lo', 'ship_z_hi', 'ship_yaw'):
        m = re.search(rf'{name}\s*=\s*ZP_GAME\s*\+\s*(\d+)', src)
        assert m, f'{name} not found'
        offs[name] = base + int(m.group(1))
    return offs


def grid():
    """The sample grid: x,z across the map, three altitudes, eight yaws.
    Every sample is injected identically into baseline and candidate
    builds, so even physically odd states are valid exactness probes."""
    samples = []
    for xh in range(2, 30, 4):            # x hi byte across the map
        for zh in range(2, 30, 4):
            for yh, ylo in ((2, 0x00), (4, 0x80), (8, 0x00)):
                for yaw in range(0, 256, 64):
                    samples.append((xh, zh, yh, ylo, yaw))
    # denser yaw sweep at a few interesting spots
    for yaw in range(0, 256, 16):
        samples.append((16, 16, 3, 0x40, yaw))
        samples.append((6, 24, 5, 0x00, yaw))
    return samples


def run_sample(addrs, s):
    xh, zh, yh, ylo, yaw = s
    F = INJECT_FRAME
    pokes = [
        (addrs['ship_x_lo'], 0x00), (addrs['ship_x_hi'], xh),
        (addrs['ship_z_lo'], 0x00), (addrs['ship_z_hi'], zh),
        (addrs['ship_y_lo'], ylo), (addrs['ship_y_hi'], yh),
        (addrs['ship_yaw'], yaw),
    ]
    cmd = ['./emu', 'game.bin', '--headless', str(FRAMES), '--hash']
    for a, v in pokes:
        cmd += ['--poke', f'{F}:{a:x}={v:x}']
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    hashes = [l.split()[1] for l in r.stdout.strip().split('\n')[F:]]
    return ','.join(f'{v:02x}' for v in s), hashes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--golden', action='store_true')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--quick', action='store_true')
    args = ap.parse_args()
    addrs = zp_addrs()
    samples = grid()
    if args.quick:
        samples = samples[::8]
    results = {}
    with ThreadPoolExecutor(max_workers=8) as ex:
        for key, hashes in ex.map(lambda s: run_sample(addrs, s), samples):
            results[key] = hashes
    if args.golden:
        json.dump(results, open(GOLDEN, 'w'), indent=0, sort_keys=True)
        print(f'GOLDEN: {len(results)} samples x {FRAMES-INJECT_FRAME} frames -> {GOLDEN}')
        return
    gold = json.load(open(GOLDEN))
    bad = 0
    for k, h in sorted(results.items()):
        if k not in gold:
            print(f'  {k}: NOT IN GOLDEN'); bad += 1
        elif gold[k] != h:
            print(f'  {k}: MISMATCH'); bad += 1
    print(f'SAMPLE CHECK: {len(results)} samples, {bad} mismatches — '
          + ('PASS' if bad == 0 else 'FAIL'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
