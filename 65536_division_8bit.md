# 65536/z via 8-bit Table Lookup
## (Using only u8×u8→16 unsigned multiplication)

**Input range**: z ∈ [3, 32767] (15-bit unsigned)  
**Output range**: Q ∈ [2, 21845] (15-bit unsigned, fits in same representation)

Two algorithms are described: a Newton-Raphson refinement (two multiplies, more
accuracy headroom) and a linear interpolation (one multiply, slightly tighter
accuracy margin). Both use the same normalisation step.

---

## Common Setup: Normalisation

Find k = ⌊log₂(z)⌋, the position of the MSB. With z ∈ [3, 32767], k is
strictly in **[1, 14]**.

On an 8-bit CPU: check whether the high byte is non-zero first, then find the
MSB within the relevant byte using a 128-entry CLZ table (bit 7 of the high
byte is always clear for z ≤ 32767, so only 128 entries needed).

Left-shift z to a normalised form Z with the MSB at a known position:

```
Z = z << (15 − k)       // Z ∈ [32768, 65535]
```

Extract the top 8 bits (with MSB forced set) as the mantissa m:

```
m = Z >> 8              // m ∈ [128, 255]
```

Powers of 2 give m = 128 exactly — handle as a special case, returning
`65536 >> k` directly.

---

## Algorithm 1: Newton-Raphson (two multiplies)

### Table

The 256-byte table stores `T[m] = ⌊32768/m⌋` for m ∈ [128, 255].  
Since 32768/m ∈ [128, 256] for this range, every entry fits in a byte.

```
x0 = T[m]               // 8-bit initial estimate, ≈ 2¹⁵/m
```

### The N-R Step

**Multiply 1** — extract the remainder:
```
P   = m × x0            // u8×u8→16 ✓, P ≈ 32768
δ   = 32768 − P         // exact remainder; always < m ≤ 255, so 8-bit ✓
```

**Multiply 2** — form the correction:
```
corr = x0 × δ           // u8×u8→16 ✓
x1   = (x0 << 8) + (corr >> 7)   // 16-bit result ≈ 2²³/m
```

**Final rescale:**
```
Q = x1 >> k             // k ∈ [1, 14]; result ∈ [2, 21845]
```

### N-R Concrete check — z = 1000 (k = 9, m = 250):

| Step | Value |
|---|---|
| x0 = ⌊32768/250⌋ | 131 |
| P = 250 × 131 | 32750 |
| δ = 32768 − 32750 | 18 |
| x0 × δ = 131 × 18 | 2358 |
| corr = 2358 >> 7 | 18 |
| x1 = 131 × 256 + 18 | 33554 |
| Q = 33554 >> 9 | **65** ✓ (65536/1000 = 65.536) |

### Precision Note

The error analysis presented here is a sketch, not a proof. Two sources of
error interact:

1. The `>> 7` truncation on `corr` contributes up to 1 additional unit of error
   in x1, bringing the total error before the final shift to < 3 (not < 2 as a
   naive reading might suggest).

2. m is itself a truncated approximation of z·2^(7−k), and the interaction
   between this truncation and the N-R step is not fully accounted for in the
   sketch.

For k ≥ 2 the final shift reduces the error below 1, giving the correct floor.
k = 1 (z = 3 in our range) works out numerically but is not covered by the
general argument.

**The right approach is exhaustive verification** across all 32765 values in
[3, 32767] — this runs in milliseconds on any modern machine. If any values
fail, add a one-instruction fixup before returning:

```
if (Q * z > 65536) Q--;
```

This restores exactness at negligible runtime cost.

---

## Algorithm 2: Linear Interpolation (one multiply)

Rather than refining an 8-bit estimate via N-R, this approach stores 16-bit
table values at 128 points and linearly interpolates between adjacent pairs
using the lower 8 bits of Z.

### Table

Store **129 entries** (the extra entry is needed to compute the last delta):

```
T[i] = round(2²² / (128 + i))    for i ∈ [0, 128]
```

The scaling 2²² is chosen so that the difference between adjacent entries:

```
Δ[i] = T[i] − T[i+1] ≈ 2²² / ((128+i)(129+i))
```

ranges from **254 down to 64** — always fits in a byte. This is what keeps the
interpolation multiply within u8×u8.

Table storage: 129 × 16-bit = **258 bytes**.

### The Interpolation Step

Split the normalised Z into index and fraction:

```
i = (Z >> 8) − 128      // 7-bit index ∈ [0, 127]
f =  Z & 0xFF           // 8-bit interpolation fraction
```

**One multiply:**
```
Δ    = T[i] − T[i+1]    // 16-bit subtract, result fits in 8 bits ✓
corr = (f × Δ) >> 8     // u8×u8→16 ✓, take high byte
x1   = T[i] − corr      // 16-bit result ≈ 2²²/m
```

**Final rescale:**
```
Q = x1 >> (k − 1)       // k ∈ [1, 14]; result ∈ [2, 21845]
```

### Why the scaling works

T[i] ≈ 2²²/(128+i) = 2²²/m, and Z = m·256 + f, so:

```
x1 ≈ 2²² / (m + f/256) = 2³⁰ / Z
```

Since Z = z · 2^(15−k):

```
Q = 2³⁰/Z · 2^(1−k) = 65536/z  ✓
```

### Linear Interpolation Concrete check — z = 20000 (k = 14, Z = 40000):

| Step | Value |
|---|---|
| i = (40000 >> 8) − 128 | 28 |
| f = 40000 & 0xFF | 64 |
| T[28] = round(2²²/156) | 26887 |
| T[29] = round(2²²/157) | 26717 |
| Δ = 26887 − 26717 | 170 |
| f × Δ = 64 × 170 | 10880 |
| corr = 10880 >> 8 | 42 |
| x1 = 26887 − 42 | 26845 |
| Q = 26845 >> 13 | **3** ✓ (65536/20000 = 3.276) |

### Precision Note

The interpolation error from the curvature of 1/z contributes at most ~0.5
units to x1, and the table rounding adds another ~0.5, so the total error
before the final shift should remain below 1. However, this is a heuristic
argument — the same caveat applies as for N-R: **exhaustive verification across
[3, 32767] is strongly recommended**, and the same fixup applies if needed:

```
if (Q * z > 65536) Q--;
```

---

## Comparison

| | N-R | Interpolation |
|---|---|---|
| Table | 256 × 8-bit = 256 bytes | 129 × 16-bit = 258 bytes |
| Multiplies | **2** × u8×u8→16 | **1** × u8×u8→16 |
| Other ops | shifts, 16-bit subtract | 16-bit subtract, shift |
| Theoretical error headroom | ~2 bits | ~1 bit (tighter) |
| Fixup needed? | verify exhaustively | verify exhaustively |

The interpolation approach saves one multiply at the cost of a tighter accuracy
margin. Both should be verified exhaustively rather than relied on from analysis
alone.

---

## Experimental Results

Both algorithms were exhaustively verified across all 32765 inputs in [3, 32767]
using `test_math.py`, which reads the assembled lookup tables from the binary and
simulates the exact 6502 instruction sequence (quarter-square multiply, same
carry/borrow behaviour).

| | N-R | Interpolation |
|---|---|---|
| Exact results | 32111 (98.0%) | **32755 (99.97%)** |
| Off-by-one (+1) | 654 (2.0%) | **10 (0.03%)** |
| Off-by-one (−1) | 0 | 0 |
| Errors > ±1 | 0 | 0 |
| Max error | +1 | +1 |

**N-R failures** (654 values): all have k ≥ 8, where the 8-bit mantissa
truncates lower bits of z. The N-R step refines 1/m accurately, but m itself
is an approximation of z·2^(7−k), so the result is for a slightly smaller
divisor.

**Interpolation failures** (10 values): z = 331, 662, 993, 1986, 2979, 3641,
5958, 7282, 10923, 21846. These arise from the same mantissa-truncation
mechanism, but the interpolation's use of 16-bit table entries captures more
information about z, reducing the error rate by ~65×.

Both algorithms' errors are correctable via `if (Q * z > 65535) Q--`.

---

## Range Restriction Benefits

Restricting to z ∈ [3, 32767] (both input and output 15-bit) provides several
concrete advantages over the full 16-bit range:

- **No degenerate results**: z=1 → 65536 (17-bit) and z=2 → 32768 (16-bit) are
  both excluded; all results fit cleanly in 15 bits.
- **Symmetric representation**: input and output live in the same 15-bit unsigned
  space, convenient if results feed back as indices or alongside other 15-bit values.
- **Smaller CLZ table**: bit 7 of the high byte is always clear for z ≤ 32767,
  so the high-byte CLZ lookup only needs 128 entries rather than 256.
- **k is strictly bounded**: k ∈ [1, 14] eliminates the k=0 and k=15 edge cases
  from the final shift.
