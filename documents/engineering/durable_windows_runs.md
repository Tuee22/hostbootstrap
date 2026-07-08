# Durable Long Runs on Windows

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../CLAUDE.md](../../CLAUDE.md), [../../AGENTS.md](../../AGENTS.md)

> **Purpose**: Explain why a long agent-driven run (the ~25–50 min demo gate) gets killed on Windows
> under a Claude Code / agentic-CLI session, and give the Windows-only procedure that makes it survive.

## TL;DR

- **Windows only.** macOS and Linux are unaffected; run the gate normally there.
- **Two tiers of tests.** The fast suites (`hostbootstrap.test_all`, `cabal test`) run foreground on
  every platform and are unaffected — iterate on them normally. Only the long demo gate
  (`hostbootstrap run -- test run all` / `project up`, ~25–50 min) needs the procedure below.
- **Root cause (source-proven).** Claude Code launches a `run_in_background` shell as a *descendant of
  `claude.exe`*, and its own idle/lifecycle reaper terminates it on Windows with
  `taskkill /PID <pid> /T /F` — a grace-less kill of the whole descendant tree, which severs the
  `python → hostbootstrap-demo.exe → wsl.exe` orchestrator.
- **Fix.** Launch the gate *out of `claude.exe`'s process tree* with
  [`scripts/Start-DurableRun.ps1`](../../scripts/Start-DurableRun.ps1) (WMI `Win32_Process.Create` →
  child of `WmiPrvSE.exe`), then poll the exit-code sentinel with the `ScheduleWakeup` tool. Never use
  a `run_in_background` "waiter".

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

1. **Launch out of the tree.** Run [`scripts/Start-DurableRun.ps1`](../../scripts/Start-DurableRun.ps1)
   as a normal foreground tool call (it returns immediately after spawning):

   ```powershell
   scripts\Start-DurableRun.ps1 -Command 'hostbootstrap run -- test run all' `
       -Label 'gate-testrun' -WorkingDirectory 'C:\Users\Matt\hostbootstrap\demo' `
       -OutputDir '<session scratchpad dir>'
   ```

   It prints a JSON line: `{ "pid", "label", "out", "exit", "method" }`. All run output (streams
   merged) goes to `<label>.out`; the integer exit code is written to `<label>.exit` when the run
   finishes. Output goes to the scratchpad, never the repository tree (no `.log` files in the tree).

2. **Poll with `ScheduleWakeup`.** Schedule a wake-up sized to the expected runtime, and on each wake
   do a stateless check: if `<label>.exit` exists, read the exit code and tail `<label>.out`; otherwise
   confirm the pid is still alive (`Get-Process -Id <pid>`) and reschedule. **Do not** launch a
   `run_in_background` sleep-loop "waiter" — the waiter is itself a `claude.exe` descendant, so it is
   exactly what the reaper kills, and each reap produces a spurious "killed" notification that looks
   like the test dying when it is not.

3. **A genuine kill is still detectable.** If the pid is gone and no `<label>.exit` was written, the run
   was actually killed or crashed — distinct from a clean non-zero exit.

## Guardrail

A `PreToolUse` hook ([`scripts/hooks/guard-durable-run.ps1`](../../scripts/hooks/guard-durable-run.ps1))
blocks a direct `hostbootstrap run -- (test run all | project up)` on Windows that does not go through
`Start-DurableRun.ps1`, and redirects to this procedure. The hook is registered in the Windows user's
Claude Code settings (`~/.claude/settings.json`), **not** in the committed repo, so it never burdens a
macOS/Linux checkout — the hook command `uname`-gates to Windows and only invokes the guard for
`hostbootstrap`-mentioning commands, so ordinary commands and the fast suites pay no cost. What travels
with the repo is this doc plus `Start-DurableRun.ps1`; install the hook once per Windows machine.

## Attended runs

When you are present and want to watch the run live, the simplest durable option is to run it yourself
in a **separate terminal** (not the in-session `!` prefix, which still executes under the harness). A
tmux session also escapes the reaper (its server daemonizes outside `claude.exe`'s tree), but the
native Win32 tmux port on this host is fragile — see the host notes on the tmux server crashing on
desktop logon/unlock — so it is not recommended for unattended durability without a sturdier
multiplexer.

## Verification

The mechanism was confirmed empirically: a `Start-DurableRun.ps1`-launched process shows
`ParentProcessId` → `WmiPrvSE.exe` → `services.exe`, entirely outside `claude.exe`'s tree, with the
exit code and output captured to the scratchpad sentinel. To re-verify after changes: launch a short
command via the helper, inspect the parent chain with
`Get-CimInstance Win32_Process -Filter "ProcessId=<pid>"`, and confirm the `<label>.exit` sentinel
appears with the expected code.
