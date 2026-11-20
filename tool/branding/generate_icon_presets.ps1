# Generates the launcher icon presets (Settings > Appearance > App icon):
# each colour's own background with the white Reelish emblem on it.
#
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_emblem_sources.ps1
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_icon_presets.ps1
#
# Sources (assets/icons/, 846 x 846 RGBA):
#   app_icon_<id>.png        one per colour (app_logo_amber.png for amber;
#                            reelish_icon.png for coral): only their vertical
#                            gradient is used, sampled from a column clear of
#                            the R mark they were drawn with
#   reelish_emblem_white.png the white emblem with its soft shadows, placed
#                            as the launcher foreground
#   reelish_emblem_icon.png  the default icon, for its preview only (its
#                            resources come from generate_brand_assets.ps1
#                            and flutter_launcher_icons and are not touched
#                            here)
#
# Writes the shared mark layers, used by these presets and the Signature
# icons (generate_signature_icons.mjs):
#   android/app/src/main/res/drawable-<density>/ic_launcher_foreground_mark.png
#       the white emblem, 108 dp
#   android/app/src/main/res/drawable-<density>/ic_launcher_monochrome_mark.png
#       its themed (monochrome) layer: the default icon's
# and, per preset:
#   android/app/src/main/res/drawable-nodpi/ic_launcher_background_<id>.png
#       adaptive icon background: the colour's gradient
#   android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_<id>.xml
#       adaptive icon: that background with the mark layers
#   android/app/src/main/res/mipmap-<density>/ic_launcher_<id>.png
#       the whole tile, for launchers without adaptive icons (Android 7)
#   assets/images/app_icons/<id>.png
#       a 192 px preview for the settings screen (also default.png)
#
# The activity aliases that use these are declared in AndroidManifest.xml
# and listed in AppIconSwitcher.kt and lib/src/platform/app_icon.dart.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$icons = Join-Path $root 'assets\icons'
$res = Join-Path $root 'android\app\src\main\res'
$previews = Join-Path $root 'assets\images\app_icons'
New-Item -ItemType Directory -Force $previews | Out-Null

$presets = [ordered]@{
  # Coral, the colour of the original icon: free, as the default was.
  coral = 'reelish_icon.png'
  amber = 'app_logo_amber.png'
  blue = 'app_icon_blue.png'
  green = 'app_icon_green.png'
  indigo = 'app_icon_indigo.png'
  lime = 'app_icon_lime.png'
  orange = 'app_icon_orange.png'
  rose = 'app_icon_rose.png'
  slate = 'app_icon_slate.png'
  teal = 'app_icon_teal.png'
  violet = 'app_icon_violet.png'
}
$densities = [ordered]@{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
$layerSizes = [ordered]@{ mdpi = 108; hdpi = 162; xhdpi = 216; xxhdpi = 324; xxxhdpi = 432 }
$tileSize = 846
# The corners of the original icon tiles (radius 104 of 846).
$tileRadius = 104

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

function Save-Scaled([System.Drawing.Bitmap]$source, [int]$size, [string]$path) {
  $canvas = New-Canvas $size
  $bitmap, $g = $canvas
  $g.DrawImage($source, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)))
  $g.Dispose()
  $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bitmap.Dispose()
}

# The colour of [tile]'s gradient at [y] of a [height]-tall image, from a
# column clear of the R and of the rounded corners.
function Get-GradientColor([System.Drawing.Bitmap]$tile, [int]$y, [int]$height) {
  $sourceY = [int](8 + $y * ($tile.Height - 17) / ($height - 1))
  $color = $tile.GetPixel(120, $sourceY)
  return [System.Drawing.Color]::FromArgb(255, $color.R, $color.G, $color.B)
}

$white = Open-Png (Join-Path $icons 'reelish_emblem_white.png')

# --- The shared mark layers.
foreach ($density in $layerSizes.Keys) {
  Save-Scaled $white $layerSizes[$density] (Join-Path $res "drawable-$density\ic_launcher_foreground_mark.png")
  Copy-Item (Join-Path $res "drawable-$density\ic_launcher_monochrome.png") `
    (Join-Path $res "drawable-$density\ic_launcher_monochrome_mark.png") -Force
}

$adaptive = @'
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by tool/branding/generate_icon_presets.ps1. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@drawable/ic_launcher_background_{0}"/>
  <foreground>
      <inset
          android:drawable="@drawable/ic_launcher_foreground_mark"
          android:inset="20%" />
  </foreground>
  <monochrome>
      <inset
          android:drawable="@drawable/ic_launcher_monochrome_mark"
          android:inset="20%" />
  </monochrome>
</adaptive-icon>
'@

foreach ($id in $presets.Keys) {
  $source = Open-Png (Join-Path $icons $presets[$id])

  # Adaptive background: the colour's vertical gradient.
  $size = 432
  $canvas = New-Canvas $size
  $background, $g = $canvas
  for ($y = 0; $y -lt $size; $y++) {
    $brush = New-Object System.Drawing.SolidBrush((Get-GradientColor $source $y $size))
    $g.FillRectangle($brush, 0, $y, $size, 1)
    $brush.Dispose()
  }
  $g.Dispose()
  $background.Save((Join-Path $res "drawable-nodpi\ic_launcher_background_$id.png"),
    [System.Drawing.Imaging.ImageFormat]::Png)
  $background.Dispose()

  [System.IO.File]::WriteAllText((Join-Path $res "mipmap-anydpi-v26\ic_launcher_$id.xml"),
    ($adaptive -f $id), (New-Object System.Text.UTF8Encoding($false)))

  # The whole tile: the gradient in the original tile's rounded square, and
  # the white emblem where the default icon has it.
  $canvas = New-Canvas $tileSize
  $tile, $g = $canvas
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $tileRadius * 2; $s = $tileSize - 1
  $path.AddArc(0, 0, $d, $d, 180, 90)
  $path.AddArc($s - $d, 0, $d, $d, 270, 90)
  $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90)
  $path.AddArc(0, $s - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $g.SetClip($path)
  for ($y = 0; $y -lt $tileSize; $y++) {
    $brush = New-Object System.Drawing.SolidBrush((Get-GradientColor $source $y $tileSize))
    $g.FillRectangle($brush, 0, $y, $tileSize, 1)
    $brush.Dispose()
  }
  $g.ResetClip()
  $g.DrawImage($white, (New-Object System.Drawing.Rectangle(0, 0, $tileSize, $tileSize)))
  $g.Dispose(); $path.Dispose()

  foreach ($density in $densities.Keys) {
    Save-Scaled $tile $densities[$density] (Join-Path $res "mipmap-$density\ic_launcher_$id.png")
  }
  Save-Scaled $tile 192 (Join-Path $previews "$id.png")
  $tile.Dispose(); $source.Dispose()
  Write-Output "preset $id"
}
$white.Dispose()

$default = Open-Png (Join-Path $icons 'reelish_emblem_icon.png')
Save-Scaled $default 192 (Join-Path $previews 'default.png')
$default.Dispose()
Write-Output 'preview default'
