# WSL2 Host Provider

**Status**: Authoritative source
**Supersedes**: the cached-rootfs/`wsl --import` runtime narrative, the backup-existence-as-ownership
claim, and the native C-shim wall adapter
**Referenced by**: [documents index](../README.md), [applied cordon](applied_cordon.md), [ensure reconcilers](ensure_reconcilers.md), [durable state](../architecture/durable_state.md), [ownership invariant](../architecture/ownership_invariant.md), [readiness](../architecture/readiness.md), [lima](lima.md), [incus](incus.md), [durable Windows runs](durable_windows_runs.md), [demo runbook](../operations/demo_runbook.md), [resource budgeting](resource_budgeting.md)

> **Purpose**: Describe the active Windows WSL2 provider, the selected install route, the exact limits of
> the current global-file reconciliation, and how the shared utility-VM wall is released.

## Current Status

Windows uses a project-owned named Ubuntu 24.04 WSL2 distro as the VM provider frame. The active
registration path uses:

```text
wsl --install -d Ubuntu-24.04 --name <project>-vm --no-launch --vhd-size <GB>
```

The active lower-boundary separation assigns pure `Wsl2VM` target data and the inner
`wsl -d <distro> --exec <command> <args...>` renderer to `HostBootstrap.Lift.Context`. The helper appends
the supplied command vector after `--exec`, without an implicit parse by the distro's default shell.
`HostBootstrap.Wsl2` reexports them and
owns distro/lifecycle builders. For compatibility it reexports prerequisite helpers whose implementations
— diagnostics, output normalization, virtualization classification, and `bcdedit` rendering — are owned by
`HostBootstrap.Ensure.Wsl2`. The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
and [ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) pin that dependency
direction.

The selected `SubstrateProvider` is abstract and carries the complete lower `LiftContext` without exposing
construction or record update. Common discovery owns closed daemon, permission, VM, and egress requests,
accepts only raw outcomes from its executor, and privately classifies the complete result vocabulary —
that classification being a total function over a closed sum, so it is reached by application rather than
through a substitution point. Tool paths, markers, identities, and backend reports must be exact
single-line results. The fresh generative capability that common discovery returns exists only after
settlement and is indexed to the exact opaque managed provider, backend, and generation; provider mutation
does not consume it. This is the same interface
used by Incus and Lima rather than a WSL-specific dispatch fold.

It then enters the distro with `wsl -d <distro> --exec <command> <args...>`, stages source, builds/installs the Linux project
binary, ensures the in-distro Docker daemon, builds the project image, and hands the chain into the
container frame. `project down` restores the journalled global-wall origin and then runs global
`wsl --shutdown`. `project destroy` runs a different list: guarded `wsl --unregister`, then the wall
release, and no `wsl --shutdown` (see [Wall release](#wall-release)). The guard is the one
every frame's destructive removal goes through, not a WSL2 copy of it: this provider supplies only the noun
its refusal reads in and the argument vector for a name the guard has already admitted. A distro outside
the project's namespace refuses, and so do the two degenerate inputs that make the guard vacuous — an empty
prefix, which is a prefix of every name, and an empty distro name.

The demo's WSL2 bootstrap installs `demo/docker/wsl2-daemon.json` before starting Docker and
checks that `docker info` reports the classic `overlay2` image store before pulling the
published base image. The daemon downloads one layer at a time, and a WSL2 published-base
pull gets at most three attempts. Each successful pull still has its repository digest
inspected and pinned before the derived build. Docker Engine 29 defaults fresh installations to the containerd image
store; on the Windows acceptance host, that store intermittently failed to extract valid
published layers with tar-header or CRC errors. A later `overlay2` pull also intermittently
reported a layer/configuration mismatch; a retry of that exact digest succeeded. Serial
downloads and the bounded retry mitigate these observed transient failures but do not
establish their lower-level cause. The WSL-only choice leaves the other guest
providers' Docker setup unchanged. The [Windows acceptance phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md)
records the failed pulls, the focused `overlay2` pull and Kind-import probes, and the gate evidence of
its full matrix, which ran with these bounded retries.

The WSL project image import into Kind also permits at most three attempts.
Each failed attempt writes captured Kind output to stderr before retrying, so
an import failure in a nested lifecycle child remains visible to the outer
Harness run. The import targets the same image and cluster on each attempt.
Like the pull retries, it mitigates the observed transient failures without
explaining them.

Before Kind starts, WSL2 bootstrap exports the newly built project image to
`/dev/null` with `docker save`. This checks every local layer, including base
files outside the runtime smoke test. If Docker reports the observed
`file integrity checksum failed` corruption, bootstrap requires an empty
container inventory, removes the guest's unused images and builder cache,
re-pulls the published base with digest verification, and rebuilds. The path
is bounded to three builds and leaves other export failures visible. A
successful export establishes local image integrity at that point; it does
not explain the lower-level cause of intermittent WSL2 image-store corruption.

`wslInstallArgs` is the sole registration builder and has both a production consumer and tests; no
`wsl --import` or cached-rootfs builder exists.

### Open gaps

- **Destroy leaves the utility VM running.** `project destroy` emits no `wsl --shutdown`, so a still-running
  utility VM keeps the managed ceiling until it idles out or an operator shuts it down (see
  [Wall release](#wall-release)). Appending the shutdown to the WSL2 row's destroy effects is owed by
  [the host-providers-and-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md).
- **Wall settlement kernel unadopted.** The production WSL wall is applied and released through
  `HostBootstrap.Wsl2.GlobalWall.Host` directly, not through the typed reservation and settlement chain of
  [Resource wall and global effect](#resource-wall-and-global-effect). Production adoption is owed by
  [the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) (see
  [§ O](../../DEVELOPMENT_PLAN/development_plan_standards.md#o-resource-budget-and-cordoning)).
- **Non-NTFS profile volumes.** The Windows ownership row does not check the filesystem type, so a non-NTFS
  profile volume that supports hard links is trusted rather than refused (see
  [Resource wall and global effect](#resource-wall-and-global-effect)). Owed by
  [the ownership-clauses-and-reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md).
- **Wall location from an unchecked `USERPROFILE`.** `HostBootstrap.Wsl2.GlobalWall.Windows` refuses only an
  unset `USERPROFILE`; an empty or relative value places `.wslconfig` and the wall's protected store under the
  process working directory. `openHostWallLocation`, `hostWallProtectedStore`, and `hostWallActiveRecordKey`
  are public, so a library consumer can aim the wall at any path or compare-and-swap its active record (see
  [Resource wall and global effect](#resource-wall-and-global-effect)). Both are owed by
  [the ownership-clauses-and-reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md).
- **Migrated wall results refused at the mint.** `withProviderWallSettlementPermitFromObservation` refuses
  `WallMigrated` as a non-owning observation, so the `Changed Repaired` settlement the contract names is
  unreachable (see [Resource wall and global effect](#resource-wall-and-global-effect)). Owed by
  [the cluster-lifecycle-and-cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- **Distro adopted by name.** The shared guest-VM provider realization that serves Lima instances and WSL
  distros reports a present distro with the configured name as already owned
  (`ProviderProvisionAlreadyOwned`), with no origin record, owner claim, or bound identity, so an unrelated
  distro with that name is adopted as managed (see the
  [per-backend clause matrix](../architecture/ownership_invariant.md#per-backend-clause-matrix)). Owed by
  [the host-providers-and-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md).

## Platform reconciliation

`ensure wsl2` installs WSL with `winget`, runs `wsl --install --no-distribution` and
`wsl --set-default-version 2`, and reconciles Windows hypervisor launch. A required Windows reboot is
reported to the operator; the binary does not reboot the host. Its readiness probe and its per-branch
behaviour are canonical in [ensure reconcilers](ensure_reconcilers.md).

The pure `wslNextAction` selects one `WslAction` from platform status, hypervisor presence, and firmware
virtualization availability:

- A ready platform sets its default version to 2, without querying either machine fact.
- A not-ready platform with a running hypervisor selects installation, without querying firmware.
- Without a hypervisor, available virtualization selects installation for an absent platform, or
  `bcdedit /set hypervisorlaunchtype auto` followed by a reboot request for
  `WslVirtualizationUnavailable`.
- With no hypervisor and no OS-visible virtualization, the action refuses with the BIOS/UEFI instruction.

After the installation driver succeeds, the reconciler refreshes tool resolution and runs the same
default-version-2 action as the direct ready path. This also covers the driver's no-op when its later
readiness probe finds an already-ready platform, so that fast path cannot leave the default at version 1.

Hypervisor presence is observed through CPUID leaf 1, ECX bit 31 on supported Windows architectures.
Only when it is absent does the reconciler query native
[Windows processor-feature API](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-isprocessorfeaturepresent).
That flag means virtualization is enabled and available through the operating system; a false result
does not establish that UEFI disabled it. A running hypervisor therefore takes precedence. Unsupported
native observations return an explicit refusal rather than a false machine fact. These observations use
no PowerShell program, and the small CPUID C source is registered on every build with native code behind
platform guards.

`wsl2Ready` makes one `wsl --status` call and delegates to the pure `classifyWslStatus`. After shared
lowercasing and UTF-16 NUL-padding removal, virtualization-disabled text yields
`WslVirtualizationUnavailable` even with exit 0 or a no-distribution marker. Otherwise exit 0 or a
"has no installed distributions" report yields `WslPlatformReady`; other non-zero results and runner
refusals yield `WslPlatformAbsent`. Readiness accepts only `WslPlatformReady` and never queries the online
distribution catalogue. This describes the platform independently of an installed distro; it does not
mint resource readiness authority. Live convergence on a bare Windows host remains owned by the
[Windows/WSL2 acceptance phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md). The
[canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)'s
readiness authority is opaque and resource-indexed. See [readiness](../architecture/readiness.md).

The common provider discovery/capability boundary is implemented, and the prepared provider mutation
backend covers Incus and Direct. WSL2 provider mutation — wall apply and release, distro install,
`wsl --shutdown`, and guarded `wsl --unregister` — runs as described host effects through the one effect
interpreter. The WSL2 application of the shared guest-VM backend opens only after that host-effect
transaction has established the provider, and it supplies only the typed readiness and share reprobe
carried to child frames.

The WSL2 backend is an application of the one guest-VM row described in [lima](lima.md), not a second
constructor: it supplies the Windows host guard, the closed WSL2 provider kind, the WSL tool, and its own
refusal wording, and the guard sequence beneath it is shared. Its host guard asks for the host's **host
frame** (`substrateFrame`, which collapses the five substrate classifications to three host frames; see the
[glossary](../README.md#glossary)) and admits `WindowsFrame`, rather than reading the accelerator row,
because both Windows classifications realize the same provider and keying on the GPU row alone refused a
`windows-cpu` host outright.

The thin Python bootstrap happens before this provider exists. It requires winget and Windows
PowerShell, but downloads the pinned GHCup executable directly with `Invoke-WebRequest`; winget does not
install the Haskell toolchain. See
[Python/Haskell boundary](../architecture/python_haskell_boundary.md).

## Resource wall and global effect

WSL2 has no per-distro CPU or memory limit. The provider merges managed `[general]`/`[wsl2]` sections
into the user's global `%UserProfile%\.wslconfig`. Initial creation follows that write with
`wsl --shutdown` before install. On an existing distro, current reconcile re-acquires the wall but runs
shutdown only when the distro is stopped; a running distro is deliberately left live, so changed
CPU/memory values may not take effect during that invocation. A file rewrite is therefore not an applied
cordon.

The production wall acquire (`applyCurrentUserGlobalWall`) returns the applied file record or a
`HostWallError`, and the release (`restoreCurrentUserGlobalWall`) returns success or a `HostWallError`. The
typed settlement kernel (target contract, below) instead classifies the provider's report as a
`WallAcquireObservation`. The permit mint (`withProviderWallSettlementPermitFromObservation`) admits only a
successful observation with a positive epoch, and `settleProviderWallCall` settles the permit:

| `WallAcquireObservation` | Contract | Tree |
|---|---|---|
| `WallApplied` (positive epoch) | `Changed Created`, minting the live authority | as the contract |
| `WallAlreadyExact` (positive epoch) | `Unchanged`, minting the live authority | as the contract |
| `WallMigrated` (positive epoch) | `Changed Repaired`, minting the live authority | refused at the mint as a non-owning observation (`Failure`, `DoNotRetry`) |
| `WallRefused`, `WallAcquireFailed`, `WallAcquireUncertain`, or a zero epoch | refused at the mint; never reaches settlement | as the contract (`Failure`, `DoNotRetry`) |

Migrated is a lawful acquisition result of the unchanged/migrated/refused contract in
[§ O](../../DEVELOPMENT_PLAN/development_plan_standards.md#o-resource-budget-and-cordoning); the mint's
refusal of it is an open gap (see [Open gaps](#open-gaps)).

The lifecycle never names the file. `spLaunch` emits `ApplyGlobalWslWall <managed body>` and
`spStop`/`spDestroy` emit `ReleaseGlobalWslWall <managed body>`; all three take the same
`ResourceEnvelope`, so teardown releases exactly the wall bring-up applied, and a *different*
declaration is a structured conflict rather than an overwrite. The production entry points
(`applyCurrentUserGlobalWall`, `restoreCurrentUserGlobalWall`) accept no pathname:
`HostBootstrap.Wsl2.GlobalWall.Windows` derives the target `.wslconfig` and the wall's state directory from
the `USERPROFILE` environment variable. The contract admits only a non-empty absolute `USERPROFILE` and keeps
the location and store accessors private to that module and the test suite. The tree refuses only an unset
`USERPROFILE`, and `HostBootstrap.Wsl2.GlobalWall.Host` exports `openHostWallLocation`,
`hostWallProtectedStore`, and `hostWallActiveRecordKey` from the public library (see [Open gaps](#open-gaps)).

The typed authority chain for this shared state is the target contract of
[§ O](../../DEVELOPMENT_PLAN/development_plan_standards.md#o-resource-budget-and-cordoning). Its kernels live in
`HostBootstrap.Cluster.Budget` and run in the core suites; the production WSL path does not use them
(see [Open gaps](#open-gaps)). In order:

1. Planning derives a pure exact `ProviderWallSpec`, its `EffectiveBudget`, and a proved `BudgetPartition`
   before touching the shared file.
2. The same-spec `ProviderWallReservation` is minted only from the exact plan/provider operation's durable
   `PreparedGate`. It carries that gate's session, fence, attempt, and journal version; it is journal
   lineage, not an OS handle.
3. The WSL owning adapter consumes the reservation and holds clause 1's exclusive lock — a lock the
   operating system releases if the process dies — across the initial shared-wall call.
4. The adapter's package-private bridge turns the backend's own result into a `ProviderWallSettlementPermit`;
   a raw observation supplied by a caller cannot produce one.
5. `settleProviderWallCall` consumes the permit and, for an applied, unchanged, or migrated result, mints
   the live `ProviderWallAuthority` together with the epoch-indexed `WslGlobalWallLease`. The lease is an
   output of this step, never an input to it. A refused, failed, or uncertain result is refused at the
   mint and yields no mutation authority.
6. Every later reconcile or restore requires the live authority, the lease, and the exact partition
   projection, and revalidates the wall epoch and fence at the call.

The wall is acquired through the host-wall backend, which holds all four
[ownership invariant](../architecture/ownership_invariant.md) clauses. A backup pathname alone cannot
prove ownership: it records no absent origin, cannot bind the live object's identity, and cannot exclude
concurrent cooperating mutations.

The implementation is split so that the ownership logic is not Windows-only:

| Module | Role |
|--------|------|
| `HostBootstrap.Wsl2.GlobalWall` | the pure phase machine, receipts, and conflicts; settlement (`settleWallApply`) returns a `WallReceipt`, and a `WallAuthority` exists only inside `withWallAuthority` over that receipt |
| `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` | the byte-exact UTF-8/UTF-16 managed-section merge |
| `HostBootstrap.Wsl2.GlobalWall.Host` | the recovery driver and durable record codec |
| `HostBootstrap.Wsl2.GlobalWall.Windows` | where the one wall is, and nothing else |

The wall is one owned object among several, so its clauses come from the shared rows rather than from a
seam of its own: the identity read, the exclusive open, the whole-object read, the create-exclusive, the
no-replace link, and the removal are the row the gate host declares (see
[ownership seam](../architecture/ownership_seam.md)). What stays here is what is genuinely the wall's:
its phase machine, its conflicts, and the pure transformer that derives the managed body so the file's
content is produced rather than edited in place.

Clauses 1 and 2 are the wall's own `ProtectedStore`, opened beside the target under
`%UserProfile%\.hostbootstrap\global-wall`. That is the same exclusive entry and the same
compare-and-swap the run's data root and generated config hold, so there is one exclusive open beneath
every host-local owner — and the wall carries no lock file, no journal file, and no fence file of its
own. Its strictly monotonic, never-reused fence is that store's own record version: versions increase on
every write to one record and the fence record is never deleted.

Staging is two names rather than a move. The armed object is created exclusively, its identity is
recorded, and only then is the durable stage name *linked* to it — which is why the seam's no-replace
publication is a link that leaves its source rather than a move. That order is what makes the
create-outcome-unknown phase resolvable: an armed leftover at a name embedding this receipt's
never-reused fence is this owner's own interrupted attempt on every host, so it is removed by exact
identity inside the same exclusive entry and the create retried, and its unknown bytes are never
published.

On Windows the row uses public `Win32` types and wrappers where they preserve the required semantics, and
a narrow direct `kernel32` boundary for status-sensitive calls whose public wrappers do not expose the
exact `GetLastError` result. It adds no C shim, no Cabal `c-sources`, and no private `Win32` import.
`getFileInformationByHandle`'s `bhfiVolumeSerialNumber`/`bhfiFileIndex` pair supplies the identity, and
`LockFileEx` with `LOCKFILE_EXCLUSIVE_LOCK` the exclusive open. The identity assumes the 64-bit file index
is unique, which holds on NTFS but not on ReFS. The row does not check the filesystem type: the only
`OwnershipUnsupported` it returns is a `CreateHardLinkW` refusal reporting a different device or no
hard-link support, so a non-NTFS volume that supports hard links is trusted rather than refused (see
[Open gaps](#open-gaps) and [ownership invariant](../architecture/ownership_invariant.md)). A byte-range
lock is not affine to the acquiring OS thread, so the row needs neither a named mutex nor the threaded
RTS.

Because the driver takes its primitives from a row, every phase, conflict, and crash-resume branch is
executed against a real kernel on whichever kernel the gate host runs — `device:inode` identity, an
`fcntl` exclusive open and `link(2)` on POSIX, the handle-based pair and `CreateHardLinkW` on Windows.
The shared pure model and codec suites remain platform-neutral. A run of the driver suite is therefore
evidence for the one row that ran it; confirming it against the other row is a second gate host's, and
that is the [host-portability acceptance phase](../../DEVELOPMENT_PLAN/phase-29-host-portability-acceptance.md)'s.
`WslGlobalWallWindowsSpec` compiles and runs on every gate host. It holds one case asserting that the
Win32 row's own declaration agrees with the gate host, and three row cases (absent origin, present origin,
replacement) that on Windows drive the production entry points against a temporary `USERPROFILE` and
elsewhere assert the row's declared refusal. The broader WSL2 provider lifecycle matrix is separate from
this focused adapter coverage.

A crash-resume branch is entered by writing the durable state an interruption leaves — a value — through
that same protected store and re-entering the ordinary entry point. The driver carries no crash point and
no injected seam for a test to reach.

Shutdown affects the shared WSL utility VM and stops every distro, so it is a global side effect rather
than a project-local wall.

The managed body includes processors, memory, swap equal to the memory amount, and idle-timeout settings.
Storage is the per-distro `--vhd-size` cap supplied only when the selected install route registers a new
distro. The current existing-distro path neither observes nor resizes its VHDX, so that cap is not an
effective-wall reconciliation. Windows capacity preflight includes system-drive free space.

## Wall release

Lima and Incus release their walls when the project stops: `limactl stop` and `incus stop` return the VM's
CPU and memory to the host. WSL2 releases its shared utility-VM wall through two coordinated teardown
effects on `project down`.

The managed body uses finite idle timeouts: six hours in milliseconds for
`[general] instanceIdleTimeout` and `[wsl2] vmIdleTimeout`, derived from
the single `managedWslIdleTimeoutHours` constant in `HostBootstrap.Cluster.Cordon.Foundation` (and
reexported by the configuration facade). The six-hour ceiling exceeds the observed acceptance duration
recorded in the [Windows and WSL2 acceptance phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md),
allowing the observed gaps between its `wsl -d` steps. These finite timeouts are an interrupted-run
backstop: `project down` does not wait for either timeout to expire.

`project down` emits `ReleaseGlobalWslWall` followed by `wsl --shutdown`. The order is load-bearing: the
utility VM re-reads the file on its next cold boot, so releasing *after* shutdown would publish the
managed body one more time. Release restores the exact origin bytes, or their absence, from the
journalled origin record; a foreign replacement of the managed file is refused as a `Conflict` and left
intact rather than deleted. Shutdown is the same disclosed global side effect already performed on
bring-up, stops every WSL distro, and returns the utility VM's CPU and memory to the host.

The two effects run in order and the release can stop the list:

- A release refusal — a `Conflict` or any other `HostWallError` — fails `project down` before
  `wsl --shutdown`; the utility VM keeps running with whatever configuration it booted with.
- A project with no journalled wall (`HostWallNoActiveRecord`) reports that it held no wall and continues to
  the shutdown.
- A failing `wsl --shutdown` is reported as skipped, because teardown commands run best-effort.

The provider stops with global `wsl --shutdown` rather than a per-distro `wsl --terminate`. Terminating
the one distro leaves the shared utility VM — and the CPU and memory ceiling it booted with — running until
`vmIdleTimeout` expires; only stopping the utility VM returns that memory and makes the next cold boot
read the restored file.

`project destroy` emits guarded `wsl --unregister` and then `ReleaseGlobalWslWall`, with no
`wsl --shutdown`. The release restores the file, but a utility VM that is still running keeps the managed
ceiling until it idles out after `vmIdleTimeout` or an operator runs `wsl --shutdown`; the restored
configuration takes effect at the utility VM's next cold boot (see [Open gaps](#open-gaps)).

If a run is interrupted before `project down` reaches these effects, an operator can still run
`wsl --shutdown` by hand. It deletes no distro and no data, but it terminates every running distro,
including ones unrelated to this project, and the utility VM restarts on next use. See
[durable Windows runs](durable_windows_runs.md) for why a finished-looking session may still be holding
the wall.

## Durable share

WSL drvfs already exposes the Windows project directory below `/mnt/<drive>/...`; no attach command is
needed. The provider waits for that path and reconciles the stable Docker-visible alias
`/var/tmp/hostbootstrap-demo-data`, which is then carried through kind and the pod.

The common prepared alias backend is the `StrongAliasBackend` that `discoverStrongAliasBackend` mints
from the exact opaque managed WSL provider and share authorities. It ships one closed symbolic-link act
to the project binary already installed in the guest, so there is no guest interpreter program and no
discovered `flock`, `stat`, or Python front end to choose between: the ownership row and kernel in the
frame that owns the link answer all four clauses. Its explicit-absence/fresh-nonce `prepared` record lives inside that host-backed drvfs
target, is fsynced and read back before the alias effect, and is bound to the symlink's exact device/inode
in `managed`. Conditional release first persists the observation-version-fenced `releasing` record and
then removes only that exact identity. Crash retries recover each durable state rather than adopting an
exact-looking pathname.

The worked demo adopts this route in its `copy-source` node through `runExactVmShare` in
[HostBootstrapDemo.Commands](../../demo/src/HostBootstrapDemo/Commands.hs). It prepares and settles the
exact provider share, keeps the managed provider and share authorities inside
`withProviderShareSettlement`, and derives a fresh provider capability. `discoverStrongAliasBackend`
narrows that capability for `reconcileNodeGuestAlias`. Mount validation and alias settlement complete
before that continuation registers the share's runtime dependency. Direct-host builds use the canonical
host path and create no alias.

The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns the shared implementation
and baseline destroy/up/readback gate. Dated hardware acceptance and remaining work belong to the
[Apple Silicon](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md),
[NVIDIA](../../DEVELOPMENT_PLAN/phase-27-nvidia-gpu-substrate.md), and
[Windows and WSL2](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md) phases. See
[durable state](../architecture/durable_state.md) for the ownership contract.

## Lifecycle caveat

Teardown visits the authenticated WSL child before its parent shuts down the utility VM or unregisters
the distro.
Unregister removes the distro VHDX; durable `.data` is the plan-owned host share outside it. The
[Windows and WSL2 acceptance phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md) records
the concrete reverse and durable-readback gate.

## Validation

The [Windows and WSL2 acceptance phase](../../DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md)
owns the complete recursive teardown and durable-readback matrix and its terminal ownership audit. It
records dated native command results and wall-release and recovery observations; its gate evidence and
remaining work state the current acceptance coverage. The
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns validation of the shared
implementation.

Phase status belongs in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [Incus](incus.md), [Lima](lima.md) — peer provider implementations, and the wall-release behavior this
  provider must match.
- [ownership invariant](../architecture/ownership_invariant.md) — the four clauses the `.wslconfig`
  backend must hold, and their Windows realization.
- [durable state](../architecture/durable_state.md) — drvfs carry and stable alias.
- [applied cordon](applied_cordon.md) — the global WSL2 CPU/memory wall.
- [durable Windows runs](durable_windows_runs.md) — why a detached gate can still be holding the wall.
- [lifecycle state model](../architecture/lifecycle_state_model.md) — target capabilities and ownership.
