; map.s — Minimap blitter for BBC Micro
;
; Provides: draw_map
; Requires: raster_zp.inc (for raster_page)
;
; Blits 16×32 pixel minimap to screen starting at character row 2, offset 16.
; Data: 4 stripes of 64 bytes in character-cell order (col×8+scanline).
; Two hardcoded versions for double-buffered rendering.

.include "raster_zp.inc"

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
