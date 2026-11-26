; =====================================================================
; PASOPIA (PA7010) boot sector - loads the patched ROM image AND
; disk_basic.bin from floppy into RAM, then starts the patched BASIC
; ---------------------------------------------------------------------
; How the stock ROM boots from floppy (verified by disassembling
; tbasic.rom):
;   Reset -> 01F0h init -> 02C6h CALL 16A5h (FDD boot loader) ->
;   02C9h CALL 161Bh -> JP 7E2Bh (BASIC cold start).
;   16A5h tries drives 0..3 ((CFFFh) = 00h..03h, head 0):
;   SPECIFY (03h,3Fh,03h), motor on (FDC_CONTROL=E6h <- 40h),
;   RECALIBRATE (07h), SEEK track 1 (0Fh, NCN=01h), then
;   READ DATA (46h, US/HD=(CFFFh), C=01h, H=00h, R=01h, N=01h,
;   EOT=10h, GPL=0Eh, DTL=FFh) - one 256-byte sector -> D000h.
;   It then requires (D000h) = F3h (DI) and JP (HL) -> D000h.
;   On failure it retries the next drive (max 4), then RETs and
;   BASIC starts normally.
;
; RAM/ROM banking (per the MAME pasopia driver,
; pasopia_ctrl_w/memory_r, and the Toshiba T100 (=PA7010)
; maintenance manual: main RAM is a full 64KB):
;   - Writes to memory ALWAYS go to the 64KB RAM, even while the
;     ROM is mapped for reads.
;   - Reads at 0000h-7FFFh return ROM while the bank register is 0,
;     and RAM after writing a value with bit1 set to port 3Ch.
;   - Port 3Ch is write-only for this purpose; the stock ROM never
;     writes it (no D3 3C anywhere in tbasic.rom). The state can be
;     read back on PPI2 port C bit2 (IN A,(22h)).
;   (Port 23h is NOT banking: ports 20h-23h are an 8255 PPI whose
;    port C drives RS-232 DTR/RTS/TXD.)
; So this loader can simply READ the patched ROM image into
; 0000h-7FFFh (writes pass through to RAM under the ROM), flip the
; bank, verify a signature, and jump into the RAM copy.
;
; Load sequence (payload read order: track ascending, side 0
; sectors 1..16, then side 1 sectors 1..16, starting at T1/S0/S2
; right after this boot sector):
;   128 sectors tbasic_patched.rom -> 0000h-7FFFh (RAM under ROM)
;     5 sectors disk_basic.bin     -> 8000h-84FFh (continues the
;                                   same sector stepping)
; Then: verify (8000h) = D5h (fd_xfer entry), OUT (3Ch),02h to map
; RAM for reads, verify (17B2h) = C3h (the patch JP fd_xfer -
; the stock ROM has D5h there), JP 02C9h which now executes the
; RAM copy: CALL 161Bh -> JP 7E2Bh (patched cold start; device
; selection at 3954h finds the driver already resident).
; Failure handling (same fail-soft philosophy as the ROM loader):
;   - any FDC error or a bad driver byte -> JP 02C9h with the ROM
;         still mapped: stock BASIC starts, no driver.
;   - bad image signature after the flip -> flip back to ROM
;         (OUT (3Ch),00h) and JP 02C9h: stock BASIC starts.
;   - a SEEK error lands in the ROM's own sense tail (1746h),
;         whose error path retries the whole boot on the next
;         drive, exactly like the stock loader.
;
; It reuses the ROM's own FDC primitives (not touched by the
; patch set): 1775h send a byte to the FDC, 1785h read a result
; byte, 175Dh SENSE INTERRUPT drain, 176Fh send byte + drive
; byte (for SEEK), 1746h SENSE INTERRUPT completion tail - all
; using (CFFFh) as the drive byte, so everything is loaded from
; whichever drive the boot sector itself came from.
; The FDC is NOT re-initialized here: the ROM loader has
; already sent SPECIFY, turned the motor on and left the head
; on track 1 after reading this very sector. A CP/M IPL for
; this machine boots the same way - no SPECIFY, no
; RECALIBRATE, no control-port writes. Re-doing them only
; adds failure modes on a real drive.
; TC discipline: every other reader in this ecosystem
; deasserts TC before a READ - the ROM loader writes TC_OFF
; (E0h) at 16D5h before its READ and leaves TC latched ON
; after it, the CP/M IPL pulses TC_OFF at the start of every
; read, and diskio pulses TC_ON/TC_OFF around each transfer.
; So TC_OFF is written at issue here too: every payload READ
; must start with TC deasserted, not still latched from the
; previous transfer, or it can fail on a real drive.
; Per-sector SEEK + SENSE: every sector READ is preceded by
; a SEEK to the current track (seek_d, whose 1746h tail
; senses completion) and a SENSE INTERRUPT drain (175Dh) -
; the same discipline as the CP/M IPL's read loop (sense,
; seek, confirm, then read). Reading sectors back-to-back
; with no seek between them works on emulators but not on
; a real drive; the per-sector seek/confirm is required.
; (The exact FDC-level mechanism behind this has not been
; isolated beyond that.)
; Sector READs are retried: on a real drive a spun-up drive
; still returns Not Ready and other transient errors. A
; failed sector is re-read up to RETRY_MAX times, with a
; re-seek to the current track and a ~60ms pause before
; each attempt; only then does the loader fail soft.
;
; REGISTER CAUTION:
; 1775h starts with LD B,A - it uses B as its byte temporary,
; and 176Fh/1746h inherit that.
; So B must never hold loop state across a primitive call:
; if the sector count lived in B, every READ DATA issue
; would reset it to FFh via the DTL byte, DJNZ would
; oscillate FFh/FEh and the load would run away past the
; payload. The sector counter therefore lives in memory
; (sec_cnt). C (sector),
; D (track), E (side) and HL (dest) are safe: no primitive
; called inside the loop touches them.
;
; Layout on the boot disk (make_boot_disk.py):
;   T1/S0/S1   this sector (256 bytes, ORG D000h)
;   payload    133 sectors in the read order above:
;              tbasic_patched.rom (32768 bytes) then
;              disk_basic.bin (1121 bytes, zero-padded to 5 sectors)
;   Clusters 4..20 (every cluster the payload touches) are marked
;   FEh (reserved) in all three FAT copies so the file core never
;   allocates them. No directory entry is used; the sectors are
;   raw, outside the file system.
;
; Build: pasmo bootsec.asm bootsec.bin
;   (must be <= 256 bytes, first byte F3h)
; =====================================================================

ORG	0D000h

BOOT_DRV	EQU    0CFFFh		; ROM boot loader drive byte (00h..03h)
FDC_STAT	EQU    0E4h
FDC_DATA	EQU    0E5h
TC_ON	EQU    0E2h
TC_OFF	EQU    0E0h
BANK_PORT	EQU   03Ch		; bit1: 1 = RAM mapped at 0000h-7FFFh
RES_BUF	EQU    0FE8Dh			; ROM loader result buffer (7 bytes)
IMG_SECTORS	EQU 128			; 32KB patched ROM image
RETRY_MAX	EQU 8			; セクタ読みのリトライ回数
DRV_SECTORS	EQU 5			; disk_basic.bin (5 セクタにパディング)

	DI				; F3h - required first byte (ROM checks this)
	LD	SP,0E000h		; reset-time stack value

; --- FDC は ROM ローダ (16A5h) が初期化済み ---
; SPECIFY 済み、モーター ON、ヘッドはトラック 1 (このセクタを
; 読んだ位置)。SPECIFY / RECALIBRATE / 制御ポート書込みは
; やり直さない。残っている完了状態だけ掃除する。
	CALL	175Dh			; SENSE INTERRUPT (clear pending)

; --- payload load loop ---
; state: HL = dest, (sec_cnt) = sectors left, C = sector (1..16),
;        D = track, E = head bits for US/HD (00h side0 / 04h side1)
	LD	HL,0000h		; image dest (RAM under the ROM)
	LD	A,IMG_SECTORS+DRV_SECTORS
	LD	(sec_cnt),A
	LD	C,02h			; first payload sector = T1/S0/S2
	LD	D,01h			; track 1
	LD	E,00h			; side 0
sec_loop:
	LD	(dst),HL		; このセクタの転送先 (リトライで戻す)
	LD	A,RETRY_MAX
	LD	(retry_cnt),A
sec_try:
	LD	HL,(dst)
        ; dest runs 0000h -> 84FFh contiguously: the ROM image
        ; (0000h-7FFFh) is followed directly by the driver at
        ; 8000h, so no dest redirect is needed at the seam.
issue:
	CALL	seek_d			; 現在トラックへ毎回 SEEK (実ドライブで必要)
	CALL	175Dh			; SENSE INTERRUPT (排出)
	OUT	(TC_OFF),A		; TC を落とす (下記)
	LD	A,46h			; READ DATA
	CALL	1775h
	LD	A,(BOOT_DRV)		; US/HD = drive + head bit
	OR	E
	CALL	1775h
	LD	A,D			; C = track
	CALL	1775h
	LD	A,E			; H = side (E is 00h or 04h)
	RRCA
	RRCA
	CALL	1775h
	LD	A,C			; R = sector
	CALL	1775h
	LD	A,01h			; N = 1 (256 bytes/sector)
	CALL	1775h
	LD	A,10h			; EOT = 16
	CALL	1775h
	LD	A,0Eh			; GPL = 14
	CALL	1775h
	LD	A,0FFh			; DTL = FFh
	CALL	1775h
; data phase: INI 256 bytes from FDC_DATA (E5h) to (HL)
; (copy of ROM 1701h-1712h; BC is saved - INI consumes it)
	PUSH	BC
	LD	BC,00E5h
rd_loop:
	IN	A,(FDC_STAT)
	RLCA				; RQM -> carry
	JR	NC,rd_loop
	AND	40h			; DIO: 0 = read phase finished
	JR	Z,rd_tc
	INI
	JR	NZ,rd_loop
rd_tc:
	OUT	(TC_ON),A		; TC strobe
	POP	BC
; result phase: 7 bytes -> RES_BUF, ST0 error bits must be 0
	PUSH	HL			; HL = next dest (dest+256)
	PUSH	BC
	LD	HL,RES_BUF
	LD	B,07h
res_loop:
	CALL	1785h
	LD	(HL),A
	INC	HL
	DJNZ	res_loop
	POP	BC
	POP	HL
	LD	A,(RES_BUF)
	AND	0C0h
	JR	Z,sec_ok
; エラー: 実ドライブでは過渡エラーが普通に来るので、少し待って
; 同じトラックへ再シークしてから同じセクタを読み直す。
	LD	A,(retry_cnt)
	DEC	A
	JP	Z,boot_fail		; 回数を使い切ったらフェイルソフト
	LD	(retry_cnt),A
	CALL	rd_delay		; ~60ms 待つ
	CALL	seek_d			; 同じトラック D へ再シーク
	JR	sec_try
sec_ok:
; advance (track, side, sector)
	INC	C
	LD	A,C
	CP	17
	JR	NZ,stepped
	LD	C,01h
	LD	A,E
	XOR	04h			; flip side
	LD	E,A
	JR	NZ,stepped		; side 1 now: same track, no seek
	INC	D			; wrapped to side 0: next track
	CALL	seek_d			; SEEK track D
stepped:
	LD	A,(sec_cnt)		; NOT DJNZ: B is clobbered by 1775h
	DEC	A
	LD	(sec_cnt),A
	JP	NZ,sec_loop		; ループが伸びて JR の範囲を超えた

; --- verify driver, flip the bank, verify image, start ---
	LD	A,(08000h)
	CP	0D5h			; fd_xfer starts PUSH DE
	JR	NZ,boot_fail
	LD	A,02h			; map RAM at 0000h-7FFFh for reads
	OUT	(BANK_PORT),A
	LD	A,(17B2h)
	CP	0C3h			; patched image: JP fd_xfer (stock: D5h)
	JR	NZ,unflip
	JP	02C9h			; RAM copy: CALL 161Bh -> JP 7E2Bh

unflip:
	XOR	A			; back to ROM
	OUT	(BANK_PORT),A
boot_fail:
	JP	02C9h			; stock BASIC (fail-soft)

; --- SEEK to track D (ROM 1732h pattern with a variable track) ---
seek_d:
	LD	A,0Fh			; SEEK
	CALL	176Fh			; sends command + drive byte
	LD	A,D
	CALL	1775h			; NCN = track
	JP	1746h			; ROM sense-completion tail (RETs)

; --- リトライ前の小休止 (10000 x 26T = 約 60ms, 4MHz 換算) ---
rd_delay:
	PUSH	HL
	LD	HL,10000
rd_dly1:
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,rd_dly1
	POP	HL
	RET

sec_cnt:
	DB	0			; payload sectors left (see caution)
dst:
	DW	0			; current sector dest (retry resets HL)
retry_cnt:
	DB	0			; retries left for this sector

END
