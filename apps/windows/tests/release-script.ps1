param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('kage-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$candidate = Join-Path $fixture 'Kage.exe'
Copy-Item -LiteralPath $Executable -Destination $candidate
$global:KageReleaseFixtureTagCommit = 'a' * 40
$global:KageReleaseFixtureArguments = $null
function global:gh {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'api') {
        if ($args[1] -ne 'repos/fixture/kage/git/ref/tags/windows-agent-777') { throw 'Wrong release tag lookup.' }
        return $global:KageReleaseFixtureTagCommit
    }
    if ($args[0] -eq 'release' -and $args[1] -eq 'create') {
        $global:KageReleaseFixtureArguments = @($args)
        return
    }
    throw 'Unexpected GitHub operation.'
}
try {
    $publisher = Join-Path $PSScriptRoot '../scripts/publish-github-release.ps1'
    & $publisher -Executable $candidate -Repository fixture/kage -Commit ('a' * 40) -BuildId 777 -Attempt 2
    if ($global:KageReleaseFixtureArguments -notcontains '--verify-tag' -or $global:KageReleaseFixtureArguments -contains '--target' -or
        $global:KageReleaseFixtureArguments[2] -ne 'windows-agent-777') { throw 'Release must verify its reserved tag and preserve the original build identity on retries.' }
    $manifest = Get-Content -LiteralPath (Join-Path $fixture 'agent-update.json') -Raw | ConvertFrom-Json
    if ($manifest.commit -ne ('a' * 40) -or $manifest.tag -ne 'windows-agent-777' -or
        $manifest.sha256 -ne (Get-FileHash -LiteralPath $candidate).Hash.ToLowerInvariant()) { throw 'Manifest is not bound to the verified artifact and commit.' }
    $global:KageReleaseFixtureTagCommit = 'b' * 40
    $global:KageReleaseFixtureArguments = $null
    $rejected = $false
    try { & $publisher -Executable $candidate -Repository fixture/kage -Commit ('a' * 40) -BuildId 777 }
    catch {
        if ($_.Exception.Message -notlike '*another commit*') { throw }
        $rejected = $true
    }
    if (!$rejected -or $null -ne $global:KageReleaseFixtureArguments) { throw 'Mismatched source tag reached publication.' }
    Write-Output 'PASS: stable build tag across retries, verified source commit, artifact manifest, and rejection before publishing mismatched tags.'
} finally {
    Remove-Item Function:/gh -ErrorAction SilentlyContinue
    Remove-Variable KageReleaseFixtureTagCommit,KageReleaseFixtureArguments -Scope Global -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($fixture)
    $prefix = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'kage-release-'))
    if (!$resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe release fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
