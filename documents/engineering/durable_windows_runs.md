# Durable Long Runs on Windows

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [WSL2](wsl2.md), [testing](testing.md), [../../CLAUDE.md](../../CLAUDE.md), [../../AGENTS.md](../../AGENTS.md)

> **Purpose**: Explain why an agent-driven long-running demo gate gets killed on Windows
> under a Claude Code / agentic-CLI session, give the Windows-only procedure that makes it survive, and
> state what a surviving run keeps holding after the session ends.

## TL;DR

- **Windows only.** macOS and Linux are unaffected; run the gate normally there.
- **Two tiers of tests.** The host static gate — the four commands in
  [§ JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness),
  including `check_code` and the `demo/` Cabal leg — runs foreground as ordinary Windows processes and is
  expected to pass there, exactly as on macOS and Linux; iterate on it normally, with no WSL2 distro and no
  durable launcher involved. See [testing](testing.md#gate-kinds). Only the long demo gate
  (`test run all` / `project up` through the Python bootstrapper), whose Windows matrix can run for hours,
  needs the procedure below because it drives WSL2, Docker, and a real cluster.
- **Root cause (source-proven).** Claude Code launches a `run_in_background` shell as a *descendant of
  `claude.exe`*, and its own idle/lifecycle reaper terminates it on Windows with
  `taskkill /PID <pid> /T /F` — a grace-less kill of the whole descendant tree, which severs the
  `python → hostbootstrap-demo.exe → wsl.exe` orchestrator.
- **Fix.** Launch the gate *out of `claude.exe`'s process tree* with the harness-owned
  `Start-DurableRun.ps1` (WMI `Win32_Process.Create` → child of `WmiPrvSE.exe`), then poll the
  exit-code sentinel with the `ScheduleWakeup` tool. Never use a `run_in_background` "waiter".

## Root cause

The behavior was isolated from the on-disk `claude.exe` binary (v2.1.204), not inferred:

- **Spawn.** On Windows a shell tool child is created with `detached + windowsHide`, with **no**
  `CREATE_NEW_PROCESS_GROUP` and **no** Job Object. The child is therefore an ordinary native
  descendant of the tool shell, itself a descendant of `claude.exe`.
- **Kill.** The harness's Windows terminal-kill primitive is `taskkill /PID <pid> /T /F`. `/T` walks
  the entire descendant tree; `/F` is forced and grace-less.
- **Trigger.** One of the harness's own reapers (an idle/memory-pressure background-shell reaper, and a
  turn/agent-teardown reaper) fires during a lifecycle/idle moment and calls that kill. It is
  event-driven, not a fixed timer — observed deaths ranged from seconds to ~39 minutes, and short
  fixed-duration probes survived.

Ruled out with evidence: the Windows OS itself (no Kernel-Power / resource-exhaustion / Defender /
scheduler events; `claude` never restarted), a Job Object with kill-on-close (the default shell path
uses explicit `taskkill`, not job-object teardown), and the 10-minute foreground timeout (real, but a
separate hazard — every recorded incident was backgrounded).

## Why Windows only

Two source-level facts make this Windows-specific:

1. The kill path is OS-gated: `if (platform !== 'windows')` routes POSIX through a graceful
   `SIGTERM → 1.5 s → process-group SIGKILL`; Windows alone takes the immediate `taskkill /T /F`.
2. Process topology: on macOS/Linux the container/VM workload runs under a *separate daemon/VM* outside
   the tool's process group, so even a group-kill of the CLI relay leaves the heavy work running. On
   Windows the orchestrator is a direct native child chain fully reachable by `/T`.

The fix principle follows directly: **keep the workload out of `claude.exe`'s descendant tree** so
`taskkill /T` cannot reach it. A Scheduled Task survives for exactly this reason (Task Scheduler owns
it, in a separate session); WMI `Win32_Process.Create` achieves the same with no registration and no
admin (the child is parented to `WmiPrvSE.exe`).

## The procedure (Windows)

1. **Initialize the test config.** From the repository root, run
   `poetry run hostbootstrap run --project-root demo test init` as an ordinary foreground call. It is
   short, the guard does not match it, and `test run all` fails fast at pre-flight without the config it
   writes.

2. **Launch out of the tree.** Run the harness-owned `Start-DurableRun.ps1` as a normal foreground
   tool call (it returns immediately after spawning):

   ```powershell
   & "$env:USERPROFILE\.claude\hostbootstrap\Start-DurableRun.ps1" `
       -Command 'poetry run hostbootstrap run --project-root demo test run all' `
       -Label 'gate-testrun' -WorkingDirectory '<repository root>' `
       -OutputDir '<session scratchpad dir>'
   ```

   The spawned process does not inherit the agent shell's environment: it runs with the user's stored
   environment, so `poetry` must be on the user's persistent `PATH`. The launcher prints a JSON line:
   `{ "pid", "label", "out", "exit", "method" }`. All run output (streams merged) goes to `<label>.out`;
   the integer exit code is written to `<label>.exit` when the run finishes. Output goes to the
   scratchpad, never the repository tree (no `.log` files in the tree). Right after launch, record the
   process's identity:
   `Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" | Select-Object CreationDate, CommandLine`.

3. **Poll with `ScheduleWakeup`.** Schedule a wake-up sized to the expected runtime, and on each wake
   do a stateless check: if `<label>.exit` exists, read the exit code and tail `<label>.out`; otherwise
   confirm that a process with that pid exists *and* has the recorded creation date and command line
   (Windows reuses pids, so a bare `Get-Process -Id <pid>` can report an unrelated process), then
   reschedule. **Do not** launch a `run_in_background` sleep-loop "waiter" — the waiter is itself a
   `claude.exe` descendant, so it is exactly what the reaper kills, and each reap produces a spurious
   "killed" notification that looks like the test dying when it is not.

4. **A genuine kill is still detectable.** If the recorded process is gone, check `<label>.exit` once
   more: the run may have written it and exited between the two checks. Only if the process is gone and
   `<label>.exit` is still absent was the run killed or crashed — distinct from a clean non-zero exit.

## Guardrail

A `PreToolUse` hook (`guard-durable-run.ps1`) blocks a direct
`hostbootstrap run -- (test run all | project up)` on Windows that does not go through
`Start-DurableRun.ps1`, and redirects to this procedure. It is registered in the Windows user's Claude
Code settings (`~/.claude/settings.json`) — the hook command `uname`-gates to Windows and only invokes
the guard for `hostbootstrap`-mentioning commands, so ordinary commands and the fast suites pay no cost.

## Where the two files live, and why not here

Both `Start-DurableRun.ps1` and `guard-durable-run.ps1` live in the Claude harness's own configuration
directory — `%USERPROFILE%\.claude\hostbootstrap\` — and **not** in this repository. § KK is the
reason, and it is not a filing preference: the repository contains no script, and scaffolding that
exists because of one particular development harness belongs to that harness's configuration. The
reaper these two files work around is a property of `claude.exe`, not of `hostbootstrap`; a macOS or
Linux checkout, a CI runner, and an operator using any other tool all need neither. Nothing in the
build, the gates, or the operator surface depends on them.

What travels with the repository is this document. To install on a fresh Windows machine:

1. Create `%USERPROFILE%\.claude\hostbootstrap\`.
2. Author `Start-DurableRun.ps1` there: it takes `-Command`, `-Label`, `-WorkingDirectory`, and
   `-OutputDir`, writes a small launcher into `OutputDir`, spawns it through
   `Invoke-CimMethod Win32_Process Create` (falling back to a one-shot Scheduled Task), and prints
   `{ "pid", "label", "out", "exit", "method" }`. The launcher merges every stream into `<label>.out`
   and writes the integer exit code to `<label>.exit` when the run finishes.
3. Author `guard-durable-run.ps1` there: it reads the `PreToolUse` payload as JSON on stdin, allows
   everything on non-Windows, every tool other than `Bash` and `PowerShell`, and every command that does
   not match the case-insensitive pattern

   ```text
   (hostbootstrap(-demo)?(\.exe)?)\b[^\r\n]*\b(test\s+run\s+all|project\s+up)\b
   ```

   and otherwise writes the redirect message to stderr and exits 2. Before that match it allows any
   command whose text contains `Start-DurableRun` anywhere. That allowance is a deliberate bypass, not a
   check: a command that merely mentions the launcher name passes the guard even if it also launches the
   gate directly.
4. Register the hook in `~/.claude/settings.json` under `hooks.PreToolUse` for the `Bash|PowerShell`
   matcher, `uname`-gated to Windows and filtered to commands mentioning `hostbootstrap`.

## Attended runs

When you are present and want to watch the run live, the simplest durable option is to run it yourself
in a **separate terminal** (not the in-session `!` prefix, which still executes under the harness). A
tmux session also escapes the reaper (its server daemonizes outside `claude.exe`'s tree), but the
native Win32 tmux port on this host is fragile — see the host notes on the tmux server crashing on
desktop logon/unlock — so it is not recommended for unattended durability without a sturdier
multiplexer.

## The run outlives the session — and holds the wall until teardown

Surviving the reaper is the point of this mechanism, and it has a consequence worth stating plainly:
**a finished-looking agent session is no evidence that the gate has stopped.** The run is detached, so
it disappears from the session UI while continuing to hold everything it reserved — on Windows that is
the project's full CPU and memory budget, walled into the shared WSL2 utility VM.

A run that reaches normal `project down` restores the journalled `.wslconfig` origin and then invokes
global `wsl --shutdown`; the order ensures the next cold boot reads the restored configuration. Shutdown
stops every distro and releases the shared utility VM's memory balloon. The
[Windows and WSL2 substrate phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md) records
this release order and its observed effect on a live utility VM. `project destroy` differs: it releases
the file without a `wsl --shutdown` (see [WSL2 wall release](wsl2.md#wall-release)).

An interrupted detached run is different: if its orchestrator dies before teardown, neither restoration
nor shutdown is guaranteed to execute. The managed six-hour idle timeouts are the eventual-recovery
backstop for that case, not the normal release mechanism. On a host sized close to the budget, inspect
the sentinel and process state and, if the run was interrupted, use `wsl --shutdown` after accounting for
its effect on every distro.

Before treating the host as free, check the run rather than the UI:

```powershell
Get-Content <scratchpad>\<label>.exit -ErrorAction SilentlyContinue   # sentinel: present = finished
Get-Process vmmem* -ErrorAction SilentlyContinue                       # see below
[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB, 2)
```

The vmmem check reads as "released" only when no other WSL distro and no other Hyper-V VM is running:
expect no vmmemWSL process when no other WSL distro runs, and treat any other vmmem process as belonging
to whichever workload owns it.

`wsl --shutdown` reclaims the balloon immediately. It deletes no distro and no data, but it terminates
every running distro, including ones unrelated to this project; the utility VM restarts on next use and
re-reads the restored configuration. It is already a disclosed global part of the provider's own
lifecycle.

## Validation

The mechanism was confirmed empirically: a `Start-DurableRun.ps1`-launched process shows
`ParentProcessId` → `WmiPrvSE.exe` → `services.exe`, entirely outside `claude.exe`'s tree, with the
exit code and output captured to the scratchpad sentinel. To re-verify after changes: launch a short
command via the helper, inspect the parent chain with
`Get-CimInstance Win32_Process -Filter "ProcessId=<pid>"`, and confirm the `<label>.exit` sentinel
appears with the expected code.
