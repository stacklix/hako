param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
[xml]$source = Get-Content -Raw (Join-Path $PSScriptRoot 'kage.svg')
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$assetDirectory = Join-Path $PSScriptRoot '../src/Hako/Assets'
New-Item -ItemType Directory -Force -Path $assetDirectory | Out-Null

function Render-Logo([int]$size) {
    $bitmap = [Drawing.Bitmap]::new($size * 4, $size * 4)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $g.ScaleTransform([single]($size * 4 / 256), [single]($size * 4 / 256))
    $background = [Drawing.Drawing2D.GraphicsPath]::new()
    $background.AddArc(0, 0, 112, 112, 180, 90)
    $background.AddArc(144, 0, 112, 112, 270, 90)
    $background.AddArc(144, 144, 112, 112, 0, 90)
    $background.AddArc(0, 144, 112, 112, 90, 90)
    $background.CloseFigure()
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($source.svg.rect.fill))
    $g.FillPath($brush, $background)
    $brush.Dispose(); $background.Dispose()
    foreach ($node in $source.svg.path) {
        $numbers = [regex]::Matches($node.d, '-?\d+(?:\.\d+)?')
        $points = [Collections.Generic.List[Drawing.PointF]]::new()
        for ($index = 0; $index -lt $numbers.Count; $index += 2) {
            $points.Add([Drawing.PointF]::new([single]$numbers[$index].Value, [single]$numbers[$index + 1].Value))
        }
        $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($node.fill))
        $g.FillPolygon($brush, $points.ToArray())
        $brush.Dispose()
    }
    $g.Dispose()
    $result = [Drawing.Bitmap]::new($size, $size)
    $scaler = [Drawing.Graphics]::FromImage($result)
    $scaler.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scaler.DrawImage($bitmap, 0, 0, $size, $size)
    $scaler.Dispose(); $bitmap.Dispose()
    return ,$result
}

$frames = @()
foreach ($size in $sizes) {
    $bitmap = Render-Logo $size
    $buffer = [IO.MemoryStream]::new()
    $bitmap.Save($buffer, [Drawing.Imaging.ImageFormat]::Png)
    $frames += ,$buffer.ToArray()
    $buffer.Dispose(); $bitmap.Dispose()
}
$output = [IO.File]::Create((Join-Path $assetDirectory 'Kage.ico'))
$writer = [IO.BinaryWriter]::new($output)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame) }
} finally { $writer.Dispose(); $output.Dispose() }
$master = Render-Logo 1024
$master.Save((Join-Path $PSScriptRoot 'kage.png'), [Drawing.Imaging.ImageFormat]::Png)
$master.Dispose()
Write-Output 'Exported Kage PNG and nine ICO sizes.'
