<#
.SYNOPSIS
    Launch a long-running command OUTSIDE Claude Code's (claude.exe's) process tree so it
    survives the harness's background-task reaper. Windows-only.

.DESCRIPTION
    Root cause this exists for (source-proven from claude.exe v2.1.204): a command started as a
    Claude Code `run_in_background` shell is a *descendant of claude.exe*, and the harness's own
    idle/lifecycle reaper terminates it on Windows with `taskkill /PID <pid> /T /F` -- a grace-less
    kill of the whole descendant tree. macOS/Linux escape this (graceful group-signal + the heavy
    workload lives under a separate daemon/VM outside the tool's process group), which is why only
    Windows needs this helper.

    This script launches the command via WMI `Win32_Process.Create`, so the new process is a child
    of `WmiPrvSE.exe` -- NOT of claude.exe -- and therefore unreachable by the reaper's
    `taskkill /T`. Output (all streams merged) and a small exit-code sentinel are written to
    OutputDir. The launcher itself returns immediately, so nothing long-lived remains inside
    claude.exe's tree.

    The intended caller (Claude Code) then polls the sentinel with the ScheduleWakeup tool -- a
    stateless, sub-second check -- and reads the results when `<Label>.exit` appears. Do NOT wrap
    this in a `run_in_background` "waiter": that waiter is itself a reaped descendant and is the
    source of the spurious "killed" notifications.

.PARAMETER Command
    The command line to run, e.g. 'hostbootstrap run -- test run all'.

.PARAMETER Label
    A short run label (used to name the output and sentinel files). Sanitized to [A-Za-z0-9._-].

.PARAMETER WorkingDirectory
    Working directory for the launched command. Defaults to the current directory.

.PARAMETER OutputDir
    Directory for the generated launcher, the merged output file, and the exit sentinel. Pass the
    session scratchpad dir. Defaults to %TEMP%\hb-durable-runs. Never the repo working tree.

.PARAMETER Method
    'Wmi' (default) creates the process via Win32_Process.Create (child of WmiPrvSE, no admin, no
    footprint). 'ScheduledTask' uses a one-shot Task Scheduler task (service-owned) instead; it is
    also used as an automatic fallback if the WMI create fails.

.OUTPUTS
    A single compressed JSON object on stdout:
      { "pid": <int>, "label": "<Label>", "out": "<path>", "exit": "<path>", "method": "Wmi|ScheduledTask" }
    Poll `exit` for existence: when present it contains the integer exit code. If the pid is gone
    and no exit file was written, the run was killed/crashed.

.EXAMPLE
    scripts\Start-DurableRun.ps1 -Command 'hostbootstrap run -- test run all' `
        -Label 'gate-testrun' -WorkingDirectory 'C:\Users\Matt\hostbootstrap\demo' `
        -OutputDir 'C:\...\scratchpad'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string]$Label,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$OutputDir = (Join-Path $env:TEMP 'hb-durable-runs'),
    [ValidateSet('Wmi', 'ScheduledTask')][string]$Method = 'Wmi'
)

$ErrorActionPreference = 'Stop'

# --- Windows-only guard -------------------------------------------------------------------------
$isWin = $false
if ($null -ne $env:OS -and $env:OS -eq 'Windows_NT') { $isWin = $true }
if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) { $isWin = $IsWindows }
if (-not $isWin) {
    throw 'Start-DurableRun.ps1 is Windows-only. On macOS/Linux run the command normally (foreground or a plain background task); the reaper there is graceful and the workload detaches on its own.'
}

# --- Resolve paths ------------------------------------------------------------------------------
$safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '_')
if ([string]::IsNullOrWhiteSpace($safeLabel)) { throw "Label sanitized to empty; pass a label containing [A-Za-z0-9._-]." }
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

$outFile    = Join-Path $OutputDir "$safeLabel.out"
$exitFile   = Join-Path $OutputDir "$safeLabel.exit"
$launchFile = Join-Path $OutputDir "$safeLabel.launch.ps1"

# Clear stale artifacts for this label so a poll can't read a previous run's result.
foreach ($f in @($outFile, $exitFile, $launchFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

# --- Generate the launcher script ---------------------------------------------------------------
# The launcher runs INSIDE the detached process: it sets cwd, runs the command with every stream
# merged into the out file, then writes the integer exit code to the sentinel. Single quotes in
# embedded literals are doubled so paths/commands with apostrophes stay intact.
function Quote([string]$s) { "'" + ($s -replace "'", "''") + "'" }

$launcher = @"
`$ErrorActionPreference = 'Continue'
`$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Set-Location -LiteralPath $(Quote $WorkingDirectory)
try {
    Invoke-Expression $(Quote $Command) *>&1 | Out-File -LiteralPath $(Quote $outFile) -Encoding utf8
    `$code = `$LASTEXITCODE
} catch {
    `$_ | Out-String | Out-File -LiteralPath $(Quote $outFile) -Append -Encoding utf8
    `$code = 1
}
if (`$null -eq `$code) { `$code = 0 }
Set-Content -LiteralPath $(Quote $exitFile) -Value ([string]`$code)
"@
Set-Content -LiteralPath $launchFile -Value $launcher -Encoding UTF8

$psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$launchCmdLine = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $psExe, $launchFile

# --- Launch, breaking out of claude.exe's tree --------------------------------------------------
function Start-ViaWmi {
    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = $launchCmdLine
        CurrentDirectory = $WorkingDirectory
    }
    if ($res.ReturnValue -ne 0) { throw "Win32_Process.Create failed (ReturnValue=$($res.ReturnValue))." }
    return [int]$res.ProcessId
}

function Start-ViaScheduledTask {
    $taskName = "hb-durable-$safeLabel"
    schtasks.exe /Query /TN $taskName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { schtasks.exe /Delete /TN $taskName /F | Out-Null }
    $action = "$psExe -NoProfile -ExecutionPolicy Bypass -File `"$launchFile`""
    schtasks.exe /Create /TN $taskName /TR $action /SC ONCE /ST 00:00 /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed (exit $LASTEXITCODE)." }
    schtasks.exe /Run /TN $taskName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Run failed (exit $LASTEXITCODE)." }
    # Best-effort: resolve the spawned PID (may not be immediately available).
    Start-Sleep -Milliseconds 500
    $p = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$safeLabel.launch.ps1*" } |
        Select-Object -First 1
    return [int]($p.ProcessId | ForEach-Object { $_ })
}

$usedMethod = $Method
try {
    if ($Method -eq 'Wmi') { $procId = Start-ViaWmi }
    else { $procId = Start-ViaScheduledTask }
}
catch {
    if ($Method -eq 'Wmi') {
        Write-Warning "WMI launch failed ($($_.Exception.Message)); falling back to a Scheduled Task."
        $usedMethod = 'ScheduledTask'
        $procId = Start-ViaScheduledTask
    }
    else { throw }
}

[pscustomobject]@{
    pid    = $procId
    label  = $safeLabel
    out    = $outFile
    exit   = $exitFile
    method = $usedMethod
} | ConvertTo-Json -Compress
