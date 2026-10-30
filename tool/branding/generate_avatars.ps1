# Prepares the profile avatar presets from assets/avatars/Avatars (N).png:
#
#   powershell -ExecutionPolicy Bypass -File tool/branding/generate_avatars.ps1
#
# Each source is a round illustration on a transparent canvas with uneven
# margins. This crops it to its visible pixels, centres that on a square
# and writes assets/avatars/avatar_N.png at 256 x 256, the files the app
# bundles (lib/src/account/profile_controller.dart, AvatarPreset).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$dir = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'assets\avatars'
$size = 256

foreach ($n in 1..8) {
  $path = Join-Path $dir "Avatars ($n).png"
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $source = [System.Drawing.Bitmap]::FromStream((New-Object System.IO.MemoryStream(, $bytes)))

  # Bounds of the visible pixels.
  $rect = New-Object System.Drawing.Rectangle(0, 0, $source.Width, $source.Height)
  $data = $source.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $pixels = New-Object byte[] ($data.Stride * $source.Height)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
  $source.UnlockBits($data)
  $minX = $source.Width; $minY = $source.Height; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $source.Height; $y++) {
    $row = $y * $data.Stride
    for ($x = 0; $x -lt $source.Width; $x++) {
      if ($pixels[$row + $x * 4 + 3] -gt 24) {
        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  $w = $maxX - $minX + 1; $h = $maxY - $minY + 1
  $side = [Math]::Max($w, $h)

  $out = New-Object System.Drawing.Bitmap($size, $size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $scale = $size / $side
  $dest = New-Object System.Drawing.RectangleF(
    (($side - $w) / 2 * $scale), (($side - $h) / 2 * $scale), ($w * $scale), ($h * $scale))
  $g.DrawImage($source, $dest,
    (New-Object System.Drawing.RectangleF($minX, $minY, $w, $h)),
    [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose()
  $out.Save((Join-Path $dir "avatar_$n.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $out.Dispose(); $source.Dispose()
  Write-Output "avatar_$n.png from ${w}x${h}"
}
