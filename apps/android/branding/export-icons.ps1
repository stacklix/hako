param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$appRoot = Split-Path $PSScriptRoot -Parent
$resRoot = Join-Path $appRoot 'android/app/src/main/res'
$androidNs = 'http://schemas.android.com/apk/res/android'
[xml]$foreground = Get-Content -Raw (Join-Path $resRoot 'drawable/ic_launcher_foreground.xml')
[xml]$background = Get-Content -Raw (Join-Path $resRoot 'drawable/ic_launcher_background.xml')
$backgroundColor = [Drawing.ColorTranslator]::FromHtml($background.color.GetAttribute('color', $androidNs))

# Render the same M/L/C/Z paths used by VectorDrawable, without extra dependencies.
function New-VectorPath([string]$data) {
    $path = [Drawing.Drawing2D.GraphicsPath]::new([Drawing.Drawing2D.FillMode]::Alternate)
    $tokens = [regex]::Matches($data, '[MLCZ]|-?\d+(?:\.\d+)?')
    $index = 0
    $x = 0.0; $y = 0.0
    while ($index -lt $tokens.Count) {
        $command = $tokens[$index++].Value
        switch ($command) {
            'M' {
                $x = [single]::Parse($tokens[$index++].Value, [Globalization.CultureInfo]::InvariantCulture)
                $y = [single]::Parse($tokens[$index++].Value, [Globalization.CultureInfo]::InvariantCulture)
                $path.StartFigure()
            }
            'L' {
                $nextX = [single]::Parse($tokens[$index++].Value, [Globalization.CultureInfo]::InvariantCulture)
                $nextY = [single]::Parse($tokens[$index++].Value, [Globalization.CultureInfo]::InvariantCulture)
                $path.AddLine([single]$x, [single]$y, $nextX, $nextY)
                $x = $nextX; $y = $nextY
            }
            'C' {
                $points = @()
                for ($j = 0; $j -lt 6; $j++) {
                    $points += [single]::Parse($tokens[$index++].Value, [Globalization.CultureInfo]::InvariantCulture)
                }
                $path.AddBezier([single]$x, [single]$y, $points[0], $points[1], $points[2], $points[3], $points[4], $points[5])
                $x = $points[4]; $y = $points[5]
            }
            'Z' { $path.CloseFigure() }
            default { throw "Unsupported path command: $command" }
        }
    }
    return ,$path
}

function Export-Icon([string]$destination, [int]$size) {
    $large = [Drawing.Bitmap]::new($size * 4, $size * 4)
    $graphics = [Drawing.Graphics]::FromImage($large)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear($backgroundColor)
    $graphics.ScaleTransform([single]($size * 4 / 72), [single]($size * 4 / 72))
    $graphics.TranslateTransform(-18, -18)
    $graphics.TranslateTransform(54, 54)
    $graphics.ScaleTransform([single]0.9, [single]0.9)
    $graphics.TranslateTransform(-54, -54)
    foreach ($node in $foreground.vector.group.path) {
        $path = New-VectorPath $node.GetAttribute('pathData', $androidNs)
        $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($node.GetAttribute('fillColor', $androidNs)))
        $graphics.FillPath($brush, $path)
        $brush.Dispose(); $path.Dispose()
    }
    $graphics.Dispose()
    $small = [Drawing.Bitmap]::new($size, $size)
    $scaler = [Drawing.Graphics]::FromImage($small)
    $scaler.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
    $scaler.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scaler.DrawImage($large, 0, 0, $size, $size)
    $small.Save($destination, [Drawing.Imaging.ImageFormat]::Png)
    $scaler.Dispose(); $small.Dispose(); $large.Dispose()
}

foreach ($entry in @{'mdpi'=48; 'hdpi'=72; 'xhdpi'=96; 'xxhdpi'=144; 'xxxhdpi'=192}.GetEnumerator()) {
    Export-Icon (Join-Path $resRoot "mipmap-$($entry.Key)/ic_launcher.png") $entry.Value
}
Export-Icon (Join-Path $PSScriptRoot 'nami.png') 1024
Write-Output 'Exported Nami master PNG and five launcher densities.'
