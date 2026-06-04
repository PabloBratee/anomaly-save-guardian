<#
.SYNOPSIS
    Generate the Anomaly Save Guardian app icon (anomaly-save-guardian.ico).

.DESCRIPTION
    Dependency-free icon generator. Draws a protective shield with a circular
    restore arrow in the app's radioactive-green accent on a dark rounded tile,
    using only built-in System.Drawing (GDI+). Renders several sizes and packs
    them into a multi-resolution Windows .ico, plus a 256px preview .png.

    The design reads on both dark and light backgrounds: a dark tile keeps the
    bright shield legible, and the bold shield + restore arrow stay recognisable
    down to 16x16 in the taskbar / tray.

    PowerShell 5.1 compatible. Run from anywhere:
        .\assets\build-icon.ps1
#>
[CmdletBinding()]
param(
    # Where to write the .ico. Defaults to the repo root next to this folder.
    [string]$OutIco,
    # Where to write the preview .png. Defaults next to the .ico.
    [string]$OutPng
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$assetsDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $assetsDir
if (-not $OutIco) { $OutIco = Join-Path $repoRoot 'anomaly-save-guardian.ico' }
if (-not $OutPng) { $OutPng = Join-Path $assetsDir 'anomaly-save-guardian.png' }

function New-Color { param([int]$r, [int]$g, [int]$b, [int]$a = 255) [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function Add-RoundedRect {
    param([System.Drawing.Drawing2D.GraphicsPath]$Path, [single]$x, [single]$y, [single]$w, [single]$h, [single]$r)
    $d = $r * 2
    $Path.AddArc($x, $y, $d, $d, 180, 90)
    $Path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $Path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $Path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $Path.CloseFigure()
}

function Draw-Icon {
    param([System.Drawing.Graphics]$g, [int]$S)

    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [single]$S
    $cx = $s * 0.5

    # --- Dark rounded tile (keeps the shield readable on light or dark backgrounds) ---
    $tilePad = $s * 0.045
    $tileRad = $s * 0.215
    $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
    Add-RoundedRect $tile $tilePad $tilePad ($s - 2 * $tilePad) ($s - 2 * $tilePad) $tileRad
    $tileRect = New-Object System.Drawing.RectangleF($tilePad, $tilePad, ($s - 2 * $tilePad), ($s - 2 * $tilePad))
    $tileBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $tileRect, (New-Color 39 43 51), (New-Color 18 20 26), 90)
    $g.FillPath($tileBrush, $tile)
    # subtle top inner highlight
    $tilePen = New-Object System.Drawing.Pen((New-Color 70 78 90 90), [single]([Math]::Max(1, $s * 0.012)))
    $g.DrawPath($tilePen, $tile)
    $tilePen.Dispose(); $tileBrush.Dispose()

    # --- Shield ---
    $hw  = $s * 0.285          # half width at the shoulders
    $top = $s * 0.215
    $tr  = $s * 0.085          # top corner radius
    $shoulder = $s * 0.495
    $tip = $s * 0.855

    $shield = New-Object System.Drawing.Drawing2D.GraphicsPath
    $shield.AddArc(($cx - $hw), $top, ($tr * 2), ($tr * 2), 180, 90)
    $shield.AddArc(($cx + $hw - $tr * 2), $top, ($tr * 2), ($tr * 2), 270, 90)
    $shield.AddLine(($cx + $hw), ($top + $tr), ($cx + $hw), $shoulder)
    $shield.AddBezier(
        ($cx + $hw), $shoulder,
        ($cx + $hw), ($s * 0.72),
        ($cx + $hw * 0.46), ($tip - $s * 0.02),
        $cx, $tip)
    $shield.AddBezier(
        $cx, $tip,
        ($cx - $hw * 0.46), ($tip - $s * 0.02),
        ($cx - $hw), ($s * 0.72),
        ($cx - $hw), $shoulder)
    $shield.AddLine(($cx - $hw), $shoulder, ($cx - $hw), ($top + $tr))
    $shield.CloseFigure()

    $shieldRect = New-Object System.Drawing.RectangleF(($cx - $hw), $top, ($hw * 2), ($tip - $top))
    $shieldBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $shieldRect, (New-Color 170 230 98), (New-Color 104 168 56), 90)
    $g.FillPath($shieldBrush, $shield)
    $shieldPen = New-Object System.Drawing.Pen((New-Color 66 112 38), [single]([Math]::Max(1, $s * 0.022)))
    $shieldPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($shieldPen, $shield)
    $shieldBrush.Dispose(); $shieldPen.Dispose()

    # inner shield sheen (top-left soft highlight)
    $sheen = New-Object System.Drawing.Drawing2D.GraphicsPath
    $sheen.AddEllipse(($cx - $hw * 0.8), ($top + $s * 0.02), ($hw * 1.0), ($s * 0.26))
    $sheenBrush = New-Object System.Drawing.SolidBrush((New-Color 255 255 255 26))
    $clip = $g.Clip
    $g.SetClip($shield)
    $g.FillPath($sheenBrush, $sheen)
    $g.Clip = $clip
    $sheenBrush.Dispose(); $sheen.Dispose()

    # --- Circular restore arrow (dark, engraved into the shield) ---
    $ccx = $cx
    $ccy = $s * 0.515
    $r   = $s * 0.155
    $penW = [single]($s * 0.072)
    $arrowColor = New-Color 23 26 33
    $arcPen = New-Object System.Drawing.Pen($arrowColor, $penW)
    $arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

    # Arc sweeps clockwise leaving a gap at the top for the arrowhead.
    $startAngle = 300.0
    $sweep      = 250.0
    $g.DrawArc($arcPen, ($ccx - $r), ($ccy - $r), ($r * 2), ($r * 2), $startAngle, $sweep)
    $arcPen.Dispose()

    # Arrowhead at the leading (end) tip, pointing along the clockwise tangent.
    $endDeg = $startAngle + $sweep
    $endRad = $endDeg * [Math]::PI / 180.0
    $px = $ccx + $r * [Math]::Cos($endRad)
    $py = $ccy + $r * [Math]::Sin($endRad)
    $dirX = -[Math]::Sin($endRad); $dirY = [Math]::Cos($endRad)   # clockwise travel
    $radX = [Math]::Cos($endRad);  $radY = [Math]::Sin($endRad)   # outward radial
    $headLen = $s * 0.135
    $headW   = $s * 0.105
    $tipX = $px + $dirX * $headLen
    $tipY = $py + $dirY * $headLen
    $baseX = $px - $dirX * ($headLen * 0.15)
    $baseY = $py - $dirY * ($headLen * 0.15)
    $p1 = New-Object System.Drawing.PointF(([single]($baseX + $radX * $headW)), ([single]($baseY + $radY * $headW)))
    $p2 = New-Object System.Drawing.PointF(([single]($baseX - $radX * $headW)), ([single]($baseY - $radY * $headW)))
    $p3 = New-Object System.Drawing.PointF(([single]$tipX), ([single]$tipY))
    $headBrush = New-Object System.Drawing.SolidBrush($arrowColor)
    $g.FillPolygon($headBrush, @($p1, $p2, $p3))
    $headBrush.Dispose()

    $tile.Dispose(); $shield.Dispose()
}

function New-IconBitmap {
    param([int]$S)
    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bmp.SetResolution(96, 96)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { Draw-Icon $g $S } finally { $g.Dispose() }
    return $bmp
}

# --- Render frames (uncompressed DIB; up to 128 keeps the file lean) ---
$sizes = @(16, 24, 32, 48, 64, 128)
$bitmaps = @{}
foreach ($sz in $sizes) { $bitmaps[$sz] = New-IconBitmap $sz }

# --- Preview PNG (rendered at 256 for clarity) ---
$preview = New-IconBitmap 256
$preview.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()
Write-Host "Preview : $OutPng" -ForegroundColor Cyan

# --- Encode each frame as an uncompressed 32bpp BMP DIB ---
# PNG-compressed frames keep the file small, but System.Drawing.Icon (used by the
# UI to load this icon for the window and tray) cannot decode them and renders
# garbage. Uncompressed DIB frames load correctly everywhere the app uses them.
function Get-DibBytes {
    param([System.Drawing.Bitmap]$bmp)
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    }
    finally { $bmp.UnlockBits($data) }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        # BITMAPINFOHEADER: height is doubled (XOR image + AND mask)
        $bw.Write([int]40)          # biSize
        $bw.Write([int]$w)          # biWidth
        $bw.Write([int]($h * 2))    # biHeight (XOR + AND)
        $bw.Write([int16]1)         # biPlanes
        $bw.Write([int16]32)        # biBitCount
        $bw.Write([int]0)           # biCompression (BI_RGB)
        $bw.Write([int]($w * $h * 4)) # biSizeImage
        $bw.Write([int]0); $bw.Write([int]0)   # ppm x/y
        $bw.Write([int]0); $bw.Write([int]0)   # clrUsed / clrImportant

        # XOR (BGRA) bottom-up
        for ($y = $h - 1; $y -ge 0; $y--) {
            $row = $y * $stride
            $bw.Write($buf, $row, $w * 4)
        }
        # AND mask: 1bpp, rows padded to 32-bit boundary. All zero = use alpha.
        $maskStride = [int]([Math]::Floor((($w + 31) / 32)) * 4)
        $zeros = New-Object byte[] ($maskStride * $h)
        $bw.Write($zeros, 0, $zeros.Length)
        $bw.Flush()
        return $ms.ToArray()
    }
    finally { $bw.Dispose(); $ms.Dispose() }
}

$frames = @()
foreach ($sz in $sizes) {
    $frames += [PSCustomObject]@{ Size = $sz; Bytes = (Get-DibBytes $bitmaps[$sz]) }
}

# --- Write the .ico container ---
$fs = New-Object System.IO.FileStream($OutIco, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter($fs)
try {
    $bw.Write([int16]0)               # reserved
    $bw.Write([int16]1)               # type = icon
    $bw.Write([int16]$frames.Count)   # image count

    $offset = 6 + (16 * $frames.Count)
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $bw.Write([byte]$dim)         # width
        $bw.Write([byte]$dim)         # height
        $bw.Write([byte]0)            # color count
        $bw.Write([byte]0)            # reserved
        $bw.Write([int16]1)           # planes
        $bw.Write([int16]32)          # bit count
        $bw.Write([int]$f.Bytes.Length)
        $bw.Write([int]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Bytes, 0, $f.Bytes.Length) }
    $bw.Flush()
}
finally {
    $bw.Dispose(); $fs.Dispose()
    foreach ($sz in $sizes) { $bitmaps[$sz].Dispose() }
}

$kb = '{0:N1} KB' -f ((Get-Item -LiteralPath $OutIco).Length / 1KB)
Write-Host "Icon    : $OutIco  ($kb, $($frames.Count) sizes)" -ForegroundColor Green

# Sanity-check that the .ico loads as a usable icon.
$test = New-Object System.Drawing.Icon($OutIco)
Write-Host ("Loaded  : default frame {0}x{1}" -f $test.Width, $test.Height) -ForegroundColor Green
$test.Dispose()
