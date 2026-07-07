# Virus (Zarch) for the BBC Micro

A prototype of Braben's Lander/Zarch/Virus for a stock BBC Micro: a
3D heightfield terrain renderer with a player ship, enemies, particles,
terrain collision and destruction — in MODE 2 (128×160, 4bpp), double
buffered, on a 2MHz 6502.

`python3 build.py game` produces `game.ssd` — boot it in
[jsbeeb](https://bbc.xania.org/) (SHIFT+BREAK) or run the bundled
emulator: `./emu game.bin`.

## Architecture

- **Terrain** (`grid.s`, `map.s`): a scrolling window over a byte-per-cell
  heightmap (5 bits height, 3 bits colour), rendered as a vertex grid
  with per-vertex projection, plateau/sea/land colour resolution,
  z-interpolated rows, and h-chain edge drawing. Dirty-height tracking
  bounds the next frame's clear.
- **Rasteriser** (`raster.s`): MODE 2 line drawer optimised for chains of
  short lines — run-based, colour-latched, with the 512-byte stripe
  screen layout addressed incrementally.
- **Video** (`video.s`): two 10K buffers ($3000/$5800), CRTC R12/R13
  flipping on vsync, and page-parallel clears whose loop bound is
  SMC-patched to the dirty height.
- **Objects** (`object.s`): ship/enemy/debris meshes rotated with
  quarter-square 8×8 multiplies (`math.s`), projected and drawn with
  edge dedup.
- **State**: the ship lives in `ZP_GAME` — x/y/z as 8.8 fixed point,
  yaw as an angle byte; a chase camera derives from it each frame
  (`zp_layout.inc`, `game_zp.inc`).

## Emulator and exactness harness

`emu.c` is a purpose-built 65C02 + MODE-2 emulator (SDL2 window or
headless): PPM dump, deterministic boot, key injection, a call-stack
profiler ($FE32 hook / `--profile`), per-frame framebuffer hashing
(`--hash`) and state injection (`--poke F:ADDR=VAL`).

`sample_states.py` drives the bit-exactness discipline: it derives the
ship-state addresses from the sources, injects a 620-state grid (map-wide
x/z, three altitudes, yaw sweeps), and hashes five frames per state.
`goldens.json` is the recorded baseline — all 620 sequences are distinct,
and any engine change must reproduce every hash exactly:

```
python3 build.py game          # build game.bin / game.ssd (+ emu)
python3 sample_states.py --check          # full 620-state gate
python3 sample_states.py --check --quick  # 1/8th grid while iterating
```

## Performance

Profile over 60 frames (headless, `--profile`): screen clears ~20%,
line rasteriser ~13%, terrain vertex pipeline ~10%, quarter-square
multiplies ~6%; ~21% of each frame is vsync headroom. The clears are
already page-parallel with SMC dirty-height bounds, the multiplies are
already quarter-square, and the rasteriser is already run-based — the
flagged next optimisation is frame coherence for the terrain grid
(camera motion shifts most projected vertices by a per-frame constant;
see the DOOM-engine repo's translation-coherence vertex cache for the
telescoping-identity approach that keeps such caches bit-exact).

## Files

| | |
|---|---|
| `game.s` | main loop, ship physics, camera, includes the rest |
| `grid.s` / `map.s` | terrain renderer / heightmap window |
| `raster.s` / `clip.s` / `video.s` | line drawing, clipping, buffers |
| `object.s` / `particle.s` / `status.s` | meshes, debris, status panel |
| `math.s` | quarter-square multiply, reciprocal |
| `gen_*.py` | table/map generators (provenance of the `.inc` tables) |
| `emu.c`, `sample_states.py`, `goldens.json` | emulator + exactness gate |
| `65536_division_8bit.md` | division-by-reciprocal derivation note |
