#!/usr/bin/env python3
"""Generate a 32x32 toroidally-wrapping plasma fractal heightmap.

Diamond-square on a torus: all indices mod N, every point has exactly
4 neighbours, edges wrap seamlessly in both axes.

Pipeline:
  1. Generate fractal heightmap
  2. Binary search for sea level S giving ~40% water
  3. Find peak, smooth to 9-cell average → H
  4. Rotate map so peak is centred at (16, 16)
  5. Scale: S→0, H→31
  6. Probabilistic colour bits whose density varies linearly with height

Byte format: [height:5][color:3]
  - Bits 3-7: height (0..31), 0 = sea level
  - Bits 0-2: edge colour pattern, indexed into edge_color_lut
    - Land patterns: 000=(Y,Y), 110=(G,G); plateau uses 001,010,011,100,101,111
    - Sea patterns: 000=(Cy,Cy), 010=(B,Cy), 100=(Cy,B), 110=(B,B)

Outputs:
  - map_data.inc    : ca65 .byte directives (32×32 = 1024 bytes)
  - map_preview.ppm : colour visualisation (3×3 tiled, 4x scale)
"""

import random

SIZE = 32
SEED = 42


def diamond_square_torus(size, roughness=0.35, seed=SEED):
    """Generate a size×size heightmap on a torus using diamond-square."""
    n = size
    grid = [[0.0] * n for _ in range(n)]
    rng = random.Random(seed)

    # Seed origin (the only unique corner on a torus)
    grid[0][0] = rng.uniform(-1, 1)

    step = n
    scale = 1.0

    while step > 1:
        half = step // 2

        # Diamond step: center of each step×step square
        for y in range(0, n, step):
            for x in range(0, n, step):
                avg = (grid[y][x] +
                       grid[y][(x + step) % n] +
                       grid[(y + step) % n][x] +
                       grid[(y + step) % n][(x + step) % n]) / 4.0
                grid[(y + half) % n][(x + half) % n] = avg + rng.uniform(-scale, scale)

        # Square step: axis-aligned midpoints
        for y in range(0, n, step):
            for x in range(0, n, step):
                # Top-edge midpoint: (y, x+half)
                avg = (grid[y][x] +
                       grid[y][(x + step) % n] +
                       grid[(y - half) % n][(x + half) % n] +
                       grid[(y + half) % n][(x + half) % n]) / 4.0
                grid[y][(x + half) % n] = avg + rng.uniform(-scale, scale)

                # Left-edge midpoint: (y+half, x)
                avg = (grid[y][x] +
                       grid[(y + step) % n][x] +
                       grid[(y + half) % n][(x - half) % n] +
                       grid[(y + half) % n][(x + half) % n]) / 4.0
                grid[(y + half) % n][x] = avg + rng.uniform(-scale, scale)

        scale *= roughness
        step = half

    return grid


def main():
    # Step 1: Fractal generation
    grid = diamond_square_torus(SIZE, roughness=0.35)

    # Step 2: Binary search for sea level S giving ~40% water
    flat = [grid[y][x] for y in range(SIZE) for x in range(SIZE)]
    lo, hi = min(flat), max(flat)
    target = 0.40
    s_lo, s_hi = lo, hi
    for _ in range(50):
        mid = (s_lo + s_hi) / 2.0
        frac = sum(1 for v in flat if v <= mid) / len(flat)
        if frac < target:
            s_lo = mid
        else:
            s_hi = mid
    S = (s_lo + s_hi) / 2.0

    # Step 3: Find highest point, smooth to 9-cell average → H
    max_val = -1e9
    peak_x, peak_y = 0, 0
    for y in range(SIZE):
        for x in range(SIZE):
            if grid[y][x] > max_val:
                max_val = grid[y][x]
                peak_x, peak_y = x, y

    total = 0.0
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            total += grid[(peak_y + dy) % SIZE][(peak_x + dx) % SIZE]
    H = total / 9.0
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            grid[(peak_y + dy) % SIZE][(peak_x + dx) % SIZE] = H

    # Step 4: Rotate map toroidally so peak is at (16, 16)
    shift_x = (16 - peak_x) % SIZE
    shift_y = (16 - peak_y) % SIZE
    rotated = [[grid[(y - shift_y) % SIZE][(x - shift_x) % SIZE]
                for x in range(SIZE)] for y in range(SIZE)]
    grid = rotated

    # Step 4b: Set 5×5 plateau vertices to average of 16 border vertices
    PLAT_MIN, PLAT_MAX = 14, 18
    border_sum = 0.0
    border_count = 0
    for y in range(PLAT_MIN, PLAT_MAX + 1):
        for x in range(PLAT_MIN, PLAT_MAX + 1):
            if y == PLAT_MIN or y == PLAT_MAX or x == PLAT_MIN or x == PLAT_MAX:
                border_sum += grid[y][x]
                border_count += 1
    plat_avg = border_sum / border_count
    for y in range(PLAT_MIN, PLAT_MAX + 1):
        for x in range(PLAT_MIN, PLAT_MAX + 1):
            grid[y][x] = plat_avg

    # Step 5: Find lowest height D
    D = min(grid[y][x] for y in range(SIZE) for x in range(SIZE))

    # Step 6: Scale — map H→31, S→0 (H is now plat_avg since peak was smoothed to it)
    H = plat_avg
    scale = 31.0 / (H - S)

    # Step 7a: Quantize heights
    heights = [[0]*SIZE for _ in range(SIZE)]
    for y in range(SIZE):
        for x in range(SIZE):
            scaled = (grid[y][x] - S) * scale
            heights[y][x] = max(0, min(31, int(round(scaled))))

    # Step 7b: Force plateau to height 31
    plat_h = 31
    for y in range(PLAT_MIN, PLAT_MAX + 1):
        for x in range(PLAT_MIN, PLAT_MAX + 1):
            heights[y][x] = plat_h

    # Step 7c: Pack bytes with colour bits (using clamped heights, original Q for colour)
    rng = random.Random(SEED + 1)
    packed = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            Q = grid[y][x]
            h = heights[y][x]
            # Normalised distance from sea level (0 at coast, 1 at extreme)
            if Q >= S:
                norm = (Q - S) / (H - S) if H != S else 0.0
            else:
                norm = (S - Q) / (S - D) if S != D else 0.0
            norm = max(0.0, min(1.0, norm))
            # Colour bit probability: near-coast band → 0; otherwise 100%
            P = 0.0 if norm < 0.1 else 1.0
            # Two random bits
            bit6 = 1 if rng.random() < P else 0
            bit7 = 1 if rng.random() < P else 0
            byte = (h << 3) | (bit7 << 2) | (bit6 << 1)
            row.append(byte)
        packed.append(row)

    # Step 7d: Eliminate isolated colour bits (1D median filter per axis)
    # Bit 6: smooth against x-direction neighbours
    # Bit 7: smooth against z-direction neighbours
    # Iterate until stable (alternating patterns need multiple passes)
    changed = True
    while changed:
        changed = False
        prev = [row[:] for row in packed]
        for y in range(SIZE):
            for x in range(SIZE):
                byte = prev[y][x]
                # Bit 1: check x-direction neighbours
                b6 = (byte >> 1) & 1
                b6_l = (prev[y][(x - 1) % SIZE] >> 1) & 1
                b6_r = (prev[y][(x + 1) % SIZE] >> 1) & 1
                if b6 != b6_l and b6_l == b6_r:
                    byte = (byte & ~(1 << 1)) | (b6_l << 1)
                    changed = True
                # Bit 2: check z-direction neighbours
                b7 = (byte >> 2) & 1
                b7_u = (prev[(y - 1) % SIZE][x] >> 2) & 1
                b7_d = (prev[(y + 1) % SIZE][x] >> 2) & 1
                if b7 != b7_u and b7_u == b7_d:
                    byte = (byte & ~(1 << 2)) | (b7_u << 2)
                    changed = True
                packed[y][x] = byte

    # Step 7e: Remap edge colour patterns for LUT compatibility
    # Patterns 010 and 100 are reserved for plateau boundary edges.
    # Remap non-plateau land cells: 010 → 000, 100 → 110
    # Plateau: 4×4 cells = 5×5 vertices centred at (16,16)
    PLATEAU_CELLS = {(y, x) for y in range(PLAT_MIN, PLAT_MAX + 1)
                     for x in range(PLAT_MIN, PLAT_MAX + 1)}
    for y in range(SIZE):
        for x in range(SIZE):
            if (y, x) in PLATEAU_CELLS:
                continue
            byte = packed[y][x]
            if (byte >> 3) == 0:
                continue  # sea cell, patterns fine
            pattern = byte & 7
            if pattern == 0b010:  # 010 → 000: clear bit 1
                packed[y][x] = byte & ~0x02
            elif pattern == 0b100:  # 100 → 110: set bit 1
                packed[y][x] = byte | 0x02

    # Step 7f: Override plateau cells with computed byte values
    # Edge rules: outline=WHITE, internal=BLACK, outgoing=GREEN
    color_to_pattern = {
        ('W', 'W'): 0b001, ('W', 'B'): 0b101, ('G', 'W'): 0b010,
        ('B', 'W'): 0b011, ('B', 'B'): 0b111, ('W', 'G'): 0b100,
        ('G', 'G'): 0b110,
    }
    for y in range(PLAT_MIN, PLAT_MAX + 1):
        for x in range(PLAT_MIN, PLAT_MAX + 1):
            # h-edge: right from (y,x) to (y,x+1)
            if x == PLAT_MAX:
                h = 'G'  # outgoing right
            elif y == PLAT_MIN or y == PLAT_MAX:
                h = 'W'  # top/bottom outline
            else:
                h = 'B'  # internal
            # v-edge: down from (y,x) to (y+1,x)
            if y == PLAT_MAX:
                v = 'G'  # outgoing down
            elif x == PLAT_MIN or x == PLAT_MAX:
                v = 'W'  # left/right outline
            else:
                v = 'B'  # internal
            pattern = color_to_pattern[(h, v)]
            packed[y][x] = (plat_h << 3) | pattern

    # Step 8: Write assembly include
    with open("map_data.inc", "w") as f:
        f.write("; 32x32 toroidally-wrapping plasma fractal heightmap\n")
        f.write("; Generated by gen_map.py\n")
        f.write("; Byte format: [height:5][color:3]\n")
        f.write("; Bits 0-2 = edge colour pattern for edge_color_lut\n\n")
        f.write('.segment "HEIGHTMAP"\n')
        f.write("height_map:\n")
        for y in range(SIZE):
            vals = ", ".join(f"${v:02X}" for v in packed[y])
            f.write(f"    .byte {vals}  ; row {y}\n")

    # Step 9: Generate 16×32 pixel minimap in MODE 2 format (256 bytes)
    # Each pixel = 2×1 map cells (2 columns, 1 row — no y subsampling).
    # Green/yellow if any land in 3×3 neighbourhood (yellow if colour bits
    # predominantly 0), blue for sea, black for plateau centre.
    # Output: column-major — 8 columns of 32 bytes, indexed by scanline.
    def mode2_byte(left_col, right_col):
        """Encode two 4-bit MODE 2 colours into one byte."""
        b = 0
        for bit in range(4):
            if left_col & (1 << bit):
                b |= (1 << (bit * 2 + 1))
            if right_col & (1 << bit):
                b |= (1 << (bit * 2))
        return b

    COL_BLACK, COL_GREEN, COL_YELLOW, COL_BLUE = 0, 2, 3, 4
    MINI_W, MINI_H_EFF = 16, 32  # effective pixel dimensions (no y subsampling)

    # Build effective pixel grid
    mini_colors = [[COL_BLUE] * MINI_W for _ in range(MINI_H_EFF)]
    for ey in range(MINI_H_EFF):
        for px in range(MINI_W):
            # Check 3×3 cells centred on (2*px, ey)
            has_land = False
            zeros, ones = 0, 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    cy = (ey + dy) % SIZE
                    cx = (2 * px + dx) % SIZE
                    cell = packed[cy][cx]
                    if cell >> 3:
                        has_land = True
                        b6 = (cell >> 1) & 1
                        b7 = (cell >> 2) & 1
                        zeros += (1 - b6) + (1 - b7)
                        ones += b6 + b7
            if has_land:
                mini_colors[ey][px] = COL_YELLOW if zeros > ones else COL_GREEN

    # Draw 2×4 black dot at centre (plateau at map 16,16 → pixel 8,16)
    # 4 rows tall to match pre-subsampling visual size
    for dy in range(4):
        for dx in range(2):
            mini_colors[14 + dy][7 + dx] = COL_BLACK

    # Encode in BBC Micro character-cell order: 4 stripes of 64 bytes.
    # Within each stripe: 8 character columns × 8 scanlines per cell.
    # Byte order: col0_line0, col0_line1, ..., col0_line7, col1_line0, ...
    minimap_bytes = []
    for stripe in range(4):
        for col in range(8):
            for scanline in range(8):
                pixel_row = stripe * 8 + scanline
                minimap_bytes.append(mode2_byte(
                    mini_colors[pixel_row][col * 2],
                    mini_colors[pixel_row][col * 2 + 1]))

    assert len(minimap_bytes) == 256, f"Minimap is {len(minimap_bytes)} bytes, expected 256"

    # Append minimap to assembly include (4 stripes of 64 bytes)
    with open("map_data.inc", "a") as f:
        f.write('\n.segment "CODE"\n')
        f.write("; 16x32 pixel minimap in MODE 2 character-cell format (256 bytes)\n")
        f.write("; 4 stripes of 64 bytes: 8 char cols × 8 scanlines per cell\n")
        f.write("; Green/Yellow=land, Blue=sea, Black=plateau centre\n")
        f.write("minimap_data:\n")
        for stripe in range(4):
            f.write(f"    ; stripe {stripe} (character rows {stripe*8}-{stripe*8+7})\n")
            for col in range(8):
                offset = stripe * 64 + col * 8
                vals = ", ".join(f"${v:02X}" for v in minimap_bytes[offset:offset + 8])
                f.write(f"    .byte {vals}  ; col {col}\n")

    # Write PPM preview: 3×3 tile to show wrapping, 4x pixel scale
    tile = 3
    px_scale = 4
    pw = SIZE * tile * px_scale
    ph = SIZE * tile * px_scale
    with open("map_preview.ppm", "wb") as f:
        f.write(f"P6\n{pw} {ph}\n255\n".encode())
        for ty in range(SIZE * tile):
            row_bytes = bytearray()
            y = ty % SIZE
            for tx in range(SIZE * tile):
                x = tx % SIZE
                h = packed[y][x] >> 3
                bit6 = (packed[y][x] >> 1) & 1
                bit7 = (packed[y][x] >> 2) & 1
                if h == 0:
                    # Sea: cyan (0,255,255) → blue (0,0,255) based on bits
                    sea_t = (bit6 + bit7) / 2.0
                    r = 0
                    g = int(255 * (1 - sea_t))
                    b = 255
                else:
                    # Land: yellow (255,255,0) → green (0,255,0) based on bits
                    bright = 0.3 + 0.7 * h / 31.0
                    land_t = (bit6 + bit7) / 2.0
                    r = int(255 * (1 - land_t) * bright)
                    g = int(255 * bright)
                    b = 0
                for _ in range(px_scale):
                    row_bytes += bytes([r, g, b])
            for _ in range(px_scale):
                f.write(row_bytes)

    # Stats
    water = sum(1 for y in range(SIZE) for x in range(SIZE)
                if (packed[y][x] >> 3) == 0)
    max_h = max(packed[y][x] >> 3 for y in range(SIZE) for x in range(SIZE))
    print(f"Map: {SIZE}x{SIZE} (toroidal), height range 0..{max_h}")
    print(f"Water cells: {water}/{SIZE*SIZE} ({100*water/SIZE/SIZE:.1f}%)")
    print(f"Peak at (16, 16), S={S:.4f}, H={H:.4f}, D={D:.4f}")
    print(f"Plateau: 4x4 cells at ({PLAT_MIN},{PLAT_MIN})-({PLAT_MAX},{PLAT_MAX})")
    print(f"Wrote map_data.inc ({SIZE*SIZE} bytes)")
    print(f"Wrote map_preview.ppm ({pw}x{ph}, 3x3 tiled)")


if __name__ == "__main__":
    main()
