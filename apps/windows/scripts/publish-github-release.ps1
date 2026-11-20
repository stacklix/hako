param([Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$Commit,[Parameter(Mandatory=$true)][long]$BuildId,[int]$Attempt=1)
$ErrorActionPreference='Stop'
$file=Get-Item -LiteralPath $Executable
$version=$file.VersionInfo.ProductVersion.Split('+')[0]
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid Agent release version.' }
$tag="windows-agent-$BuildId"
$tagCommit = & gh api "repos/$Repository/git/ref/tags/$tag" --jq '.object.sha'
if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $Commit) { throw 'Release source tag is missing or points to another commit.' }
$manifest=Join-Path $file.DirectoryName 'agent-update.json'
@{schema=1;tag=$tag;version=$version;buildId=$BuildId;commit=$Commit;sha256=(Get-FileHash $file.FullName).Hash.ToLowerInvariant();size=$file.Length;publishedAt=[DateTimeOffset]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
& gh release create $tag $file.FullName $manifest --repo $Repository --verify-tag --title "Kage $version · build $BuildId.$Attempt" --notes "Verified Kage build. Source: $Commit. Workflow: https://github.com/$Repository/actions/runs/$BuildId" --latest=false
if ($LASTEXITCODE -ne 0) { throw 'GitHub Agent release publication failed.' }
