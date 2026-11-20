# Builds the Reelish brand sources from the emblem, the logo since v1.39:
#
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_emblem_sources.ps1
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_brand_assets.ps1
#   dart run flutter_launcher_icons
#
# Source: assets/icons/reelish_app_emblem.png (846 x 846 RGBA): the terracotta
# beam between three cream and three sand squares, with soft shadows. Its
# colours are the palette: terracotta #BA725A, sand #CAA76C, cream #F4F0E5.
# The wordmark is the existing one (word_logo.png), its coral "ISH" redrawn in
# terracotta.
#
# Writes (846 x 846 RGBA unless noted):
#   assets/icons/reelish_wordmark.png      the wordmark, "ISH" in terracotta
#   assets/icons/reelish_emblem_icon.png   the app icon: the emblem on a warm
#                                          charcoal tile
#   assets/icons/reelish_primary_logo.png  the emblem over the wordmark, for
#                                          splashes
#   tool/branding/launcher_foreground.png  adaptive icon foreground: the
#                                          emblem at the tile's share
#   tool/branding/launcher_monochrome.png  themed icon: the emblem's shapes,
#                                          white, shadows removed
#   assets/icons/reelish_emblem_white.png  the emblem in white with its soft
#                                          shadows, placed as the foreground:
#                                          the mark on colour tiles
#   tool/branding/emblem_clean.png         the emblem's shapes, white, in its
#                                          own canvas: Sovereign Crest's mask
# and prints each image's artwork bounds for BrandAssets.
#
# Uses only System.Drawing, which ships with Windows.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$icons = Join-Path $root 'assets\icons'
$canvasSize = 846

# The emblem's solid shapes inside its canvas (measured from alpha); the soft
# shadows fall a little outside.
$emblemShapes = New-Object System.Drawing.Rectangle(78, 132, 689, 581)
# The wordmark's letters inside word_logo.png.
$wordShapes = New-Object System.Drawing.Rectangle(184, 394, 480, 58)

function Open-Png([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $stream = New-Object System.IO.MemoryStream(, $bytes)
  return [System.Drawing.Bitmap]::FromStream($stream)
}

function New-Canvas([int]$size) {
  $bitmap = New-Object System.Drawing.Bitmap($size, $size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  return @($bitmap, $graphics)
}

function Get-Pixels([System.Drawing.Bitmap]$bitmap) {
  $rect = New-Object System.Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
  $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $pixels = New-Object byte[] ($data.Stride * $bitmap.Height)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
  $bitmap.UnlockBits($data)
  return , $pixels
}

function Set-Pixels([System.Drawing.Bitmap]$bitmap, [byte[]]$pixels) {
  $rect = New-Object System.Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
  $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length)
  $bitmap.UnlockBits($data)
}

# Draws the emblem so its shapes are $width wide, centred on ($cx, $cy).
function Add-Emblem($g, $emblem, [double]$width, [double]$cx, [double]$cy) {
  $scale = $width / $emblemShapes.Width
  $x = $cx - ($emblemShapes.X + $emblemShapes.Width / 2) * $scale
  $y = $cy - ($emblemShapes.Y + $emblemShapes.Height / 2) * $scale
  $g.DrawImage($emblem, (New-Object System.Drawing.RectangleF($x, $y,
    ($canvasSize * $scale), ($canvasSize * $scale))))
}

# Prints where an image's visible artwork sits, as fractions of its canvas.
function Write-Bounds([string]$name, [System.Drawing.Bitmap]$bitmap) {
  $pixels = Get-Pixels $bitmap
  $w = $bitmap.Width
  $minX = $w; $minY = $w; $maxX = 0; $maxY = 0
  for ($i = 0; $i -lt $pixels.Length; $i += 4) {
    if ($pixels[$i + 3] -lt 24) { continue }
    $p = $i / 4; $x = $p % $w; $y = [Math]::Floor($p / $w)
    if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
    if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
  }
  '{0}: Rect.fromLTRB({1:0.000}, {2:0.000}, {3:0.000}, {4:0.000})' -f $name,
    ($minX / $w), ($minY / $w), (($maxX + 1) / $w), (($maxY + 1) / $w)
}

$emblem = Open-Png (Join-Path $icons 'reelish_app_emblem.png')
$word = Open-Png (Join-Path $icons 'word_logo.png')

# --- The wordmark, "ISH" in terracotta. Coral pixels (red well above green)
# take terracotta at their own brightness and alpha; white and the soft grey
# shadows stay as they are.
$pixels = Get-Pixels $word
for ($i = 0; $i -lt $pixels.Length; $i += 4) {
  $b = $pixels[$i]; $gr = $pixels[$i + 1]; $r = $pixels[$i + 2]
  if ($pixels[$i + 3] -eq 0 -or ($r - $gr) -lt 60) { continue }
  $shade = $r / 255.0
  $pixels[$i] = [byte][Math]::Round(0x5A * $shade)
  $pixels[$i + 1] = [byte][Math]::Round(0x72 * $shade)
  $pixels[$i + 2] = [byte][Math]::Round(0xBA * $shade)
}
$wordmark = New-Object System.Drawing.Bitmap($word.Width, $word.Height,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
Set-Pixels $wordmark $pixels
$wordmark.Save((Join-Path $icons 'reelish_wordmark.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Bounds 'wordLogoBounds' $wordmark

# --- The app icon: a warm charcoal tile, with the corners of the coral icon
# it follows (radius 104 of 846), a faint terracotta light from the top, and
# the emblem at 56% of the tile's width.
$canvas = New-Canvas $canvasSize
$tile, $g = $canvas
$radius = 104
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$d = $radius * 2; $s = $canvasSize - 1
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($s - $d, 0, $d, $d, 270, 90)
$path.AddArc($s - $d, $s - $d, $d, $d, 0, 90)
$path.AddArc(0, $s - $d, $d, $d, 90, 90)
$path.CloseFigure()
$fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, $canvasSize)),
  [System.Drawing.Color]::FromArgb(255, 0x2E, 0x25, 0x20),
  [System.Drawing.Color]::FromArgb(255, 0x16, 0x12, 0x0F))
$g.FillPath($fill, $path)
$fill.Dispose()
$g.SetClip($path)
$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
$glow.AddEllipse(-200, -520, 1246, 980)
$glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
$glowBrush.CenterColor = [System.Drawing.Color]::FromArgb(46, 0xBA, 0x72, 0x5A)
$glowBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 0xBA, 0x72, 0x5A))
$g.FillPath($glowBrush, $glow)
$glowBrush.Dispose(); $glow.Dispose()
$g.ResetClip()
$share = .56
Add-Emblem $g $emblem ($canvasSize * $share) ($canvasSize / 2) ($canvasSize / 2)
$g.Dispose(); $path.Dispose()
$tile.Save((Join-Path $icons 'reelish_emblem_icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$tile.Dispose()

# --- Adaptive foreground: the emblem alone at the same share, so adaptive and
# legacy launchers show it at one size (pubspec.yaml adds a 20% inset, as
# for the coral icon).
$canvas = New-Canvas $canvasSize
$foreground, $g = $canvas
Add-Emblem $g $emblem ($canvasSize * $share) ($canvasSize / 2) ($canvasSize / 2)
$g.Dispose()
$foreground.Save((Join-Path $PSScriptRoot 'launcher_foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Bounds 'logoIconBounds (foreground)' $foreground

# --- Themed (monochrome) layer: the shapes in white, by their own alpha.
# The shadows are dark, so brightness tells them apart: Android tints a
# monochrome layer by alpha, and a shadow would show as a halo.
$pixels = Get-Pixels $foreground
for ($i = 0; $i -lt $pixels.Length; $i += 4) {
  $bright = [Math]::Max([Math]::Max($pixels[$i], $pixels[$i + 1]), $pixels[$i + 2])
  $alpha = [int]($pixels[$i + 3] * [Math]::Min(1, [Math]::Max(0, ($bright - 70) / 60.0)))
  $pixels[$i] = 255; $pixels[$i + 1] = 255; $pixels[$i + 2] = 255
  $pixels[$i + 3] = [byte]$alpha
}
$mono = New-Object System.Drawing.Bitmap($canvasSize, $canvasSize,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
Set-Pixels $mono $pixels
$mono.Save((Join-Path $PSScriptRoot 'launcher_monochrome.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$mono.Dispose()

# --- The white emblem, for colour tiles (the icon presets, the Signature icons
# and custom accent tiles): the shapes turn white and the soft shadows stay,
# as the white R sat on them before. Same placement as the foreground.
$pixels = Get-Pixels $foreground
for ($i = 0; $i -lt $pixels.Length; $i += 4) {
  $bright = [Math]::Max([Math]::Max($pixels[$i], $pixels[$i + 1]), $pixels[$i + 2])
  $t = [Math]::Min(1, [Math]::Max(0, ($bright - 70) / 60.0))
  for ($c = 0; $c -lt 3; $c++) {
    $pixels[$i + $c] = [byte][Math]::Round($pixels[$i + $c] + (255 - $pixels[$i + $c]) * $t)
  }
}
$white = New-Object System.Drawing.Bitmap($canvasSize, $canvasSize,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
Set-Pixels $white $pixels
$white.Save((Join-Path $icons 'reelish_emblem_white.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Bounds 'whiteEmblemBounds' $white
$white.Dispose(); $foreground.Dispose()

# --- The emblem's shapes alone, white, in the emblem's own canvas: the mask
# Sovereign Crest fills with champagne gold (generate_sovereign_crest.mjs).
$pixels = Get-Pixels $emblem
for ($i = 0; $i -lt $pixels.Length; $i += 4) {
  $bright = [Math]::Max([Math]::Max($pixels[$i], $pixels[$i + 1]), $pixels[$i + 2])
  $alpha = [int]($pixels[$i + 3] * [Math]::Min(1, [Math]::Max(0, ($bright - 70) / 60.0)))
  $pixels[$i] = 255; $pixels[$i + 1] = 255; $pixels[$i + 2] = 255
  $pixels[$i + 3] = [byte]$alpha
}
$clean = New-Object System.Drawing.Bitmap($canvasSize, $canvasSize,
  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
Set-Pixels $clean $pixels
$clean.Save((Join-Path $PSScriptRoot 'emblem_clean.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$clean.Dispose()

# --- Primary logo: the emblem over the wordmark, centred together on the
# canvas, at the share the coral primary logo had (about 61% wide).
$canvas = New-Canvas $canvasSize
$primary, $g = $canvas
$emblemWidth = 430.0
$emblemHeight = $emblemWidth * $emblemShapes.Height / $emblemShapes.Width
$wordWidth = 500.0
$wordHeight = $wordWidth * $wordShapes.Height / $wordShapes.Width
$gap = 64.0
$top = ($canvasSize - ($emblemHeight + $gap + $wordHeight)) / 2
Add-Emblem $g $emblem $emblemWidth ($canvasSize / 2) ($top + $emblemHeight / 2)
$g.DrawImage($wordmark,
  (New-Object System.Drawing.RectangleF((($canvasSize - $wordWidth) / 2),
    ($top + $emblemHeight + $gap), $wordWidth, $wordHeight)),
  (New-Object System.Drawing.RectangleF($wordShapes.X, $wordShapes.Y,
    $wordShapes.Width, $wordShapes.Height)),
  [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$primary.Save((Join-Path $icons 'reelish_primary_logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Write-Bounds 'primaryLogoBounds' $primary
$primary.Dispose()

Write-Bounds 'emblemBounds (reelish_app_emblem.png)' $emblem
$wordmark.Dispose(); $word.Dispose(); $emblem.Dispose()
Write-Output 'Emblem sources written.'
