param(
    [Parameter(Mandatory)][string]$JavaHome,
    [Parameter(Mandatory)][string]$AndroidSdk,
    [string]$Platform = 'android-36',
    [string]$BuildTools = '36.0.0'
)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$work = Join-Path $appRoot ('build/legacy-video-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$work/classes", "$work/dex" -Force | Out-Null
$androidJar = Join-Path $AndroidSdk "platforms/$Platform/android.jar"
& "$JavaHome/bin/javac.exe" --release 8 -classpath $androidJar -d "$work/classes" (Join-Path $appRoot 'android-video/src/me/stackli/hako/LegacyVideoServer.java')
if ($LASTEXITCODE -ne 0) { throw 'Legacy video Java compilation failed.' }
$classes = @(Get-ChildItem "$work/classes" -Recurse -Filter '*.class' | ForEach-Object FullName)
& "$JavaHome/bin/java.exe" -cp "$AndroidSdk/build-tools/$BuildTools/lib/d8.jar" com.android.tools.r8.D8 --min-api 19 --lib $androidJar --output "$work/dex" @classes
if ($LASTEXITCODE -ne 0) { throw 'Legacy video DEX compilation failed.' }
# A fixed entry timestamp makes the embedded, source-built resource reproducible.
Add-Type -AssemblyName System.IO.Compression
$output = Join-Path $appRoot 'src/Hako/Assets/hako-video-api19.jar'
$file = [IO.File]::Open($output, 'Create')
try {
    $zip = [IO.Compression.ZipArchive]::new($file, 'Create', $true)
    try {
        $entry = $zip.CreateEntry('classes.dex')
        $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $stream = $entry.Open()
        try { $bytes = [IO.File]::ReadAllBytes("$work/dex/classes.dex"); $stream.Write($bytes) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
} finally { $file.Dispose() }
Get-FileHash -LiteralPath $output -Algorithm SHA256
