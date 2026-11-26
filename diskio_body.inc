; -------------------
;
; Disk I/O
;
; -------------------

STATUS_RQM EQU 80h
STATUS_DIO EQU 40h
STATUS_NDM EQU 20h
STATUS_CB EQU 10h

MOTOR_ON  EQU 40h
MOTOR_OFF_REQ  EQU 01h
MOTOR_OFF EQU 00h

MOTOR_OFF_COUNT EQU  110    ;; 0.26 * 110 = 28.6 sec

MFM       EQU 40h

FDD_RW_READ  EQU 1
FDD_RW_WRITE EQU 0

; -------------------
;  Set FDD R/W param
;
; D  : Track#
; E  : Sector#
; B  : Number of R/W sectors
; A  : side 0 0 0 0 0 Drive Drive
; -------------------
fdd_setparam:
	ld ix, fdc_param
	; Parameter D (cylinder)
	ld (ix+2), d
	; Parameter E (Sector)
	ld (ix+4), e
	; Others
	ld (ix+5), 1   ; N=1:256 bytes/sector
	; Parameter A
	and 83h ;; mask side & drive
	ld d, a
	rlca
	and 01h
	ld (ix+3), a   ; Header
	rlca
	rlca
	or d
	and 07h
	ld (us_hd), a   ; R/W command US/HD (HD bit included)
	and 03h
	ld (ix+1), a   ; SEEK/SENSE/RECAL see drive only (no HD bit)
	; Parameter B
	ld (ix+9), b   ; Number of sectors
	ld (ix+6), 10h ; EOT = 16 (same as boot code; TC-terminated)
	ld (ix+7), 0eh   ; GSL
	ld (ix+8), 0ffh   ; DTL
	ret

; -------------------
;  FDD Read/Write 
;
; HL : Read/Write data area
;  a : 0 : write, 1: read
; -------------------
fdd_rw:
	push hl
	; preserve command code
	ld (fdc_param + 10), a
	; Prepare for R/W
	di
	ld a, (MOTOR_STATE)
	ld h, a
	ld a, MOTOR_ON
	ld (MOTOR_STATE), a
	out (FDC_CONTROL), a
	ei
	ld a, h
	cp MOTOR_OFF
	jr nz, fdd_rw1
	;; Motor ON & wait for spin-up
	ld a, (INTCOUNT)
	add a, 100   ;; about 1.6sec
	ld h, a
fdd_rw_spinup:
	ld a, (INTCOUNT)
	cp h
	jr nz, fdd_rw_spinup
fdd_rw1:
	;; Wait for device ready
	ld a, (INTCOUNT16)
	add a, 16   ;; 16 * 0.26 = 4.1sec
	ld h, a
fdd_sensdrv:
	push hl
	call sense_dev_status
	pop hl
	jp c, fdd_err
	ld l, a
	ld a, (INTCOUNT16)
	cp h
	jp z, fdd_err
	ld a, l
	and 20h
	jr z, fdd_sensdrv
	call sense_int_status
	;; ignore errors
	; check same track
	ld hl, cur_track
	ld a, (fdc_param + 1)  ; HD, US1, US0
	and 03h
	ld d, 0
	ld e, a
	add hl, de
	ld a, (fdc_param + 2)  ; Cylinder
	ld d, a
	ld a, (hl)
	ld e, a
	cp 0ffh
	jr nz, fdd_rw2
	;push de
	call recalibrate
	;pop de
	jp c, fdd_other_err
	call wait_seek
	jp c, fdd_other_err
fdd_rw2:
	ld a, d
	cp e
	; not same .. seek
	; - Workaround: (Emulator bug?) 
	;   always seek for checking drive status
	; jr z, fdd_rw3 
	call seek
	jr c, fdd_other_err
	call wait_seek
	jr c, fdd_other_err
	call update_cur_track
fdd_rw3:
	; Set FDC command
	ld a, (fdc_param+10)
	or a
	jr z, fdd_write
	ld a, 06h or MFM
	jr fdd_rw_setcom
fdd_write:
	ld a, 05h or MFM
fdd_rw_setcom:
	ld (fdc_param), a
	ld a, (us_hd)
	ld (fdc_param+1), a
	ld c, 9
	di
	call c_phase
	jr c, fdd_other_err
	; Exec R/W
	pop hl         ; Read/write buffer
	ld a, (fdc_param+9) ; Number of sectors
	ld d, a
	ld e, 0        ; de = number of read (256bytes/sector)
	call e_phase
	call r_phase
	ei
	jp c, other_error
	; Check status
	ld a, (fdc_resp)
	ld c, a
	and 0c0h
	jr z, fdd_set_motor_off   ; normal end
	; Error
	bit 3, c
	jp nz, not_ready_err
	ld a, (fdc_resp+1)
	bit 1, a
	jr nz, wp_err
	jp other_error
wp_err:
	ld a, 8
	scf
	jr fdd_set_motor_off

fdd_err:
	scf
	pop hl
	jr fdd_set_motor_off

fdd_other_err:
	ei
	pop hl
	jp other_error

fdd_set_motor_off:
	push af
	di
	ld a, (INTCOUNT16)
	add a, MOTOR_OFF_COUNT
	ld (MOTOR_OFF_TIME), a
	ld a, MOTOR_OFF_REQ
	ld (MOTOR_STATE), a
	ei
	pop af
	ret


	; -------------------
	; SEEK
	; -------------------
seek:
	ld a, 0Fh
	ld (fdc_param), a
	ld c, 3
	call c_phase
	ret c
	call wait_int
	ret

update_cur_track:
	; Updte current track
	ld hl, cur_track
	ld a, (fdc_param + 1)
	and 03h
	ld d, 0
	ld e, a
	add hl, de
	ld a, (fdc_param + 2)
	ld (hl), a
	ret

wait_seek:
	call sense_int_status
	jr nc, wait_seek1
	cp 1   ;; Not ready
	jr z, wait_seek
	scf
	jp fdd_err
wait_seek1:
	; check seek end
	and 20h
	jr z, wait_seek
	ret

	; -------------------
	; SENSE DEVICE STATUS
	; -------------------
sense_dev_status:
	ld a, 04h
	ld (fdc_param), a
	ld c, 2
	call c_phase
	ret c

	call r_phase
	ret c

	ld a, (fdc_resp)
	ret

	; -------------------
	; SENSE INTERRUPT STATUS
	; -------------------
sense_int_status:
	ld a, 08h
	ld (fdc_param), a
	ld c, 1
	call c_phase
	ret c

	call r_phase
	ret c

	ld a, (fdc_resp)
	ld c, a
	and 0c0h
	jr z, sense_int_normal
	cp 80h
	; Invalid is treated as normal
	jr z, sense_int_normal
	; Not ready
	bit 3, c
	jr nz, not_ready_err
	cp 40h
	jr z, other_error
	; Attention
	; Equipment check
	bit 4, c
	jr nz, other_error
	jr sense_int_normal
other_error:
	ld a, 0ffh
	scf
	jp fdd_set_motor_off

not_ready_err:
	ld a, 01h
	scf
	jp fdd_set_motor_off

sense_int_normal:
	or a		;; clear carry
	ld a, c
	; Normal end
	ret

recalibrate:
	ld a, 07h
	ld (fdc_param), a
	ld c, 2
	call c_phase
	ret c
	call wait_int
	ret

	; -----------------------------
	; C-PHASE
	; C : number of parameter
	; -----------------------------
c_phase:
	; wait cb=0
	in a, (FDC_STATUS)
	cp 0ffh
	jr nz, c_phase1
	; unexpected error
	; FDC reset needed
	scf
	ret
c_phase1:        
	and STATUS_CB
	jr nz, c_phase
	ld hl, fdc_param

	; send parameters
wait_rqm:
	; wait RQM=1, DIO = 0
	in a, (FDC_STATUS)
	and STATUS_RQM or STATUS_DIO
	cp STATUS_RQM
	jr nz, wait_rqm

	; Write parameter
	ld a,(hl)
	out (FDC_DATA), a
	inc hl
	dec c
	jr nz, wait_rqm
	ret

wait_int:
	; wait int = 1 (no timeout)
	in a, (FDC_CONTROL)
	bit 7, a
	jr z, wait_int
	ret

	; -----------------------------
	; E-PHASE
	; HL : pointer to data area
	; DE : number of read/write
	; -----------------------------
e_phase:
	; With wait_int, it greatly hit
	; access performance on emualtor
	;call wait_int
	ld bc, 00e5h
e_phase1:
	; Check RQM=1
	in a, (FDC_STATUS)
	rlca
	jr nc, e_phase1
	; Check DIO
	rlca 
	jr nc, e_phase_write
	; Check NDM
	rlca
	jr nc, e_phase_end
e_phase_read:
	ini
	;jr nz, e_phase1
	dec de
	ld a, e
	or d
	jr nz, e_phase1

e_phase_end:
	; TC ON - OFF
	out (TC_ON), a
	out (TC_OFF), a
	ret

e_phase_write:
	; Check NDM
	rlca
	jr nc, e_phase_end
	outi
	dec de
	ld a, e
	or d
	jr nz, e_phase1
	jr e_phase_end

	; -----------------------------
	; R-PHASE
	; -----------------------------
r_phase:
	; With wait_int, it greatly hit
	; access performance on emulator
	;call wait_int
	ld hl, fdc_resp
r_phase1:
	; wait RQM=1, DIO=1
	in a,(FDC_STATUS)
	cp 0ffh
	jr nz, r_phase2
	; unexpeceted error
	; FDC reset needed
	scf
	ret

r_phase2:
	rlca
	jr nc, r_phase1
	rlca
	ret nc
	in a, (FDC_DATA)
	ld (hl), a
	inc hl
	jr r_phase1


	; -------------------
	; WORK RAM
	; -------------------
; WORK RAM  (ROM版では DSK_WORK への EQU 配置に変更)
;   初期化は dx_winit が行う (cur_track は FFh で初期化)
; -------------------
fdc_param	EQU	DSK_WORK+0	; 11 bytes
fdc_resp	EQU	DSK_WORK+11	; 7 bytes
cur_track	EQU	DSK_WORK+18	; 4 bytes (FFh 初期化は dx_winit)
