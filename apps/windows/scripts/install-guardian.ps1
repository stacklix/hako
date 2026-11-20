#requires -Version 7.0
param(
    [string]$Executable = (Join-Path $PSScriptRoot '../../../dist/windows/Kage.exe'),
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/Kage'),
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'Kage'),
    [string]$Repository = 'stacklix/hako',
    [switch]$NoStartup
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $Executable).Path
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$DataDirectory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($DataDirectory))
$root = Join-Path $DataDirectory 'guardian'
$destination = Join-Path $InstallDirectory 'guardian/Kage.Guardian.exe'
$configuration = Join-Path $root 'config.json'
if ($env:KAGE_COMMAND_TASK_DIRECTORY -and $env:KAGE_COMMAND_EXECUTABLE -and
    [string]::Equals([IO.Path]::GetFullPath($env:KAGE_COMMAND_EXECUTABLE), $destination, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run the guardian installer from an independent terminal or updater. A guardian command cannot wait for its own host to exit.'
}
New-Item -ItemType Directory -Path $root,(Split-Path -Parent $destination) -Force | Out-Null
$lock = [IO.File]::Open((Join-Path $root 'install.lock'),'OpenOrCreate','ReadWrite','None')
try {
    $statusPath=Join-Path $root 'status.json'
    if ((Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $configuration) -and (Test-Path -LiteralPath $statusPath)) {
        $status=Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
        $old=Get-Process -Id $status.processId -ErrorAction SilentlyContinue
        if ($old) {
            if ($old.Path -ne $destination) { throw 'Guardian PID belongs to another executable.' }
            & $destination --stop-guardian --config $configuration
            if ($LASTEXITCODE -ne 0) { throw 'Guardian did not accept the graceful stop request.' }
            Write-Host 'Waiting for running commands and any Agent update to finish before replacing the guardian...'
            $old.WaitForExit()
            $old.Dispose()
        }
    }
    $temporary = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Copy-Item -LiteralPath $source -Destination $temporary
        if ((Get-FileHash $temporary).Hash -ne (Get-FileHash $source).Hash) { throw 'Guardian artifact changed while staging.' }
        [IO.File]::Move($temporary,$destination,$true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    $options=@{targetPath=(Join-Path $InstallDirectory 'Kage.exe');profileDirectory=$DataDirectory;repository=$Repository;pollSeconds=5;updatePollSeconds=300;restartDelaySeconds=30}
    $temporary=$configuration+'.tmp'
    [IO.File]::WriteAllText($temporary,($options | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$configuration,$true)
    $installedStamp=Join-Path $root 'installed.json'
    $installedTarget=Join-Path $InstallDirectory 'Kage.exe'
    if (!(Test-Path -LiteralPath $installedStamp) -and (Test-Path -LiteralPath $installedTarget)) {
        $stamp=@{sha256=(Get-FileHash -LiteralPath $installedTarget).Hash.ToLowerInvariant();installedAt=(Get-Item -LiteralPath $installedTarget).LastWriteTimeUtc.ToString('o')}
        $temporary=$installedStamp+'.tmp'
        [IO.File]::WriteAllText($temporary,($stamp | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$installedStamp,$true)
    }
    if (!$NoStartup) {
        $startup=[Environment]::GetFolderPath('Startup')
        $profileHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($DataDirectory.ToUpperInvariant()))).Substring(0,12)
        $suffix=if($DataDirectory -eq (Join-Path $env:LOCALAPPDATA 'Kage')){''}else{'-'+$profileHash}
        $shell=New-Object -ComObject WScript.Shell
        try {
            $shortcut=$shell.CreateShortcut((Join-Path $startup ('Kage Agent'+$suffix+'.lnk')))
            $shortcut.TargetPath=$destination
            $shortcut.Arguments='--guardian --config "'+$configuration+'"'
            $shortcut.WorkingDirectory=Split-Path -Parent $destination
            $shortcut.Description='Kage Agent 更新与异常退出守护'
            $shortcut.Save()
        } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    }
    $reply=(& $destination --start-guardian --config $configuration | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or !$reply.ok) { throw 'Independent guardian startup failed.' }
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $state=if(Test-Path -LiteralPath $statusPath){Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json}else{$null}
    } until (($state -and $state.processId -eq $reply.data.processId) -or [DateTime]::UtcNow -gt $deadline)
    if (!$state -or $state.processId -ne $reply.data.processId) { throw 'Guardian did not publish its own status.' }
    [pscustomobject]@{status='running';processId=$state.processId;executable=$destination;configuration=$configuration;startupEnabled=(!$NoStartup);mainAgentUnchanged=$true} | ConvertTo-Json
} finally { $lock.Dispose() }
