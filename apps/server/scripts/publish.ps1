$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $appRoot '../..'))
$destination = Join-Path $repoRoot 'dist/server'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$previousGOOS = $env:GOOS
$previousGOARCH = $env:GOARCH
$previousCGO = $env:CGO_ENABLED
Push-Location $appRoot
try {
    $env:GOOS = 'linux'
    $env:GOARCH = 'amd64'
    $env:CGO_ENABLED = '0'
    $output = Join-Path $destination 'hako-server-linux-amd64'
    & go build -trimpath -ldflags '-s -w' -o $output ./cmd/hako-server
    if ($LASTEXITCODE -ne 0) { throw "Publish failed: $LASTEXITCODE" }
    Write-Host "Published: $output"
}
finally {
    Pop-Location
    $env:GOOS = $previousGOOS
    $env:GOARCH = $previousGOARCH
    $env:CGO_ENABLED = $previousCGO
}
