; edge_color.inc — Edge colour LUTs for grid rendering
;
; Three 8-entry tables, indexed by color bits 0-2 of heightmap cell.
; Table selected by vertex height: 0 = sea, 31 = plateau, other = land.
;
;           pattern: 000  001  010  011  100  101  110  111
h_color_sea:
    .byte          $14, $05, $10, $04, $14, $14, $10, $05
v_color_sea:                                                   ; Cy   Y    B    G    Cy   Cy   B    Y   
    .byte          $14, $14, $14, $14, $10, $05, $10, $05         ; Cy   Cy   Cy   Cy   B    Y    B    Y   

h_color_plat:
    .byte          $05, $15, $04, $00, $15, $15, $04, $00
v_color_plat:                                                  ; Y    W    G    Bk   W    W    G    Bk  
    .byte          $05, $15, $15, $15, $04, $00, $04, $00         ; Y    W    W    W    G    Bk   G    Bk  

h_color_land:
    .byte          $05, $14, $04, $10, $05, $05, $04, $04
v_color_land:                                                  ; Y    Cy   G    B    Y    Y    G    G   
    .byte          $05, $04, $05, $04, $04, $04, $04, $04         ; Y    G    Y    G    G    G    G    G   

