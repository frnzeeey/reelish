# Regenerates the platform brand assets from the sources in assets/icons/:
#
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_brand_assets.ps1
#   dart run flutter_launcher_icons      # Android launcher icons (pubspec.yaml)
#
# Sources (assets/icons/, 846 x 846 RGBA):
#   reelish_icon.png  the app icon (coral tile, white mark)
#   Primary_logo.png  the primary logo (mark over the wordmark), for splashes
#   logo_icon.png     the mark alone (adaptive icon foreground, monochrome)
#   word_logo.png     the wordmark alone
#
# Writes:
#   tool/branding/launcher_background.png             adaptive icon background:
#                                                     the icon's own gradient
#   tool/branding/launcher_monochrome.png             themed icon: the mark,
#                                                     shadow removed
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

$icon = Open-Png 'reelish_icon.png'
$primary = Open-Png 'Primary_logo.png'
$word = Open-Png 'word_logo.png'

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

# --- Themed (monochrome) icon layer: the mark's white pixels only. Android
# tints a monochrome layer by its alpha, so the mark's soft drop shadow would
# otherwise show as a blurred halo.
$mark = Open-Png 'logo_icon.png'
$mono = New-Object System.Drawing.Bitmap($mark.Width, $mark.Height,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$rect = New-Object System.Drawing.Rectangle(0, 0, $mark.Width, $mark.Height)
$source = $mark.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$pixels = New-Object byte[] ($source.Stride * $mark.Height)
[System.Runtime.InteropServices.Marshal]::Copy($source.Scan0, $pixels, 0, $pixels.Length)
$mark.UnlockBits($source)
for ($i = 0; $i -lt $pixels.Length; $i += 4) {
  # BGRA. White mark pixels are bright; the shadow is dark.
  $bright = [Math]::Min([Math]::Min($pixels[$i], $pixels[$i + 1]), $pixels[$i + 2])
  $alpha = [int]($pixels[$i + 3] * [Math]::Max(0, ($bright - 160)) / 95)
  $pixels[$i] = 255; $pixels[$i + 1] = 255; $pixels[$i + 2] = 255
  $pixels[$i + 3] = [Byte][Math]::Min(255, $alpha)
}
$target = $mono.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
[System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $target.Scan0, $pixels.Length)
$mono.UnlockBits($target)
$mono.Save((Join-Path $PSScriptRoot 'launcher_monochrome.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$mono.Dispose(); $mark.Dispose()

# --- Android splash logo: the primary logo, unchanged.
Copy-Item (Join-Path $icons 'Primary_logo.png') (Join-Path $res 'drawable-nodpi\reelish_splash.png') -Force

# --- Android TV banner (320 x 180 at xhdpi): the app icon and the wordmark
# on the app's dark background with a soft coral glow, as before.
$canvas = New-Canvas 320 180
$banner, $g = $canvas
$g.Clear([System.Drawing.Color]::FromArgb(255, 11, 11, 15))
$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
$glow.AddEllipse(-110, -80, 380, 340)
$glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
$glowBrush.CenterPoint = New-Object System.Drawing.PointF(72, 90)
$glowBrush.CenterColor = [System.Drawing.Color]::FromArgb(70, 255, 77, 109)
$glowBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 255, 77, 109))
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
