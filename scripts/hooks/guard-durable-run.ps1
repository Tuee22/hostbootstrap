<#
.SYNOPSIS
    Claude Code PreToolUse guard: on WINDOWS ONLY, block a naive launch of the long demo gate so it
    is not reaped mid-run. No-ops (allows) on macOS/Linux and for every non-gate command.

.DESCRIPTION
    Reads the PreToolUse payload as JSON on stdin. If the OS is Windows and the Bash/PowerShell
    command is a direct `hostbootstrap ... (test run all | project up)` (or the demo exe equivalent)
    that is NOT going through scripts\Start-DurableRun.ps1, it exits 2 with an explanatory message
    on stderr -- which Claude Code surfaces to the model and treats as "block this tool call". Any
    other case exits 0 (allow).

    Why: claude.exe reaps its own run_in_background descendants on Windows via `taskkill /T /F`; the
    ~25-50 min demo gate must be launched OUT of claude.exe's tree (Start-DurableRun.ps1) and polled
    via ScheduleWakeup. See CLAUDE.md / AGENTS.md "Running tests (Windows)" and
    documents/engineering/durable_windows_runs.md.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Allow { exit 0 }

# --- Windows-only: never interfere on macOS/Linux -----------------------------------------------
$isWin = ($env:OS -eq 'Windows_NT')
if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) { $isWin = $IsWindows }
if (-not $isWin) { Allow }

# --- Parse the PreToolUse payload ---------------------------------------------------------------
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { Allow }
try { $payload = $raw | ConvertFrom-Json } catch { Allow }   # never break tooling on parse issues

$tool = [string]$payload.tool_name
if ($tool -ne 'Bash' -and $tool -ne 'PowerShell') { Allow }

$command = [string]$payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { Allow }

# --- Allow the sanctioned path ------------------------------------------------------------------
if ($command -match 'Start-DurableRun') { Allow }

# --- Block a naive gate launch ------------------------------------------------------------------
# hostbootstrap run -- test run all / project up, or the demo exe running the same.
$gate = '(?i)(hostbootstrap(-demo)?(\.exe)?)\b[^\r\n]*\b(test\s+run\s+all|project\s+up)\b'
if ($command -match $gate) {
    $msg = @'
BLOCKED (Windows-only guard): do not launch the long demo gate directly.

On Windows, `hostbootstrap run -- test run all` / `project up` (~25-50 min) is a descendant of
claude.exe and will be force-killed (taskkill /T /F) by the harness's background-task reaper.

Launch it OUT of claude.exe's process tree instead, then poll with ScheduleWakeup:

  scripts\Start-DurableRun.ps1 -Command 'hostbootstrap run -- test run all' `
      -Label 'gate-testrun' -WorkingDirectory '<demo dir>' -OutputDir '<scratchpad>'

Then re-check the printed `<label>.exit` sentinel via ScheduleWakeup (NOT a run_in_background
waiter). See CLAUDE.md / AGENTS.md "Running tests (Windows)" and
documents/engineering/durable_windows_runs.md. (Fast suites like `hostbootstrap.test_all` and
`cabal test` are unaffected -- run those foreground normally.)
'@
    [Console]::Error.WriteLine($msg)
    exit 2
}

Allow
