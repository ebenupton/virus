; status.s — Status bar: logo + fuel bar + BCD score display
;
; Provides: init_status, draw_status
; Requires: raster_zp.inc (for raster_page)
;
; Char row 0 is preserved across frames (clear_screen skips it).
; init_status: clears row 0 of both buffers, blits logo to both.
; draw_status: redraws score only when changed, updates fuel bar by ±1 pixel.
; All operations are double-buffer aware.

.include "zp_layout.inc"

; === Zero page (ZP_STATUS internal) ===
status_ptr = ZP_STATUS + 0    ; 2 bytes — screen destination pointer
status_src = ZP_STATUS + 2    ; 2 bytes — font data source pointer

; === Constants ===
FUEL_MAX = 64                ; max fuel level (32 byte columns × 2 pixels)

; === Data ===
score:       .byte $12, $34, $87, $65   ; 4-byte BCD = 12348765
fuel_target: .byte FUEL_MAX             ; target fuel level (0..64)
fuel_cur_0:  .byte 0                    ; current drawn level, buffer 0
fuel_cur_1:  .byte 0                    ; current drawn level, buffer 1
; Last-rendered score per buffer (init $FF to force first draw)
score_drawn: .byte $FF, $FF, $FF, $FF   ; buffer 0
             .byte $FF, $FF, $FF, $FF   ; buffer 1

; =====================================================================
; init_status — Clear char row 0 and blit logo to both buffers
; =====================================================================
; Call once at startup, after init_screen.

init_status:
    ; Clear char row 0 of both buffers (512 bytes each)
    LDX #0
    LDA #0
@clear_row0:
    STA $3000,X
    STA $3100,X
    STA $5800,X
    STA $5900,X
    INX
    BNE @clear_row0

    ; Blit logo to both buffers
    LDX #103
@logo_both:
    LDA logo_data,X
    STA $3008,X
    STA $5808,X
    DEX
    BPL @logo_both
    RTS

; =====================================================================
; draw_status — Conditionally redraw score, update fuel bar
; =====================================================================

draw_status:
    ; --- Check if score needs redrawing for current buffer ---
    LDX #0                    ; buffer 0 offset into score_drawn
    LDA raster_page
    CMP #$58
    BNE @sc_check
    LDX #4                    ; buffer 1 offset
@sc_check:
    LDA score
    CMP score_drawn,X
    BNE @redraw_score
    LDA score+1
    CMP score_drawn+1,X
    BNE @redraw_score
    LDA score+2
    CMP score_drawn+2,X
    BNE @redraw_score
    LDA score+3
    CMP score_drawn+3,X
    BEQ @score_ok

@redraw_score:
    ; Copy score to score_drawn for this buffer
    LDA score
    STA score_drawn,X
    LDA score+1
    STA score_drawn+1,X
    LDA score+2
    STA score_drawn+2,X
    LDA score+3
    STA score_drawn+3,X

    ; Set up score screen base (X=0:buf0, X=4:buf1 from above)
    TXA
    BNE @score_buf1
    LDA #<$3178
    STA status_ptr
    LDA #>$3178
    STA status_ptr+1
    JMP @render_digits
@score_buf1:
    LDA #<$5978
    STA status_ptr
    LDA #>$5978
    STA status_ptr+1

@render_digits:
    LDX #0
@score_loop:
    LDA score,X
    PHA                 ; save byte for low nibble
    ; High nibble
    LSR
    LSR
    LSR
    LSR
    STX nmos_tmp
    JSR render_digit
    LDX nmos_tmp
    ; Low nibble
    PLA
    AND #$0F
    STX nmos_tmp
    JSR render_digit
    LDX nmos_tmp
    INX
    CPX #4
    BNE @score_loop

@score_ok:
    JMP update_fuel           ; tail call — update fuel bar

; render_digit — Render a single digit at status_ptr, advance by 16
;   A = digit value (0-9)
render_digit:
    ; Compute status_src = font_data + A * 16
    ASL             ; ×2
    ASL             ; ×4
    ASL             ; ×8
    ASL             ; ×16 (max 144, C=0 since digit≤9)
    ADC #<font_data
    STA status_src
    LDA #>font_data
    ADC #0
    STA status_src+1
    ; Copy 16 bytes
    LDY #15
@copy:
    LDA (status_src),Y
    STA (status_ptr),Y
    DEY
    BPL @copy
    ; Advance status_ptr by 16
    LDA status_ptr
    CLC
    ADC #16
    STA status_ptr
    BCC @no_carry
    INC status_ptr+1
@no_carry:
    RTS

; =====================================================================
; update_fuel — Incremental fuel bar update (±1 pixel per frame)
; =====================================================================
; Bar: byte columns 15-46 (64 pixels), scanlines 3-5 within char row 0.
; Draws or erases the edge pixel only; relies on row 0 persistence.
;
; Grow pixel P: $08 (left green) if P even, $0C (both green) if P odd
; Shrink pixel P: $00 (both black) if P even, $08 (left green) if P odd

update_fuel:
    ; Set up bar base pointer: scanline 3 of byte column 15
    LDA #$7B                  ; lo byte: 15*8 + 3 = $7B
    STA status_ptr
    LDA raster_page
    STA status_ptr+1          ; hi byte: $30 or $58

    ; Select buffer index: X = 0 (buf 0) or 1 (buf 1)
    LDX #0
    CMP #$58
    BNE @uf_adj
    INX
@uf_adj:
    LDA fuel_cur_0,X
    CMP fuel_target
    BEQ @uf_done              ; at target → nothing to do
    BCC @uf_grow

    ; --- Shrink: erase pixel at position (cur-1), decrement cur ---
    SEC
    SBC #1
    STA fuel_cur_0,X
    TAY                       ; Y = pixel position
    AND #1
    BNE @shrink_odd
    LDA #$00                  ; even: erase both pixels in column
    BEQ @uf_write             ; always (A=0)
@shrink_odd:
    LDA #$08                  ; odd: keep left green, erase right
    BNE @uf_write             ; always (A=$08)

@uf_grow:
    ; --- Grow: draw green at position cur, increment cur ---
    TAY                       ; Y = pixel position (old cur)
    CLC
    ADC #1
    STA fuel_cur_0,X          ; store incremented level
    TYA
    AND #1
    BNE @grow_odd
    LDA #$08                  ; even: left pixel green
    BNE @uf_write             ; always (A=$08)
@grow_odd:
    LDA #$0C                  ; odd: both pixels green

@uf_write:
    ; A = byte value to write, Y = pixel position
    STA status_src            ; save byte value
    TYA
    AND #$FE
    ASL A
    ASL A                     ; byte column offset = (P & $FE) * 4
    TAY
    LDA status_src            ; recover byte value
    STA (status_ptr),Y        ; scanline 3
    INY
    STA (status_ptr),Y        ; scanline 4
    INY
    STA (status_ptr),Y        ; scanline 5

@uf_done:
    RTS
