param([switch]$NoRestore)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot '../..'))
$buildRoot = Join-Path $appRoot 'build'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$buildRoot = (Resolve-Path -LiteralPath $buildRoot).Path
$staging = Join-Path $buildRoot ('single-file-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
$staging = (Resolve-Path -LiteralPath $staging).Path
if (-not $staging.StartsWith($buildRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Staging directory must stay within the application build directory.'
}

try {
    $publishArguments = @('publish', (Join-Path $appRoot 'src/Hako/Hako.csproj'), '-c', 'Release', '-p:PublishProfile=Standalone', '-o', $staging)
    if ($NoRestore) { $publishArguments += '--no-restore' }
    & dotnet @publishArguments
    if ($LASTEXITCODE -ne 0) { throw "Publish failed: $LASTEXITCODE" }
    $items = @(Get-ChildItem -LiteralPath $staging -Force)
    if ($items.Count -ne 1 -or $items[0].Name -ne 'Hako.exe' -or $items[0].PSIsContainer) {
        throw 'Standalone publication must produce exactly one Hako.exe.'
    }
    $destination = Join-Path $repoRoot 'dist/windows'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $items[0].FullName -Destination (Join-Path $destination 'Hako.exe') -Force
    Write-Host "Published: $(Join-Path $destination 'Hako.exe')"
}
finally {
    $resolvedStaging = (Resolve-Path -LiteralPath $staging).Path
    if (-not $resolvedStaging.StartsWith($buildRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a staging directory outside the application build directory.'
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}
