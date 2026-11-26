#Requires -Version 5.1
<#
.SYNOPSIS
    PASOPIA (PA7010) T-BASIC フロッピー拡張のブートディスク (.2d) を生成する。

.DESCRIPTION
    純正 T-BASIC ROM イメージ (tbasic.rom) にパッチを当て、ドライバ
    (disk_basic.bin) とブートセクタ (bootsec.bin) と一緒に、フロッピー
    からブートできる PASOPIA7 形式 2D ディスクイメージを組み立てる。

    生成されるディスクは「フォーマット済みの空ディスク」にブート
    セクタとペイロードを書いたもので、他のディスクイメージは不要。
    ブートするとパッチ済み BASIC 本体が RAM に読み込まれて起動し、
    フロッピー ("1:") と RAM パック ("5:") の両方が使えるようになる。

    必要なファイル (このスクリプトと同じフォルダに置く):
      disk_basic.bin / disk_basic.sym   ドライバ本体とそのシンボル
      bootsec.bin                       ブートセクタ

    JP/CALL の飛び先は disk_basic.sym から読む (無い場合はスクリプト
    内蔵の、配布バイナリと一致する値を使う)。

.PARAMETER RomPath
    純正 tbasic.rom のパス。既定はこのスクリプトと同じフォルダの
    tbasic.rom。

.PARAMETER OutPath
    出力する .2d ファイル。既定は pasopia_boot.2d。

.EXAMPLE
    .\build_boot_disk.ps1 -RomPath C:\roms\tbasic.rom
#>
[CmdletBinding()]
param(
    [string]$RomPath = (Join-Path $PSScriptRoot 'tbasic.rom'),
    [string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- 設定 ----------
# 起動時サインオンに追加する行 (パッチ #18 で ROM の 7FC0h へ書き込む)
$SignOnLine = 'FDD ext. V1.0'

# ---------- ユーティリティ ----------
function Get-SectorOffset([int]$Track, [int]$Side, [int]$Sector) {
    # .2d レイアウト: トラック優先、面、セクタ (各 256 バイト)
    return ((($Track * 2 + $Side) * 16) + ($Sector - 1)) * 256
}

function Test-BytesEqual([byte[]]$A, [int]$OffA, [byte[]]$B, [int]$OffB, [int]$Len) {
    for ($i = 0; $i -lt $Len; $i++) {
        if ($A[$OffA + $i] -ne $B[$OffB + $i]) { return $false }
    }
    return $true
}

function ConvertTo-Hex([byte[]]$Bytes) {
    return (($Bytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
}

# ---------- 入力ファイル ----------
$drvBin  = Join-Path $PSScriptRoot 'disk_basic.bin'
$drvSym  = Join-Path $PSScriptRoot 'disk_basic.sym'
$bootBin = Join-Path $PSScriptRoot 'bootsec.bin'
if (-not $OutPath) {
    $OutPath = Join-Path $PSScriptRoot 'pasopia_boot.2d'
}
foreach ($f in @($RomPath, $drvBin, $bootBin)) {
    if (-not (Test-Path $f)) { throw "ファイルが見つかりません: $f" }
}

$rom  = [System.IO.File]::ReadAllBytes($RomPath)
$drv  = [System.IO.File]::ReadAllBytes($drvBin)
$boot = [System.IO.File]::ReadAllBytes($bootBin)

if ($rom.Length -ne 32768) { throw "tbasic.rom は 32768 バイトである必要があります (実際: $($rom.Length))" }
if ($drv.Length -gt 1136)  { throw "ドライバが 1136 バイト (8000h-846Fh) を超えています (実際: $($drv.Length))" }
if ($drv[0] -ne 0xD5)      { throw "ドライバの先頭バイトが D5h ではありません" }
if ($boot.Length -gt 256)  { throw "ブートセクタが 256 バイトを超えています (実際: $($boot.Length))" }
if ($boot[0] -ne 0xF3)     { throw "ブートセクタの先頭バイトが F3h ではありません" }

# ---------- フック先アドレス (.sym があれば読む) ----------
$sym = @{
    fd_xfer       = 0x8000
    fd_dir_rd     = 0x810E
    fd_dir_wr     = 0x8127
    fd_fat_rd     = 0x813F
    fd_fat_wr     = 0x815F
    fd_rec        = 0x81A0
    dx_tick       = 0x8208
    fd_cinit      = 0x8234
    fd_probe_gate = 0x8255
}
if (Test-Path $drvSym) {
    foreach ($line in Get-Content $drvSym) {
        if ($line -match '^\s*(\S+)\s+EQU\s+0([0-9A-F]+)H') {
            if ($sym.ContainsKey($Matches[1])) { $sym[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16) }
        }
    }
}
function New-Jump([int]$Addr) { return [byte[]]@(0xC3, ($Addr -band 0xFF), (($Addr -shr 8) -band 0xFF)) }
function New-Call([int]$Addr) { return [byte[]]@(0xCD, ($Addr -band 0xFF), (($Addr -shr 8) -band 0xFF)) }

# ---------- ROM パッチ ----------
# アドレス -> (純正バイト列, 変更後バイト列)
# ※ [ordered] にすると int キーが「位置インデックス」として解釈
#   されてしまうため、通常のハッシュテーブルを使う (適用順は不問)
$patches = @{
    0x17B2 = @([byte[]]@(0xD5, 0xE5, 0xF5),       (New-Jump $sym.fd_xfer))
    0x45C8 = @([byte[]]@(0xD5, 0x4A, 0xCD),       (New-Jump $sym.fd_dir_rd))
    0x45E1 = @([byte[]]@(0xD5, 0xAF, 0x32),       (New-Jump $sym.fd_dir_wr))
    0x45B2 = @([byte[]]@(0x3E, 0x01, 0x2A),       (New-Jump $sym.fd_fat_rd))
    0x4538 = @([byte[]]@(0x3A, 0xAF, 0xFC),       (New-Jump $sym.fd_fat_wr))
    0x47D1 = @([byte[]]@(0xF5, 0xAF, 0x32),       (New-Jump $sym.fd_rec))
    0x0807 = @([byte[]]@(0xCD, 0x4D, 0x18),       (New-Call $sym.dx_tick))
    0x7E6E = @([byte[]]@(0x02),                   [byte[]]@(0x06))
    0x7E94 = @([byte[]]@(0x00, 0x80),             [byte[]]@(0x70, 0x84))
    0x41B2 = @([byte[]]@(0xCD, 0x6C, 0x16),       [byte[]]@(0x00, 0x00, 0x00))
    0x02CA = @([byte[]]@(0x1B, 0x16),             [byte[]]@(($sym.fd_cinit -band 0xFF), (($sym.fd_cinit -shr 8) -band 0xFF)))
    0x38B2 = @([byte[]]@(0xCD, 0x6C, 0x16),       [byte[]]@(0x00, 0x00, 0x00))
    0x408E = @([byte[]]@(0xCD, 0x6C, 0x16),       [byte[]]@(0x00, 0x00, 0x00))
    0x447F = @([byte[]]@(0xCD, 0x6C, 0x16),       [byte[]]@(0x00, 0x00, 0x00))
    0x48B1 = @([byte[]]@(0xCD, 0x6C, 0x16),       [byte[]]@(0x00, 0x00, 0x00))
    0x165D = @([byte[]]@(0xB7, 0xC8),             [byte[]]@(0x3C, 0xC0))
    0x1636 = @([byte[]]@(0xB7, 0x20, 0x17),       (New-Jump $sym.fd_probe_gate))
}
# サインオン拡張 (7FC0h-7FF7h の 56 バイト全ゼロ領域を上書き)
$signon = [byte[]]::new(56)
$signonBytes = [System.Text.Encoding]::ASCII.GetBytes("$SignOnLine`r`n")
[Array]::Copy($signonBytes, 0, $signon, 0, $signonBytes.Length)
$patches[0x7FC0] = @([byte[]]::new(56), $signon)
$patched = [byte[]]$rom.Clone()
foreach ($addr in $patches.Keys) {
    $old, $new = $patches[$addr]
    if (-not (Test-BytesEqual $rom $addr $old 0 $old.Length)) {
        throw ("パッチ箇所 {0:X4}h の純正バイトが想定と違います (想定: {1} / 実際: {2})。" +
               'ROM の版が違うか、パッチ済みの可能性があります。') -f `
              $addr, (ConvertTo-Hex $old), (ConvertTo-Hex $rom[$addr..($addr + $old.Length - 1)])
    }
    [Array]::Copy($new, 0, $patched, $addr, $new.Length)
}
Write-Host ("ROM パッチ適用: 18 箇所 (fd_xfer={0:X4}h, dx_tick={1:X4}h, fd_cinit={2:X4}h, fd_probe_gate={3:X4}h)" -f $sym.fd_xfer, $sym.dx_tick, $sym.fd_cinit, $sym.fd_probe_gate)

# ---------- ディスクイメージ構築 (320KB, PASOPIA7 2D 形式) ----------
$img = [byte[]]::new(327680)

# 管理領域 (Track18/Side0): ディレクトリ S1-12 は空エントリ = FFh 埋め
for ($s = 1; $s -le 12; $s++) {
    $off = Get-SectorOffset 18 0 $s
    for ($i = 0; $i -lt 256; $i++) { $img[$off + $i] = 0xFF }
}
# 属性セクタ S13 は 0 埋め (イメージ初期値のまま)
# FAT S14-16 (3 コピー同内容): クラスタ 0-3 は形式予約、4-20 は
# ブートセクタ+ペイロードの占有分として FEh (予約)。72 と 74 は
# 管理領域 (Track18/Side0 のディレクトリ・属性・FAT 自身) なので
# FEh (予約)。それ以外の 21-139 は FFh (空き)、140 以降は 0
# (クラスタ総数 140 の範囲外)
$fat = [byte[]]::new(256)
for ($c = 0; $c -le 20; $c++)  { $fat[$c] = 0xFE }
for ($c = 21; $c -le 139; $c++) { $fat[$c] = 0xFF }
$fat[72] = 0xFE
$fat[74] = 0xFE
foreach ($s in 14, 15, 16) {
    [Array]::Copy($fat, 0, $img, (Get-SectorOffset 18 0 $s), 256)
}

# ブートセクタ (T1/S0/S1)
[Array]::Copy($boot, 0, $img, (Get-SectorOffset 1 0 1), $boot.Length)

# ペイロード: T1/S0/S2 から 133 セクタ (ROM 128 + ドライバ 5)
$payload = [byte[]]::new(133 * 256)
[Array]::Copy($patched, 0, $payload, 0, 32768)
[Array]::Copy($drv, 0, $payload, 32768, $drv.Length)
$t = 1; $side = 0; $r = 2
for ($i = 0; $i -lt 133; $i++) {
    [Array]::Copy($payload, $i * 256, $img, (Get-SectorOffset $t $side $r), 256)
    $r++
    if ($r -eq 17) {
        $r = 1
        $side = $side -bxor 1
        if ($side -eq 0) { $t++ }
    }
}

# ---------- 検証 ----------
$t = 1; $side = 0; $r = 2
for ($i = 0; $i -lt 133; $i++) {
    if (-not (Test-BytesEqual $img (Get-SectorOffset $t $side $r) $payload ($i * 256) 256)) {
        throw "検証失敗: ペイロード セクタ $i (T$t/S$side/S$r) が一致しません"
    }
    $r++
    if ($r -eq 17) { $r = 1; $side = $side -bxor 1; if ($side -eq 0) { $t++ } }
}
foreach ($s in 15, 16) {
    if (-not (Test-BytesEqual $img (Get-SectorOffset 18 0 $s) $img (Get-SectorOffset 18 0 14) 256)) {
        throw "検証失敗: FAT コピーが一致しません"
    }
}
# 管理領域自身のクラスタ (72, 74) が予約されていること
$fatoff = Get-SectorOffset 18 0 14
if ($img[$fatoff + 72] -ne 0xFE -or $img[$fatoff + 74] -ne 0xFE) {
    throw '検証失敗: FAT の管理領域クラスタ (72, 74) が予約されていません'
}
if ($img[(Get-SectorOffset 1 0 1)] -ne 0xF3) { throw '検証失敗: ブートセクタ先頭が F3h ではありません' }

[System.IO.File]::WriteAllBytes($OutPath, $img)
$hash = (Get-FileHash $OutPath -Algorithm SHA256).Hash
Write-Host "生成完了: $OutPath"
Write-Host "  SHA-256: $hash"
Write-Host '  起動後: "1:" = フロッピー, "5:" = RAM パック'
