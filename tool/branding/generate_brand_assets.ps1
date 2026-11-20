# Regenerates the platform brand assets from the sources in assets/icons/:
#
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_brand_assets.ps1
#   dart run flutter_launcher_icons      # Android launcher icons (pubspec.yaml)
#
# Run tool/branding/generate_emblem_sources.ps1 first: it builds these
# sources from the emblem, and the launcher foreground and monochrome layers.
#
# Sources (assets/icons/, 846 x 846 RGBA):
#   reelish_emblem_icon.png   the app icon (the emblem on a charcoal tile)
#   reelish_primary_logo.png  the primary logo (emblem over the wordmark), for
#                             splashes
#   reelish_wordmark.png      the wordmark alone
#
# Writes:
#   tool/branding/launcher_background.png             adaptive icon background:
#                                                     the icon's own gradient
#   android/app/src/main/res/drawable-nodpi/reelish_splash.png   splash logo
#   android/app/src/main/res/drawable-xhdpi/tv_banner.png        TV launcher
#   windows/runner/resources/app_icon.ico             exe, window, taskbar,
#                                                     installer
#
# Uses only System.Drawing, which ships with Windows.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$icons = Join-Path $root 'assets\icons'
$res = Join-Path $root 'android\app\src\main\res'

function Open-Png([string]$name) {
  # Read into memory so the source file is not locked while writing.
  $bytes = [System.IO.File]::ReadAllBytes((Join-Path $icons $name))
  $stream = New-Object System.IO.MemoryStream(, $bytes)
  return [System.Drawing.Bitmap]::FromStream($stream)
}

function New-Canvas([int]$width, [int]$height) {
  $bitmap = New-Object System.Drawing.Bitmap($width, $height,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  return @($bitmap, $graphics)
}

$icon = Open-Png 'reelish_emblem_icon.png'
$primary = Open-Png 'reelish_primary_logo.png'
$word = Open-Png 'reelish_wordmark.png'

# --- Adaptive icon background: the icon's vertical gradient, sampled from a
# column clear of the mark and the rounded corners.
$size = 432
$canvas = New-Canvas $size $size
$background, $g = $canvas
for ($y = 0; $y -lt $size; $y++) {
  $sourceY = [int](8 + $y * ($icon.Height - 17) / ($size - 1))
  $color = $icon.GetPixel(120, $sourceY)
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $color.R, $color.G, $color.B))
  $g.FillRectangle($brush, 0, $y, $size, 1)
  $brush.Dispose()
}
$g.Dispose()
$background.Save((Join-Path $PSScriptRoot 'launcher_background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$background.Dispose()

# The themed (monochrome) layer is written by generate_emblem_sources.ps1.

# --- Android splash logo: the primary logo, unchanged.
Copy-Item (Join-Path $icons 'reelish_primary_logo.png') (Join-Path $res 'drawable-nodpi\reelish_splash.png') -Force

# --- Android TV banner (320 x 180 at xhdpi): the app icon and the wordmark
# on Living Room's warm charcoal with a soft terracotta glow.
$canvas = New-Canvas 320 180
$banner, $g = $canvas
$g.Clear([System.Drawing.Color]::FromArgb(255, 0x14, 0x11, 0x0E))
$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
$glow.AddEllipse(-110, -80, 380, 340)
$glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
$glowBrush.CenterPoint = New-Object System.Drawing.PointF(72, 90)
$glowBrush.CenterColor = [System.Drawing.Color]::FromArgb(70, 0xBA, 0x72, 0x5A)
$glowBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 0xBA, 0x72, 0x5A))
$g.FillPath($glowBrush, $glow)
$glowBrush.Dispose(); $glow.Dispose()
$g.DrawImage($icon, (New-Object System.Drawing.Rectangle(26, 44, 92, 92)))
# The wordmark's content within its 846 x 846 canvas (measured from alpha).
$wordSource = New-Object System.Drawing.Rectangle(184, 394, 480, 58)
$wordWidth = 160
$wordHeight = [int][Math]::Round($wordWidth * $wordSource.Height / $wordSource.Width)
$g.DrawImage($word,
  (New-Object System.Drawing.Rectangle(134, [int](90 - $wordHeight / 2), $wordWidth, $wordHeight)),
  $wordSource, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$banner.Save((Join-Path $res 'drawable-xhdpi\tv_banner.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$banner.Dispose()

# --- Windows icon: every size Explorer, the taskbar and the title bar ask
# for. 256 px is a PNG entry (the convention since Windows Vista); smaller
# sizes are classic 32-bit bitmaps with alpha, which every icon reader
# understands.
function ConvertTo-IconBitmap([System.Drawing.Bitmap]$bitmap) {
  $s = $bitmap.Width
  $rect = New-Object System.Drawing.Rectangle(0, 0, $s, $s)
  $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $pixels = New-Object byte[] ($data.Stride * $s)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
  $bitmap.UnlockBits($data)
  $maskStride = [int]([Math]::Ceiling($s / 32) * 4)
  $stream = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter($stream)
  # BITMAPINFOHEADER; the height counts the colour rows and the mask rows.
  $w.Write([UInt32]40); $w.Write([Int32]$s); $w.Write([Int32]($s * 2))
  $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]0)
  $w.Write([UInt32]($s * $s * 4 + $maskStride * $s))
  $w.Write([Int32]0); $w.Write([Int32]0); $w.Write([UInt32]0); $w.Write([UInt32]0)
  # BGRA rows, bottom-up.
  for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($pixels, $y * $data.Stride, $s * 4) }
  # The AND mask is unused with an alpha channel: all zero.
  $w.Write((New-Object byte[] ($maskStride * $s)))
  $w.Flush()
  return , $stream.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$images = foreach ($s in $sizes) {
  $canvas = New-Canvas $s $s
  $bitmap, $g = $canvas
  $g.DrawImage($icon, (New-Object System.Drawing.Rectangle(0, 0, $s, $s)))
  $g.Dispose()
  if ($s -ge 256) {
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $entry = $stream.ToArray()
  } else {
    $entry = ConvertTo-IconBitmap $bitmap
  }
  $bitmap.Dispose()
  , $entry
}
$ico = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($ico)
$writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]
  $dimension = if ($s -ge 256) { 0 } else { $s }
  $writer.Write([Byte]$dimension); $writer.Write([Byte]$dimension)
  $writer.Write([Byte]0); $writer.Write([Byte]0)
  $writer.Write([UInt16]1); $writer.Write([UInt16]32)
  $writer.Write([UInt32]$images[$i].Length); $writer.Write([UInt32]$offset)
  $offset += $images[$i].Length
}
foreach ($image in $images) { $writer.Write($image) }
$writer.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $root 'windows\runner\resources\app_icon.ico'), $ico.ToArray())
$writer.Dispose()

$icon.Dispose(); $primary.Dispose(); $word.Dispose()
Write-Output 'Brand assets written.'
