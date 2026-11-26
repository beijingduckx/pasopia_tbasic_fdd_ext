; =====================================================================
; PASOPIA (PA7010) T-BASIC フロッピーディスク拡張
; ---------------------------------------------------------------------
; ROM 内蔵の「汎用ファイルコア」
; (Microsoft BASIC 5.0 系のデバイスファイル機構) にフロッピーを
; デバイスとして接続する。命令ハンドラは ROM 純正のままなので、
; SAVE/LOAD/BLOAD/BSAVE はもちろん OPEN/PRINT#/INPUT#/CLOSE/
; FILES/LFILES/KILL/NAME まで全ファイル命令がフロッピーで使える。
; RAMパック (PAC) など従来デバイスも従来どおり動く。
;
; ■ デバイス番号
; "1:" = フロッピードライブ (コア内部のデバイス番号 0)
; "5:" = RAMパック (同 4)
;
; ■ デバイス記述子 (fd_desc_tab、媒体先頭の代わりに返す 12バイト)
; FCA8 = 34: 最大トラック番号 (0 始まり)。44AEh の上限
; チェック (DSKO$/DSKI$ の第2引数 ≤ FCA8) でのみ使われる。
; 35 だと存在しないトラック 35 が通ってしまうため 34 を
; 採用
; FCA9 = 16: 1グループあたりレコード数。FCAA=1 では
; グループ = 面 (2*トラック+ヘッド) なので 16 セクタ/面。
; FCAB*FCAE=16 が必須
; FCAA = 1: 面分離ジオメトリ (ブランチ)。1635h の無効化は
; ROM パッチ #16 で FCAA=FFh のときだけに変更済み
; FCAB = 2: 47A8h の除数。FCAA!=0 ではクラスタを半分化
; してから割り、商を倍化するので、グループ =
; 2*トラック+ヘッド になる
; FCAC = 140: 全クラスタ数
; FCAD = 18: 管理領域のトラック番号。39E1h が FCAA!=0 で
; 2 倍してグループ 36 (= Track18/Side0) にする。45C8h 系の
; B 値・マウント時の位置キャッシュ初期値のもと
; FCAE = 8: セクタ/クラスタ
; FCAF = 14: FAT 先頭セクタ (Track18/Side0)
; FCB0 = 16: FAT 最終セクタ
; FCB1 = 3: FAT コピー数
; FCB2 = 13: 属性ブロックの番号 (= ディレクトリブロック数+1。
; FILES/検索は 1..12 を走査、マウントは 13 を読む)
; FCB3 = 5: 容量ワード上位 ((FCB3,FCB2)=050Dh=1293 >
; 最大 index 1119。166Fh の範囲チェック用)
;
; =====================================================================

; ---------------- ROM 内アドレス ----------------
FC88	EQU 0FC88h			; 現在選択中デバイス番号 (0="1:")
FC86	EQU 0FC86h			; ディレクトリバッファへのポインタ
FC89	EQU 0FC89h			; 現在の DEVINFO へのポインタ
FCB7	EQU 0FCB7h			; 47D1h が使うリトライカウンタ格納
FCBA	EQU 0FCBAh			; FAT 書き戻し位置トラッカ
FCBB	EQU 0FCBBh			; 同上 (退避)
FCAF	EQU 0FCAFh			; 記述子 +7 (FAT 先頭セクタ)
ERR_IOX	EQU 4A7Eh			; コアの転送失敗エラー出口
RET_MNT	EQU 36DFh			; 47D1h の戻りアドレス: マウント属性読み
RET_PRO1	EQU 3FE4h		; 同: 属性更新 (読み)
RET_PRO2	EQU 3FEAh		; 同: 属性更新 (書き)

; ---------------- FDC ポート ----------------
FDC_STATUS	EQU 0E4h
FDC_DATA	EQU 0E5h
FDC_CONTROL	EQU 0E6h
TC_ON	EQU 0E2h
TC_OFF	EQU 0E0h

; ---------------- ディスク構成 ----------------
MGMT_TRK	EQU 18			; 管理領域トラック (Side0)
FAT_SEC1	EQU 14			; FAT 先頭セクタ
FAT_SEC3	EQU 16			; FAT 最終セクタ

SECBUF	EQU 0F9C4h			; 256B セクタバッファ (共用エリア)
DSK_WORK	EQU 0FF40h		; ★ディスク用ワーク RAM 先頭

; ワーク配置 (DSK_WORK からのオフセット)
; +0..+21 diskio 用 (fdc_param/fdc_resp/cur_track)
; +22.. カウンタ類と自前ワーク
MOTOR_STATE	EQU DSK_WORK+22
MOTOR_OFF_TIME	EQU DSK_WORK+23
INTCOUNT	EQU DSK_WORK+24		; dx_tick が更新 (64Hz)
INTCOUNT16	EQU DSK_WORK+25		; dx_tick が更新 (4Hz)
; DSK_WORK+26 は未使用 (空き)
dx_tdiv	EQU DSK_WORK+27			; tick 16分周カウンタ
dx_rw	EQU DSK_WORK+28			; diskio 用 R/W (0=write 1=read)
fd_cnt	EQU DSK_WORK+29			; fd_rec のレコード数
fd_ret	EQU DSK_WORK+30			; fd_rec の戻りアドレス (2)
fd_sec	EQU DSK_WORK+32			; 算出したセクタ番号
fd_trk	EQU DSK_WORK+33			; 算出したトラック番号
fd_aside	EQU DSK_WORK+34		; setparam 用 A (面ビット 00h/80h)
fd_tmp	EQU DSK_WORK+35			; 汎用 (部分転送の方向退避)
us_hd	EQU DSK_WORK+36			; R/Wコマンド用 US/HD バイト (diskio)
fd_att	EQU DSK_WORK+37			; fd_sio のリトライ残回数
; DSK_WORK+40 まで使用 (dx_winit のクリア範囲)

ORG	08000h				; ★配置先 (ブート後の RAM イメージ内)

; =====================================================================
; fd_xfer: 17B2h 横取り (レコード転送の最下層)
; 入口 (17B2h 純正と同一):
; HL = バッファ, DE = 媒体通し番号 index (記述子読みでは 0)
; B = バイト数 (0=256, 12=記述子, E0h=最終レコード部分)
; キャリ = 書込時セット / 読込時クリア, (FC88)=選択中デバイス
; デバイス 0-3 はフロッピー転送 (物理ドライブ = コア番号)、
; デバイス 4 は純正デバイス 0
; 経路 (17C6h = RAMパック実機) へ、それ以外は純正 17B5h へ。
; =====================================================================
fd_xfer:
	push	de			; 純正 17B2h の先頭 3 命令 (JP で置換された分)
	push	hl
	push	af
	ld	a,(FC88)
	cp	4			; コア 0-3 = フロッピー (物理ドライブ = コア番号)
	jr	c,fd_x_dev0
	jr	z,fd_x_pack		; コア 4 = RAMパック (純正デバイス 0 経路へ)
	jp	17B5h			; その他: 純正コード継続 (スタックも純正どおり)

fd_x_pack:
	jp	17C6h			; 純正デバイス 0 経路 (ポート 18h/1Ah 系 = RAMパック)

fd_x_dev0:
	ld	a,b
	cp	12
	jr	z,fd_x_desc
	pop	af			; 入口 AF (キャリ = 方向)
	ld	a,1			; FDD_RW_READ
	jr	nc,fd_x_d1
	xor	a			; FDD_RW_WRITE
fd_x_d1:
	ld	(dx_rw),a
	pop	hl			; バッファ
	pop	de			; index
	ld	a,b
	or	a
	jr	z,fd_x_full
	jr	fd_x_stg

; --- 記述子読み: 定数表 12バイトを (HL)=FCA8h へ ---
fd_x_desc:
	pop	af
	pop	hl			; HL = 記述子の格納先 (FCA8h)
	pop	de
	ex	de,hl			; DE = 格納先 (HL はこの直後に上書きされる)
	ld	hl,fd_desc_tab
	ld	bc,12
	ldir
	or	a
	ret

; --- 通常レコード: 256バイトを直接転送 ---
fd_x_full:
	call	fd_chs			; DE=index -> D=トラック, E=セクタ, A=面
	call	fd_sio			; HL=バッファ, (dx_rw)=方向
	ret	nc
	jp	ERR_IOX

; --- 部分レコード (B バイト): SECBUF 経由 ---
fd_x_stg:
	ld	a,(dx_rw)
	ld	(fd_tmp),a		; ユーザの方向を退避
	push	bc			; バイト数
	push	hl			; ユーザバッファ
	call	fd_chs			; fd_trk/fd_sec/fd_aside を設定
	ld	a,1
	ld	(dx_rw),a		; まずセクタを読む
	ld	a,(fd_trk)
	ld	d,a
	ld	a,(fd_sec)
	ld	e,a
	ld	a,(fd_aside)
	ld	hl,SECBUF
	call	fd_sio
	jp	c,ERR_IOX
	pop	hl			; ユーザバッファ
	pop	bc			; B = バイト数
	ld	a,(fd_tmp)
	or	a
	jr	z,fd_x_s_wr
; 読込: SECBUF の先頭 B バイトをユーザバッファへ
	ld	de,SECBUF
	ex	de,hl			; HL=SECBUF (元), DE=ユーザバッファ (先)
	ld	c,b
	ld	b,0
	ldir
	or	a
	ret
fd_x_s_wr:
; 書込: ユーザバッファの先頭 B バイトを SECBUF に重ねて書き戻す
	ld	de,SECBUF
	ld	c,b
	ld	b,0
	ldir				; HL=ユーザバッファ (元), DE=SECBUF (先)
	ld	a,0
	ld	(dx_rw),a
	ld	a,(fd_trk)
	ld	d,a
	ld	a,(fd_sec)
	ld	e,a
	ld	a,(fd_aside)
	ld	hl,SECBUF
	call	fd_sio
	ret	nc
	jp	ERR_IOX

; --- index -> 物理アドレス変換 ---
; 入口: DE = index (166Fh の計算値)。FCAA=1 では index は
; 面優先の並び: index = 32*トラック + 16*面 + 8*ハーフ + (sic-1)
; 出口: D = トラック, E = セクタ (1-16), A = setparam 用 (面<<7)
; fd_trk / fd_sec / fd_aside にも同じ値を残す。HL, BC 保存。
fd_chs:
; (DE = index をそのまま分解する)
	ld	a,e
	and	0Fh			; セクタ-1 (bit3=ハーフ、bit0-2=sic-1)
	inc	a
	ld	(fd_sec),a		; セクタ (1-16)
	ld	a,e
	and	10h			; 面ビット (bit4)
	jr	z,fd_ch_2
	ld	a,80h
	jr	fd_ch_3
fd_ch_2:
	xor	a
fd_ch_3:
	ld	(fd_aside),a
	ld	a,e
	and	0E0h
	rrca
	rrca
	rrca
	rrca
	rrca				; (v>>5) の下位 3ビット
	ld	(fd_trk),a
	ld	a,d
	and	07h			; v の上位側
	add	a,a
	add	a,a
	add	a,a			; <<3
	ld	e,a
	ld	a,(fd_trk)
	add	a,e
	ld	(fd_trk),a		; トラック = v>>5
	ld	d,a
	ld	a,(fd_sec)
	ld	e,a
	ld	a,(fd_aside)
	ret

; --- 1セクタ転送 (diskio ラッパ) ---
; 入口: D = トラック, E = セクタ, A = setparam 用 (面/ドライブ)
; HL = バッファ, (dx_rw) = 0:write / 1:read
; 出口: キャリ = エラー。BC 保存。
; 失敗時は最大3回まで再試行する。cur_track は触らない (recalibrate しない)。
; fdd_rw は毎回シークするので、再試行 = 同トラックへの再シーク + 再転送になる。
fd_sio:
	push	bc
	push	hl
	push	af			; setparam バイト (面) を退避
	ld	a,(FC88)
	and	03h			; ドライブ番号 (コア番号 0-3)
	ld	b,a
	pop	af
	or	b			; A = 面 | ドライブ
	ld	b,1			; 1セクタ
	call	fdd_setparam
	pop	hl
	ld	a,3
	ld	(fd_att),a		; リトライは最大3回まで
fd_sio_lp:
	push	hl			; バッファ退避 (fdd_rw の出口 HL は不定)
	ld	a,(dx_rw)
	call	fdd_rw
	pop	hl
	jr	nc,fd_sio_ok		; 成功
	ld	a,(fd_att)
	dec	a
	ld	(fd_att),a
	jr	nz,fd_sio_lp		; 尽きたらキャリ付きで抜ける
fd_sio_ok:
	pop	bc
	ret

; --- 管理セクタ共通転送 (fd_dir_rd / fd_dir_wr / fd_fat_rd 共用) ---
; 入口: A = 方向 (1 = 読込 / 0 = 書込), E = セクタ番号
; Track18/Side0 のセクタ E を (FC86h) と転送する。
; 出口: HL = (FC86h), キャリ = エラー。BC / DE 保存。
fd_mgmt_io:
	push	bc
	push	de
	ld	d,MGMT_TRK
	ld	(dx_rw),a
	xor	a			; 面0 (ドライブは fd_sio が (FC88) から合成)
	ld	hl,(FC86)
	call	fd_sio
	ld	hl,(FC86)
	pop	de
	pop	bc
	ret

; =====================================================================
; fd_dir_rd: 45C8h 横取り (ディレクトリ読み)
; 入口 (純正と同一): D = ブロック番号 (1..13), 戻り HL = (FC86h)
; デバイス 1-4 では Track18/Side0 のセクタ D を (FC86h) へ読む。
; =====================================================================
fd_dir_rd:
	ld	a,(FC88)
	cp	4
	jr	nc,fd_dr_stock
	ld	e,d			; セクタ = ブロック番号
	ld	a,1			; 読込
	call	fd_mgmt_io		; 出口 HL = ディレクトリバッファ
	ret	nc
	jp	ERR_IOX
fd_dr_stock:
	push	de			; 純正 45C8h の置換された 3 バイト分を複製
	ld	c,d
	call	39B6h
	jp	45CDh

; =====================================================================
; fd_dir_wr: 45E1h 横取り (ディレクトリ書き戻し)
; 入口 (純正と同一): D = ブロック番号 (1..13)
; デバイス 1-4 では (FC86h) の内容を Track18/Side0 のセクタ D へ書く。
; =====================================================================
fd_dir_wr:
	ld	a,(FC88)
	cp	4
	jr	nc,fd_dw_stock
	ld	e,d			; セクタ = ブロック番号
	xor	a			; 書込
	call	fd_mgmt_io
	ret	nc
	jp	ERR_IOX
fd_dw_stock:
	push	de			; 純正 45E1h の置換分を複製
	xor	a
	ld	(FCBA),a
	jp	45E6h

; =====================================================================
; fd_fat_rd: 45B2h 横取り (FAT コピー読み、マウント時の検証用)
; 入口 (純正と同一): B = FCAD (39B6h の値), C = コピーセクタ番号
; デバイス 1 ではセクタ C を (FC86h) に読み、純正のスワップ処理
; (45BBh: (FC86h) <-> 常駐 FAT の交換) に合流する。
; 読み失敗時は交換せずキャリを立てて戻る (読めなかった
; コピーとしてマウント側に数えさせる)。
; 【入口フラグの保存が必須】純正側は入口フラグを隠しパラメータとして
; 使う: 47D1h 経由で 166Fh に届いた Z フラグが 169Ch の JR Z で
; 参照され、Z=1 だと転送自体がスキップされる (キャリ 0 = 成功扱い)。
; ゲートの CP 4 はデバイス 4 で Z=1 を作ってしまうため、
; 純正経路では入口 AF を復帰してから複製に入る (壊すと
; パックの FAT 読みが無言でスキップされる)。
; =====================================================================
fd_fat_rd:
	push	af			; 入口 AF を保存
	ld	a,(FC88)
	cp	4
	jr	nc,fd_fr_stock
	pop	af			; FDD 経路: 保存分を破棄 (スタック均衡)
	ld	e,c			; セクタ = コピー番号 (14..16)
	ld	a,1			; 読込
	call	fd_mgmt_io
	jp	c,fd_fr_err
	jp	45BBh			; 純正のスワップ処理へ
fd_fr_err:
	scf
	ret
fd_fr_stock:
	pop	af			; 入口 AF を復帰 (フラグも純正どおり)
	ld	a,1			; 純正 45B2h の置換分を複製
	ld	hl,(FC86)
	jp	45B7h

; =====================================================================
; fd_fat_wr: 4538h 横取り (FAT 書き戻し)
; デバイス 1-4 では常駐 FAT (DEVINFO+3) を Track18/Side0 の
; セクタ 14-16 (3コピー) に 256バイトずつ書き、(DEVINFO+1)
; を落とす。失敗時はキャリを立てて戻る (純正契約)。
; =====================================================================
fd_fat_wr:
	ld	a,(FC88)
	cp	4
	jr	nc,fd_fw_stock
	ld	hl,FCBA			; 純正プロローグの (FCBA)/(FCBB) 入替を模倣
	ld	a,(hl)
	ld	(hl),0
	inc	hl
	ld	(hl),a
	ld	a,0
	ld	(dx_rw),a		; 書込
	ld	c,FAT_SEC1
fd_fw_lp:
	ld	e,c
	ld	d,MGMT_TRK
	xor	a
	ld	hl,(FC89)
	inc	hl
	inc	hl
	inc	hl			; HL = 常駐 FAT 先頭
	call	fd_sio			; BC は fd_sio が保存 (C = セクタ番号が残る)
	jr	c,fd_fw_err
	inc	c
	ld	a,c
	cp	FAT_SEC3+1
	jr	nz,fd_fw_lp
	ld	hl,(FC89)		; 純正エピローグに合わせ (DEVINFO+1) を落とす
	inc	hl
	ld	(hl),0
	ld	a,(FCBB)		; 純正エピローグの (FCBA) 復旧を模倣
	ld	(FCBA),a
	or	a
	ret
fd_fw_err:
	scf
	ret
fd_fw_stock:
	ld	a,(FCAF)		; 純正 4538h の置換分を複製
	jp	453Bh

; =====================================================================
; fd_rec: 47D1h 横取り (レコード転送の入口)
; 通常のデータ転送は純正に流す (→166Fh→fd_xfer で処理)。
; 次の戻りアドレスからの呼び出しだけは管理領域への直接転送
; なので、デバイス 1-4 の場合に限り横取りする:
; 36DFh: マウント時の属性ブロック読み (B=FCAD, C=(FCB2)=13)
; 3FE4h: 属性更新のための読み (B=FCAD, C=13)
; 3FEAh: 属性更新の書き戻し (B=FCAD, C=13)
; いずれも HL = (FC86h), A = 1レコード, 対象は Track18/Side0
; のセクタ C。
; 【出口契約】純正 47D1h は入口の A (レコード数) を保って戻る。
; 3FEAh の書戻しは A を再設定せず、3FE4h の読みの戻り A を
; そのままレコード数として使う。ここで A を壊すと書戻しが
; 0 (=256) レコードになって管理領域以降を潰す。
; =====================================================================
fd_rec:
	ld	(fd_cnt),a		; レコード数
	push	af			; 純正複製分 + 判定用に退避 (キャリ = 方向)
	jr	c,fd_rc_w
	ld	a,1			; 読込
	jr	fd_rc_s
fd_rc_w:
	xor	a			; 書込
fd_rc_s:
	ld	(dx_rw),a
	push	hl			; 戻りアドレスを覗く
	push	de
	ld	hl,6			; SP: [DE][HL][AF][戻り] -> 戻りは +6
	add	hl,sp
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	ld	(fd_ret),de
	pop	de
	pop	hl
	ld	a,(FC88)
	cp	4
	jr	nc,fd_rc_stock
	ld	de,(fd_ret)
	ld	a,d
	cp	36h
	jr	nz,fd_rc_t2
	ld	a,e
	cp	0DFh			; RET_MNT (36DFh) の下位バイト
	jr	z,fd_rc_sys
	jr	fd_rc_stock
fd_rc_t2:
	ld	a,d
	cp	3Fh
	jr	nz,fd_rc_stock
	ld	a,e
	cp	0E4h			; RET_PRO1 (3FE4h) の下位バイト
	jr	z,fd_rc_sys
	cp	0EAh			; RET_PRO2 (3FEAh) の下位バイト
	jr	nz,fd_rc_stock
fd_rc_sys:
	pop	af			; 退避した入口 AF を破棄 (スタック均衡)
	ld	a,(fd_cnt)
	ld	b,a
fd_rc_lp:
	push	hl
	ld	e,c			; セクタ = C
	ld	d,MGMT_TRK
	xor	a
	call	fd_sio			; BC は fd_sio が保存 (B = 残レコード数が残る)
	pop	hl
	jp	c,ERR_IOX
	inc	c
	ld	de,100h
	add	hl,de
	djnz	fd_rc_lp
	ld	a,(fd_cnt)		; 純正 47D1h は入口 A (レコード数) を保って
	or	a			; 戻る。属性の書戻し (3FEAh) は前の読み
	ret				; (3FE4h) の戻り A をそのまま使うため必須
fd_rc_stock:
	pop	af			; 入口 AF 復帰
	push	af			; 純正 47D1h の置換分を複製
	xor	a
	ld	(FCB7),a
	jp	47D6h

; =====================================================================
; dx_tick: タイマ割り込みフック (0807h から呼ばれる)
; ROM の割り込みハンドラ (0800h) が PUSH したレジスタを復帰する
; 前提で呼ばれる。まず元の 184Dh を実行し、diskio 用の
; INTCOUNT (毎回 +1) / INTCOUNT16 (16回に1回 +1) を保守する。
; MOTOR_OFF_REQ 状態で期限 (MOTOR_OFF_TIME) を過ぎたら
; FDC_CONTROL へ 00h を出力してモータを止める。
; 使用は AF/HL のみ。
; =====================================================================
dx_tick:
	call	184Dh			; 元の画面タイマ処理
	ld	hl,INTCOUNT
	inc	(hl)			; INTCOUNT++
	ld	hl,dx_tdiv
	inc	(hl)
	ld	a,(hl)
	cp	16
	ret	c			; 16回に1回だけ以下を実行
	ld	(hl),0
	ld	hl,INTCOUNT16
	inc	(hl)			; INTCOUNT16++
	ld	a,(MOTOR_STATE)
	cp	01h			; MOTOR_OFF_REQ
	ret	nz
	ld	a,(INTCOUNT16)
	ld	hl,MOTOR_OFF_TIME
	sub	(hl)			; 現在 - 期限 (8ビット差分)
	and	80h
	ret	nz			; bit7=1 は「まだ期限前」
	xor	a			; MOTOR_OFF = 00h
	out	(FDC_CONTROL),a
	ld	(MOTOR_STATE),a
	ret

; --- コールドスタート初期化フック (02C9h の CALL 先を横取り) ---
; 元の 161Bh を実行した後、そのまま dx_winit へ落ちて DSK_WORK を
; 初期化する。
fd_cinit:
	call	161Bh

; --- ワーク初期化 (コールドスタート時、無条件。HL/BC 保存) ---
; fd_cinit はブート経路 (02C9h) からしか呼ばれないので、ここは
; 毎ブート必ず初期化する。
dx_winit:
	push	hl
	push	bc
	ld	hl,DSK_WORK
	ld	b,40
	xor	a
dx_wi_lp:
	ld	(hl),a
	inc	hl
	djnz	dx_wi_lp
	call	dx_fill_ct		; cur_track を「不明」(FFh)に
; MOTOR_STATE は 0 (MOTOR_OFF) のままにする。
; INTCOUNT 系は dx_tick (タイマ割り込みフック) が回すので、
; 初回の fdd_rw で正規のスピンアップ待ちが働く。
	pop	bc
	pop	hl
	ret

; cur_track[0..3] を「不明」(FFh) に戻す (dx_winit から使用)
dx_fill_ct:
	ld	hl,DSK_WORK+18
	ld	a,0FFh
	ld	b,4
dx_fl_lp:
	ld	(hl),a
	inc	hl
	djnz	dx_fl_lp
	ret

; --- パックプローブの振り分け (パッチ17: 1635h から) ---
; 純正 1635h はコア0の選択時にスロット2のパックへ書き込みプローブ
; (ポート 1Ah への反転書き込み+復元) を行い、結果を FE96h に残す。
; 本版ではコア0は FDD なので、プローブは本物のパック (コア4) の
; 選択時だけに移す。"1:"-"4:" の選択でパックに触らなくなる。
; 入口: A = デバイス番号, B = 12 (1635h の LD B,C 実行済み)
; 出口: 純正 1639h (プローブ) または 1650h (記述子読み) へ JP
fd_probe_gate:
	cp	4			; コア4 = RAMパック
	jp	z,1639h			; プローブ実行
	jp	1650h			; それ以外はプローブなし

; --- デバイス記述子 (FCA8h へ返す 12バイト) ---
fd_desc_tab:
	db	34, 16, 1, 2, 140, 18, 8, 14, 16, 3, 13, 5
; FCA8 FCA9 FCAA FCAB FCAC FCAD FCAE FCAF FCB0 FCB1 FCB2 FCB3

; =====================================================================
; diskio (µPD765 セクタ R/W ルーチン、diskio_body.inc を収録)
; =====================================================================
INCLUDE	"diskio_body.inc"

END
