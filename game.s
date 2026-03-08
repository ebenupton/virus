; game.s — Real-time perspective grid with camera translation for BBC Micro
; Assembled with ca65: ca65 --cpu 65C02 game.s -o game.o
; Linked with ld65:    ld65 -C linker.cfg game.o -o game.bin
;
; Loads and runs at $0800. Double-buffered at $3000/$5800 (10K each).
; MODE 2-like video: 128×160, 4bpp, 512-byte stripes.
; XOR rendering for flicker-free erase/redraw.
;
; Parameterisable grid centred on camera tile, projected in real time each frame.
; Height modulation from 32×32 toroidal heightmap (5-bit height, 3-bit colour).

.setcpu "65C02"
.segment "CODE"

; === MOS entry points (RTS stubs in emulator) ===
OSWRCH      = $FFEE
OSBYTE      = $FFF4

; === Hardware registers ===
CRTC_REG    = $FE00
CRTC_DAT    = $FE01
SYS_VIA_IFR = $FE4D
SYS_VIA_DDRA = $FE43
SYS_VIA_ORA  = $FE4F

; === Include ZP API files ===
.include "raster_zp.inc"
.include "math_zp.inc"
.include "grid_zp.inc"
.include "object_zp.inc"

; === Zero page: video (forward-declared for ZP addressing) ===
back_buf_idx    = $10

; === Zero page: camera state ($20-$23) ===
cam_x_lo        = $20       ; 8.8 fixed-point X position (low byte)
cam_x_hi        = $21       ; 8.8 fixed-point X position (high byte)
cam_z_lo        = $22       ; 8.8 fixed-point Z position (low byte)
cam_z_hi        = $23       ; 8.8 fixed-point Z position (high byte)

; === Constants ===
SCREEN_W    = 128            ; pixels wide (4bpp, 2 pixels per byte)
SCREEN_H    = 160            ; pixels tall (20 character rows)

; BBC Micro key scan codes
KEY_Z       = $61
KEY_X       = $42
KEY_RETURN  = $49
KEY_SPACE   = $62

; Camera constants
CAM_SPEED       = $08        ; ~0.03 units/frame in 8.8
CAM_HEIGHT_LO   = $80        ; camera height 1.5 in 8.8 = $0180
CAM_HEIGHT_HI   = $01

; =====================================================================
; Entry point ($0800)
; =====================================================================

entry:
    SEI
    JSR init_screen
    JSR init_status

    ; Initialize rotation angle
    STZ obj_rot_angle

    ; Initialize camera: x=0, z=-2.25 (8.8 fixed-point)
    STZ cam_x_lo
    STZ cam_x_hi
    LDA #$C0
    STA cam_z_lo
    LDA #$FD
    STA cam_z_hi

; =====================================================================
; Main loop
; =====================================================================

main_loop:
    STA $FE32               ; dump & reset call-stack profile
    JSR update_camera
    JSR clear_screen
    JSR draw_grid

    ; Advance object rotation angle
    LDA obj_rot_angle
    CLC
    ADC #4
    STA obj_rot_angle

    ; Set up object pointer
    LDA #<obj_pyramid
    STA obj_ptr
    LDA #>obj_pyramid
    STA obj_ptr+1

    ; Compute view-space centre for object
    LDA obj_world_x_lo
    SEC
    SBC cam_x_lo
    STA obj_view_x
    LDA obj_world_x_hi
    SBC cam_x_hi
    STA obj_view_x+1

    LDA #CAM_HEIGHT_LO
    SEC
    SBC obj_world_y_lo
    STA obj_view_y
    LDA #CAM_HEIGHT_HI
    SBC obj_world_y_hi
    STA obj_view_y+1

    ; Default bbox: nothing drawn by object (overwritten if draw_object runs)
    LDA #160
    STA obj_bb_min_sy

    LDA obj_world_z_lo
    SEC
    SBC cam_z_lo
    STA obj_view_z
    LDA obj_world_z_hi
    SBC cam_z_hi
    STA obj_view_z+1
    BMI @skip_obj
    ORA obj_view_z
    BEQ @skip_obj

    JSR draw_object

@skip_obj:
    ; Combine grid + object dirty tops → save for this buffer's next clear
    LDA grid_min_sy
    CMP obj_bb_min_sy
    BCC @use_grid
    LDA obj_bb_min_sy
@use_grid:
    LDX back_buf_idx
    STA dirty_top_buf0,X

    JSR draw_map
    JSR draw_status
    JSR wait_vsync
    JSR flip_buffers
    JMP main_loop

; =====================================================================
; Update camera — VIA key scanning, direct X/Z translation
; =====================================================================

update_camera:
    LDA #$7F
    STA SYS_VIA_DDRA        ; bits 0-6 output, bit 7 input

    ; Z key → move left (cam_x -= SPEED)
    LDA #KEY_Z
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_left
    LDA cam_x_lo
    SEC
    SBC #CAM_SPEED
    STA cam_x_lo
    LDA cam_x_hi
    SBC #0
    STA cam_x_hi
@no_left:

    ; X key → move right (cam_x += SPEED)
    LDA #KEY_X
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_right
    LDA cam_x_lo
    CLC
    ADC #CAM_SPEED
    STA cam_x_lo
    LDA cam_x_hi
    ADC #0
    STA cam_x_hi
@no_right:

    ; Return → move forward (cam_z += SPEED)
    LDA #KEY_RETURN
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_forward
    LDA cam_z_lo
    CLC
    ADC #CAM_SPEED
    STA cam_z_lo
    LDA cam_z_hi
    ADC #0
    STA cam_z_hi
@no_forward:

    ; Space → move backward (cam_z -= SPEED)
    LDA #KEY_SPACE
    STA SYS_VIA_ORA
    LDA SYS_VIA_ORA
    BMI @no_back
    LDA cam_z_lo
    SEC
    SBC #CAM_SPEED
    STA cam_z_lo
    LDA cam_z_hi
    SBC #0
    STA cam_z_hi
@no_back:
    RTS

; =====================================================================
; Included modules
; =====================================================================

.include "video.s"
.include "raster.s"
.include "math.s"
.include "grid.s"
.include "object.s"
.include "clip.s"
.include "map.s"
.include "status.s"
.include "tables.inc"
.include "map_data.inc"
.include "status_data.inc"
.include "interp_data.inc"
