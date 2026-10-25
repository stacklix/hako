param([Parameter(Mandatory = $true)][string]$Executable)

$ErrorActionPreference = 'Stop'
$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$appRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $appRoot ('build/cli-smoke-' + [Guid]::NewGuid().ToString('N'))
$profileDirectory = Join-Path $workRoot 'profile with spaces'
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$backgroundId = $null

function Invoke-HakoCheck {
    param([string[]]$Arguments, [int]$ExpectedExit = 0, [switch]$Text)
    $start = [System.Diagnostics.ProcessStartInfo]::new($executablePath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.ArgumentList.Add('--data-dir'); $start.ArgumentList.Add($profileDirectory)
    if (-not $Text) { $start.ArgumentList.Add('--json') }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(45000)) { $process.Kill($true); throw 'CLI did not exit within 45 seconds.' }
        $output = $outputTask.WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
        $errorOutput = $errorTask.WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
        if ($process.ExitCode -ne $ExpectedExit) { throw "Unexpected CLI exit $($process.ExitCode), expected $ExpectedExit. Output: $output $errorOutput" }
        if ($output -match 'BEGIN (RSA )?PRIVATE KEY') { throw 'Private key leaked through CLI output.' }
        if ($Text) { return $output }
        $reply = $output | ConvertFrom-Json
        if ($reply.exitCode -ne $ExpectedExit) { throw 'JSON exit code does not match process exit code.' }
        return $reply
    }
    finally { $process.Dispose() }
}

try {
    foreach ($helpArgs in @(@('help'), @('--help'), @('-h'), @('help','key'), @('config','set','--help'))) {
        $helpText = Invoke-HakoCheck -Arguments $helpArgs -Text
        if ($helpText -notmatch 'Hako Windows Agent') { throw 'Help did not reach stdout.' }
    }
    $helpJson = Invoke-HakoCheck -Arguments @('help')
    if ($helpJson.data.commands.Count -lt 10) { throw 'Structured help is incomplete.' }
    $invalid = Invoke-HakoCheck -Arguments @('unknown-command') -ExpectedExit 2
    if ($invalid.error.code -ne 'invalid_arguments') { throw 'Invalid command error is not structured.' }
    $initial = Invoke-HakoCheck -Arguments @('status')
    if ($initial.data.running) { throw 'Status started a background instance.' }
    $key = Invoke-HakoCheck -Arguments @('key','generate')
    if (-not $key.data.keyId) { throw 'Generated key has no fingerprint.' }
    $null = Invoke-HakoCheck -Arguments @('key','generate') -ExpectedExit 1
    $publicPath = Join-Path $workRoot 'public key.pem'
    $null = Invoke-HakoCheck -Arguments @('key','export-public','--output',$publicPath)
    if (-not (Test-Path -LiteralPath $publicPath)) { throw 'Public key export file missing.' }
    $null = Invoke-HakoCheck -Arguments @('key','export-public','--output',$publicPath) -ExpectedExit 1
    $export = Invoke-HakoCheck -Arguments @('key','export-public')
    if ($export.data.publicKeyPem -notmatch 'BEGIN PUBLIC KEY') { throw 'Public PEM missing from JSON.' }
    $null = Invoke-HakoCheck -Arguments @('config','set','--url','http://127.0.0.1:1','--account','owner')
    $configuration = Invoke-HakoCheck -Arguments @('config','show')
    if ($configuration.data.keyId -ne $key.data.keyId -or $configuration.data.account -ne 'owner') { throw 'Shared configuration was not persisted.' }
    $null = Invoke-HakoCheck -Arguments @('config','set','--url','http://example.com') -ExpectedExit 1
    $metrics = Invoke-HakoCheck -Arguments @('metrics')
    if ($metrics.data.memoryTotalBytes -le 0 -or $metrics.data.cpuUsagePercent -lt 0 -or $metrics.data.cpuUsagePercent -gt 100) { throw 'Live metrics invalid.' }
    $connected = Invoke-HakoCheck -Arguments @('connect')
    if (-not $connected.data.running -or $connected.data.processId -le 0) { throw 'Connect did not start an independent background process.' }
    $backgroundId = $connected.data.processId
    $status = Invoke-HakoCheck -Arguments @('status')
    if ($status.data.processId -ne $backgroundId) { throw 'Status did not reuse the running background process.' }
    $null = Invoke-HakoCheck -Arguments @('config','set','--account','updatedowner')
    $status = Invoke-HakoCheck -Arguments @('status')
    if ($status.data.processId -ne $backgroundId -or $status.data.configuration.account -ne 'updatedowner') { throw 'IPC configuration is not shared with running instance.' }
    $disconnected = Invoke-HakoCheck -Arguments @('disconnect')
    if ($disconnected.data.connectionState -ne 'disconnected') { throw 'Disconnect did not stop retrying.' }
    $null = Invoke-HakoCheck -Arguments @('exit')
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Get-Process -Id $backgroundId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $stopped = Invoke-HakoCheck -Arguments @('status')
    if ($stopped.data.running -or $stopped.data.configuration.keyId -ne $key.data.keyId) { throw 'Exit did not stop the process or preserve the key.' }
    $backgroundId = $null
    $guiStart = [System.Diagnostics.ProcessStartInfo]::new($executablePath)
    $guiStart.UseShellExecute = $false; $guiStart.CreateNoWindow = $true
    $guiStart.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $guiStart.ArgumentList.Add('--data-dir'); $guiStart.ArgumentList.Add($profileDirectory)
    $guiProcess = [System.Diagnostics.Process]::Start($guiStart)
    $backgroundId = $guiProcess.Id
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 150
        $guiStatus = Invoke-HakoCheck -Arguments @('status')
    } until ($guiStatus.data.running -or [DateTime]::UtcNow -ge $deadline)
    if (-not $guiStatus.data.running -or $guiStatus.data.processId -ne $backgroundId) { throw 'CLI could not control the GUI runtime.' }
    $null = Invoke-HakoCheck -Arguments @('config','set','--account','guiowner')
    $guiStatus = Invoke-HakoCheck -Arguments @('status')
    if ($guiStatus.data.configuration.account -ne 'guiowner' -or $guiStatus.data.processId -ne $backgroundId) { throw 'GUI and CLI do not share one runtime/configuration.' }
    $null = Invoke-HakoCheck -Arguments @('exit')
    if (-not $guiProcess.WaitForExit(10000)) { throw 'GUI runtime did not exit through CLI.' }
    $guiProcess.Dispose(); $backgroundId = $null
    Write-Output 'PASS: EXE help/aliases/JSON, exit codes, encrypted keys, safe export, metrics, background control and shared GUI/CLI runtime.'
}
finally {
    if ($null -ne $backgroundId) {
        try { $null = Invoke-HakoCheck -Arguments @('exit') } catch { }
        $owned = Get-CimInstance Win32_Process -Filter "ProcessId=$backgroundId" -ErrorAction SilentlyContinue
        if ($null -ne $owned -and $owned.CommandLine -and $owned.CommandLine.Contains($profileDirectory)) { Stop-Process -Id $backgroundId -Force -ErrorAction SilentlyContinue }
    }
}
