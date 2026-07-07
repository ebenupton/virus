; map.s — Minimap blitter for BBC Micro
;
; Provides: draw_map
; Requires: raster_zp.inc (for raster_page)
;
; Blits 16×32 pixel minimap to screen starting at character row 2, offset 16.
; Data: 4 stripes of 64 bytes in character-cell order (col×8+scanline).
; Two hardcoded versions for double-buffered rendering.

.include "raster_zp.inc"

; =====================================================================
; draw_map — Blit the pre-rendered minimap into the back buffer
; =====================================================================
; Input:  raster_page = back buffer page ($30 → buf0 at $3000,
;         $58 → buf1 at $5800); minimap_data = 256 bytes (external,
;         generated into map_data.inc)
; Output: 256 bytes copied to 4 consecutive character rows
; Clobbers: A, X
;
; Screen layout: 512-byte character rows (64 cells × 8 bytes, MODE 2
; = 2 pixels/byte).  Each 64-byte stripe fills 8 cells × 8 scanlines
; = 16×8 pixels; the four stripes land at row starts +$400, +$600,
; +$800, +$A00 (char rows 2-5), each at byte offset $10 (cell 2).
; Straight-line copy, unrolled 4× with absolute addresses per buffer —
; no pointer arithmetic in the loop.
;
; Pseudocode:
;   base = $3000 if buf0 else $5800
;   for s in range(4):                        # stripe = one char row
;       dst = base + (2+s)*$200 + $10
;       dst[0:64] = minimap_data[s*64 : s*64+64]

draw_map:
    LDA raster_page
    CMP #$58
    BEQ @buf1

@buf0:
    LDX #63
@loop0:
    LDA minimap_data+0,X
    STA $3410,X
    LDA minimap_data+64,X
    STA $3610,X
    LDA minimap_data+128,X
    STA $3810,X
    LDA minimap_data+192,X
    STA $3A10,X
    DEX
    BPL @loop0
    RTS

@buf1:
    LDX #63
@loop1:
    LDA minimap_data+0,X
    STA $5C10,X
    LDA minimap_data+64,X
    STA $5E10,X
    LDA minimap_data+128,X
    STA $6010,X
    LDA minimap_data+192,X
    STA $6210,X
    DEX
    BPL @loop1
    RTS
