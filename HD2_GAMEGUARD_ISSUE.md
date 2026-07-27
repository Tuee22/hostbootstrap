# Helldivers 2 GameGuard "Initialize Error 110" during hostbootstrap development

**Status**: Investigation findings — diagnosis proposed, not yet experimentally confirmed
**Machine**: Windows 11 Home 10.0.26200, 15.9 GiB RAM
**Date of investigation**: 2026-07-27
**Scope**: Host-environment interaction between the hostbootstrap Windows demo substrate (WSL2)
and nProtect GameGuard as shipped with Helldivers 2. Not a defect in hostbootstrap code.

> **Summary**: The hostbootstrap demo VM walls off 10 GiB of a 16 GiB host. That leaves roughly
> 5–6 GiB for Windows, Steam, and Helldivers 2 — below the game's 8 GB official minimum. GameGuard
> initializes early and expensively and is the first component to fail, surfacing as the generic
> error 110. The always-on Hyper-V hypervisor is **not** the cause, and disabling it (the most
> common internet advice for error 110) would break hostbootstrap for no benefit.

---

## 1. Symptom

Launching Helldivers 2 from Steam fails before the game window appears, with an nProtect GameGuard
dialog reporting **Initialize Error 110**. The failures correlate with periods of hostbootstrap
development work on the same machine. The problem is described as recent ("lately") rather than
long-standing.

Error 110 carries no published meaning. nProtect does not document its error codes, and the local
GameGuard logs are encrypted (see §2.5), so the code number itself is not evidence of anything. The
diagnosis below is built entirely from measured machine state.

---

## 2. Evidence gathered

All checks were read-only. Nothing on the machine was modified.

### 2.1 Host capacity

| Measurement | Value | Source |
|---|---|---|
| Total physical RAM | 17,040,592,896 B (15.87 GiB usable) | `Win32_ComputerSystem.TotalPhysicalMemory` |
| Free RAM with dev **down** | ~6.6 GiB | `Win32_OperatingSystem.FreePhysicalMemory` |
| Windows | 11 Home, build 26200 | `systeminfo` |

### 2.2 Virtualization state — constant, therefore not the trigger

| Measurement | Value | Source |
|---|---|---|
| Boot hypervisor setting | `hypervisorlaunchtype Auto` | `bcdedit /enum {current}` |
| Hypervisor present | `True` | `Win32_ComputerSystem.HypervisorPresent` |
| Hypervisor started | "Hypervisor successfully started" | System log, `Hyper-V-Hypervisor` event 1 |
| Scheduler type | `0x4` (root scheduler — the client-SKU default used by WSL2/VBS) | System log, `Hyper-V-Hypervisor` event 2 |
| VBS | Enabled and running (`VirtualizationBasedSecurityStatus: 2`) | `Win32_DeviceGuard` |
| HVCI / Credential Guard | **Not** running (`SecurityServicesRunning: {0}`) | `Win32_DeviceGuard` |
| Secure Boot | Disabled | TPM-WMI event 1041 |

This state is established at boot and does not change when you start or stop development work.
Helldivers 2 launches successfully on this machine under exactly this configuration whenever dev
work is not running. **The hypervisor is therefore ruled out as the differentiator.** See §5.

### 2.3 Current WSL2 / container state (at time of investigation, dev down)

| Measurement | Value |
|---|---|
| Registered WSL distros | none (`HKU\<Matt SID>\…\Lxss` empty) |
| `%UserProfile%\.wslconfig` | does not exist |
| `vmmem` / `vmmemWSL` | not running |
| `WslService` | Running (idle) |
| `vmcompute` | Stopped |
| `hns` | Running |
| Docker Desktop | **not installed** |

This confirms the demo substrate is created and torn down on demand rather than persisting, and
that Docker Desktop plays no part in this problem.

> **Investigation gotcha**: WSL distro registration is **per-user**. An elevated shell reports
> "Windows Subsystem for Linux has no installed distributions" even when the interactive user's
> distros exist. Run all `wsl` commands non-elevated, as yourself.

### 2.4 GameGuard installation state

| Measurement | Value |
|---|---|
| Service | `npggsvc` — "nProtect GameGuard Service" |
| Binary | `C:\Windows\system32\GameMon.des -service` |
| Account / start type | LocalSystem / demand-start |
| Status at investigation | Stopped |
| Kernel driver payloads | `npggNT64.des` (3.4 MB), `GameMon64.des` (14.4 MB) in `…\Helldivers 2\bin\GameGuard\` |
| Last launcher log write | `bin\GameGuard\npgl.erl`, 2026-07-27 12:11:34 |

GameGuard is a kernel-mode anti-cheat: at launch it loads a driver, starts a LocalSystem service,
and performs memory scanning and integrity checks. This is a memory- and CPU-intensive startup
sequence that runs *before* the game itself, which matters for §4.

### 2.5 GameGuard logs are unusable

`bin\GameGuard\*.erl` (`npgl`, `0npgg`, `0npgm`, `0npsc64`, and rotated siblings) were read
directly. All are encrypted or compressed binary — no plaintext error strings, timestamps, or
codes. **Root-causing from GameGuard's own logs is not possible.** Their modification timestamps
are still useful as launch-attempt markers (see §6.4).

### 2.6 What hostbootstrap reserves on this host

From the repository's own documentation:

| Fact | Value | Source |
|---|---|---|
| Demo `deploy-VM` gate floor | **6 CPU / 10 GiB / 80 GiB** (`demoFullLifecycleResources`) | `documents/engineering/resource_budgeting.md:68,117` |
| Windows cordon mechanism | **Global** `%UserProfile%\.wslconfig` `[wsl2]` ceiling — WSL2 has no per-distro CPU/memory wall | `resource_budgeting.md:20,260`; `wsl2.md:41` |
| Managed config body | `processors`, `memory`, **`swap` equal to the memory amount**, plus `[wsl2] vmIdleTimeout` and `[general] instanceIdleTimeout` | `wsl2.md:68`; `Wsl2/GlobalWall/ConfigBytes.hs` |
| Host-OS reserve in preflight | 4 GiB | `resource_budgeting.md:210-214` |
| Applying the ceiling | runs a global `wsl --shutdown` (disclosed side effect) | `demo/src/HostBootstrapDemo/Commands.hs:2504-2511` |
| `project down` / `destroy` | restores the original `.wslconfig` from backup | `Commands.hs:2419` |

Note the preflight arithmetic: 10 GiB budget + 4 GiB host reserve = 14 GiB ≤ 15.87 GiB, so the
demo gate **legitimately passes** its own host check on this machine. hostbootstrap is behaving as
designed. It simply has no knowledge that a 16 GiB-recommended game also wants the box.

### 2.7 Helldivers 2 requirements

| Spec | Value |
|---|---|
| Minimum RAM | **8 GB** |
| Recommended RAM | **16 GB** |

---

## 3. The arithmetic

With the demo VM up on this 15.87 GiB host:

```
WSL2 utility VM (walled)      10.0 GiB   + a swap file of equal size, + 6 of the cores
Windows + Steam + overhead    ~3.0 GiB
------------------------------------------
Remaining for HD2             ~5-6 GiB   <-- below the 8 GB official MINIMUM
```

The game is nominally a 16 GB-recommended title on a 16 GB machine. It has no headroom to give.
Removing 10 GiB puts it under its own floor, before GameGuard's driver load and memory scan are
even accounted for.

---

## 4. Diagnosis

**Primary hypothesis — memory and CPU starvation.**

GameGuard's initialization is the earliest and most resource-hungry phase of the launch: kernel
driver load, LocalSystem service start, memory scanning. Under a ~5–6 GiB ceiling with 6 of the
machine's cores already committed to the WSL2 VM, that initialization fails or times out, and
nProtect reports it as the generic error 110. The game never reaches the point where it could
report a memory problem in its own voice.

This hypothesis predicts that failure tracks *free RAM*, and is indifferent to whether WSL
plumbing (the `.wslconfig` file, the registered distro, the vSwitch) is present.

### Why the problem appeared recently

`scripts/Start-DurableRun.ps1` is now the sanctioned way to run the long demo gate on Windows
(~25–50 min), specifically because it launches the run **outside `claude.exe`'s process tree** so
the harness's own reaper cannot kill it. Before that mechanism was adopted, backgrounded gates were
force-killed when the session ended — which incidentally released the RAM.

Now a gate you started keeps holding 10 GiB and 6 cores after the assistant session appears
finished, with no visible indication in the UI. Walking away from a "done-looking" session and
launching Helldivers 2 is exactly the collision being observed. This is the most likely explanation
for "lately."

### Secondary factor — GameGuard's sticky failure state

Error 110 is widely reported by the community as nProtect failing to close a prior instance of
itself. Once it fires, `npggsvc` and/or `GameMon.des` can be left running, and **every subsequent
launch fails regardless of available memory** until that state is cleared. This is not the root
cause, but it means:

- the failure appears more persistent and less RAM-correlated than it actually is; and
- any diagnostic testing that does not reset GameGuard between attempts will produce garbage
  results.

---

## 5. Explicitly ruled out

**Hyper-V / VBS / Virtual Machine Platform.** The single most common internet recommendation for
GameGuard 110 is to disable Hyper-V. On this machine that advice is both wrong and harmful:

- The hypervisor is launched at boot (`hypervisorlaunchtype Auto`) and is *always* present, VBS
  included. It does not toggle with development work.
- Helldivers 2 launches successfully under this exact configuration whenever dev work is down.
  Hypervisor presence is therefore demonstrably not sufficient to cause the failure.
- Disabling it would break WSL2 entirely, and with it the whole Windows substrate hostbootstrap
  depends on.

**Do not disable Hyper-V, VBS, or the Virtual Machine Platform.**

**Docker Desktop.** Not installed on this machine. Irrelevant here despite frequently appearing in
community threads about virtualization/anti-cheat conflicts.

**HVCI / Memory Integrity.** Configured but not running, so it cannot be blocking the GameGuard
driver load.

---

## 6. Recommended confirmation experiment

The diagnosis in §4 is strong but circumstantial — the encrypted logs prevent direct proof. This
four-cell experiment discriminates memory starvation from the alternative (WSL virtual networking),
which matters because the two have different remedies.

### 6.1 Mandatory reset between every cell

Fully exit Steam, then verify GameGuard is clean. Skipping this invalidates everything downstream
(see §4, secondary factor):

```powershell
Get-Process GameMon*, nprotect* -ErrorAction SilentlyContinue   # expect: nothing
Get-Service npggsvc | Select-Object Name, Status                 # expect: Stopped
```

If either is live, stop the service from an elevated shell and let it settle.

### 6.2 State snapshot before each launch

```powershell
[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB, 2)   # free GiB
Get-Process vmmem* -ErrorAction SilentlyContinue |
  Select-Object Name, @{n='GB';e={[math]::Round($_.WorkingSet64/1GB,2)}}
wsl.exe -l -v                                    # non-elevated, as yourself
Test-Path $env:USERPROFILE\.wslconfig
Get-Date
```

Also confirm no detached durable run is still alive from an earlier session — it is invisible in
the Claude UI but very much running:

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'hostbootstrap|cabal|ghc|wsl' } |
  Select-Object ProcessName, Id, StartTime
```

### 6.3 The cells

| Cell | Setup | Expected | Meaning |
|---|---|---|---|
| **A — baseline** | Dev fully down: no `.wslconfig`, no `vmmem*`, ≥ ~11 GiB free | HD2 launches | Confirms HD2 tolerates the always-on hypervisor; the trigger is something dev *adds*. If it fails here, the premise is wrong — treat as a plain GameGuard problem. |
| **B — reproduce** | `hostbootstrap run -- project up` (or the gate running). Confirm `vmmemWSL` ≈ 10 GiB and free RAM ≈ 5–6 GiB | Error 110 | Reproduction confirmed. If HD2 launches, the correlation is weaker than assumed — look for other differences (active build vs idle VM, GPU load, Steam state). |
| **C — discriminator** | From B's state, run **only** `wsl.exe --shutdown`, then reset GameGuard. This frees the 10 GiB but deliberately leaves the `.wslconfig` wall, the registered distro, and the vSwitch/virtual adapters in place | HD2 launches | **Memory starvation confirmed.** The wall file and virtual networking are exonerated. |
| **D — only if C still fails** | `hostbootstrap run -- project down` (also restores the original `.wslconfig`). Verify adapters dropped: `Get-NetAdapter \| Where-Object { $_.Name -match 'WSL\|vEthernet' }` | HD2 launches | Cause is WSL virtual networking or distro registration, not memory. If it still fails, reboot and retest to separate persistent driver state from live state. |

### 6.4 Recording results

For each cell record: timestamp, free GiB, `vmmemWSL` working set, `npggsvc` status, HD2 outcome.

Cross-check every launch attempt against the modification time of:

```
C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\GameGuard\npgl.erl
```

It is rewritten on each launch, so a fresh mtime proves GameGuard actually ran, rather than the
launch failing earlier for an unrelated reason.

---

## 7. Recommendations

### 7.1 Immediate, no cost — sequence the work

**Most hostbootstrap work does not need the WSL2 VM at all, and can run while you game:**

- `cabal build` / `cabal test` (from `core/`) — native, no VM
- `poetry run python -m hostbootstrap.check_code` — native
- `poetry run python -m hostbootstrap.test_all` — native
- editing, reading, review — obviously fine

CPU contention is the only cost, and 6 cores are not being held hostage.

**Only these raise the 10 GiB VM and cannot coexist with Helldivers 2:**

- `hostbootstrap run -- project up`
- `hostbootstrap run -- test run all` (the ~25–50 min gate)

Before gaming:

```powershell
wsl.exe --shutdown                                    # reclaims the 10 GiB immediately
Get-Process vmmem* -ErrorAction SilentlyContinue      # expect: nothing
[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB, 2)   # expect >= ~11
Get-Service npggsvc | Select-Object Status            # expect: Stopped
```

`wsl --shutdown` is non-destructive and is already a disclosed part of hostbootstrap's own
lifecycle (`Commands.hs:2504-2511`) — the utility VM restarts on next use and re-reads the ceiling.
A full `project down` is only needed if cell D implicates the virtual networking.

### 7.2 Guard against the invisible durable run

The durable-run launcher is designed to survive session teardown. Treat "the Claude session looks
finished" as **no evidence at all** that the gate has stopped. Before launching the game, check for
a live gate — either the `<label>.exit` sentinel from `scripts/Start-DurableRun.ps1` or the process
check in §6.2. This single habit likely eliminates most occurrences.

### 7.3 If the failure has already fired — clear the sticky state

Because of §4's secondary factor, freeing RAM alone may not be enough once 110 has appeared:

1. Fully exit Steam (check the tray; confirm no `steam.exe` remains).
2. Confirm no `GameMon*` / `nprotect*` processes are running; stop `npggsvc` if it is running.
3. Relaunch.

If 110 persists with ample free RAM and no GameGuard remnants, delete
`…\Helldivers 2\bin\GameGuard\` and use Steam's *Verify integrity of game files* to reinstall it.

### 7.4 Do not do

- **Do not disable Hyper-V, VBS, or the Virtual Machine Platform** (§5). It is the top community
  suggestion for error 110 and it is wrong for this machine.
- **Do not hand-edit `%UserProfile%\.wslconfig`.** hostbootstrap owns that file: it manages
  `processors`, `memory`, `swap`, and the idle timeouts, backs up the original, and restores it on
  `project down` / `destroy`. Hand edits will be reconciled away or will confuse the restore path —
  and there is active development on `HostBootstrap.Wsl2.GlobalWall` right now.
- **Do not simply lower the wall to make room.** The demo gate's `6/10/80` floor
  (`demoFullLifecycleResources`) is enforced by preflight; a smaller budget is refused.

### 7.5 Longer-term options

| Option | Effect | Trade-off |
|---|---|---|
| **32 GB RAM upgrade** | The only way to genuinely run the demo gate and HD2 concurrently | Hardware cost. Also removes the standing "16 GB is tight" constraint on demo work generally. |
| **`autoMemoryReclaim` in the managed `.wslconfig` body** | WSL2 returns idle memory to Windows instead of holding the full balloon | A *code* change to `Wsl2/GlobalWall/ConfigBytes.hs`, not a hand edit. Helps after a workload finishes; does **not** help while the gate is actively running. Worth raising with the session doing that work. |
| **Tighter idle timeouts** | The VM stops sooner when unused, releasing RAM without manual intervention | Already partly addressed (`[general] instanceIdleTimeout` was the fix for the WSL2 idle-stop issue). Does not help during an active gate. |
| **Run the long gate deliberately** | Start it when you are done gaming for the session; treat it as an overnight job | Free, but requires the discipline in §7.2. |

---

## 8. Open questions

1. Does cell C succeed? That is the one experiment that converts this from a strong inference into
   a confirmed diagnosis.
2. Is GPU memory also a factor? Not measured. If cell C succeeds, it does not matter.
3. Does GameGuard's failure threshold sit at free-RAM or at commit-charge? If the experiment gives
   ambiguous results, tracking commit charge (`Get-Counter '\Memory\Committed Bytes'`) alongside
   free RAM in §6.2 would sharpen it.

---

## 9. References

- `documents/engineering/resource_budgeting.md` — demo gate floor, host reserve, per-substrate cordoning
- `documents/engineering/wsl2.md` — the global `.wslconfig` wall and its managed body
- `documents/engineering/durable_windows_runs.md` — why long gates are detached from `claude.exe`
- `scripts/Start-DurableRun.ps1` — the durable launcher
- `demo/src/HostBootstrapDemo/Commands.hs` — `wsl --shutdown` disclosure, `project down` restore path
- [Helldivers 2 system requirements](https://www.pcgamesn.com/helldivers-2/system-requirements)
- [Steam: GameGuard error code 110](https://steamcommunity.com/app/553850/discussions/1/7599331480041481363/)
- [Steam: How to Fix Error Code 110](https://steamcommunity.com/sharedfiles/filedetails/?id=3159307976)
