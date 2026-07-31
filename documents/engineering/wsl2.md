# WSL2 Host Provider

**Status**: Authoritative source
**Supersedes**: the cached-rootfs/`wsl --import` runtime narrative, the backup-existence-as-ownership
claim, and the native C-shim wall adapter
**Referenced by**: [documents index](../README.md), [applied cordon](applied_cordon.md), [resource budgeting](resource_budgeting.md), [ensure reconcilers](ensure_reconcilers.md), [durable state](../architecture/durable_state.md)

> **Purpose**: Describe the active Windows WSL2 provider, the selected install route, the exact limits of
> the current global-file reconciliation, and how the shared utility-VM wall is released.

## Current Status

Windows uses a project-owned named Ubuntu 24.04 WSL2 distro as the VM provider frame. The active
registration path uses:

```text
wsl --install -d Ubuntu-24.04 --name <project>-vm --no-launch --vhd-size <GB>
```

It then enters the distro with `wsl -d <distro> -- ...`, stages source, builds/installs the Linux project
binary, ensures the in-distro Docker daemon, builds the project image, and hands the chain into the
container frame. `project down` uses per-distro termination; `project destroy` uses guarded
`wsl --unregister`.

The unused `wslImportArgs`/cached-rootfs builder was deleted. `wslInstallArgs` is now the sole
registration builder and has both a production consumer and tests.

## Platform reconciliation

`ensure wsl2` handles WSL/VMP feature and platform readiness. A required Windows reboot is reported to
the operator; the binary does not reboot the host. Phase 9 readiness authority is now opaque and
resource-indexed, but this live provider path has not yet adopted the universal prepared-operation
boundary—see [readiness](../architecture/readiness.md).

The thin Python bootstrap happens before this provider exists. It requires winget and Windows
PowerShell, but downloads the pinned GHCup executable directly with `Invoke-WebRequest`; winget does not
install the Haskell toolchain. See
[Python/Haskell boundary](../architecture/python_haskell_boundary.md).

## Resource wall and global effect

WSL2 has no per-distro CPU or memory limit. The provider merges managed `[general]`/`[wsl2]` sections
into the user's global `%UserProfile%\.wslconfig`. Initial creation follows that write with
`wsl --shutdown` before install. On an existing distro, current reconcile re-acquires the wall but runs
shutdown only when the distro is stopped; a running distro is deliberately left live, so changed
CPU/memory values may not take effect during that invocation. The target must return
`Unchanged | Migrated | Refused` from an observation of the effective wall rather than calling a file
rewrite an applied cordon.

The lifecycle never names the file. `spLaunch` emits `ApplyGlobalWslWall <managed body>` and
`spStop`/`spDestroy` emit `ReleaseGlobalWslWall <managed body>`; all three take the same
`ResourceEnvelope`, so teardown releases exactly the wall bring-up applied, and a *different*
declaration is a structured conflict rather than an overwrite. The target is derived from
`%UserProfile%` by the backend itself.

Target planning derives a pure exact `ProviderWallSpec ... wallSpecId`, `EffectiveBudget`, and proved
`BudgetPartition` before touching this shared state. A journaled same-spec reservation plus the
OS-released exclusive lock of clause 1 authorizes the initial shared-wall call. The
`ProviderWallReservation ... reservationId
fence` retains that lock across the call; only authoritative applied/unchanged observation consumes it and
jointly mints the live `ProviderWallAuthority ... wallSpecId wallEpoch fence` plus epoch-indexed
`WslGlobalWallLease`. The post-observation lease is not circularly required before it exists. An unknown
result exposes recovery/reprobe state, not later mutation authority. Subsequent reconciliation or
restoration requires the live authority, lease, and exact partition projection, with the epoch/fence
revalidated at the call.

The wall is acquired through the host-wall backend, which holds all four
[ownership invariant](../architecture/ownership_invariant.md) clauses. The superseded route inferred
ownership from a `.hostbootstrap-demo.bak` pathname: it recorded no *absent* original, so a crash after
the first write let retry save generated content as the “original”, and concurrent runs could overwrite
the global setting.

The implementation is split so that the ownership logic is not Windows-only:

| Module | Role |
|--------|------|
| `HostBootstrap.Wsl2.GlobalWall` | the pure phase machine, receipts, and conflicts |
| `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` | the byte-exact UTF-8/UTF-16 managed-section merge |
| `HostBootstrap.Wsl2.GlobalWall.Host` | the recovery driver, durable record codec, and `HostWallBackend` seam |
| `HostBootstrap.Wsl2.GlobalWall.Windows` | the production Win32 backend |
| `HostBootstrap.Wsl2.GlobalWall.Posix` | the POSIX backend the ungated suite runs the driver against |

On Windows the clauses are realized without a foreign-function boundary, using `Win32`'s existing
bindings: `LockFileEx` with `LOCKFILE_EXCLUSIVE_LOCK` on a per-user lock file for exclusive entry, a
journalled origin record naming exact bytes or absence under `%UserProfile%\.hostbootstrap`, and
`getFileInformationByHandle`'s `bhfiVolumeSerialNumber`/`bhfiFileIndex` pair for identity binding. The
64-bit file index is unique and stable on NTFS; a non-NTFS profile volume returns `Unsupported` rather
than assuming it. A byte-range lock is not affine to the acquiring OS thread, so the adapter needs
neither a named mutex nor the threaded RTS.

Because the driver is backend-parametric, every phase, conflict, and crash-resume branch is executed
against a real kernel on any POSIX host through the second backend — `fcntl` exclusive entry, a journal
file, and `device:inode` identity. A uniform invariant gets a uniform gate. The Win32 backend still owes
a native-Windows run.

Shutdown affects the shared WSL utility VM and stops every distro, so it is a global side effect rather
than a project-local wall.

The managed body includes processors, memory, swap equal to the memory amount, and idle-timeout settings.
Storage is the per-distro `--vhd-size` cap supplied only when the selected install route registers a new
distro. The current existing-distro path neither observes nor resizes its VHDX, so that cap is not an
effective-wall reconciliation. Windows capacity preflight includes system-drive free space.

## Wall release

Lima and Incus release their walls when the project stops: `limactl stop` and `incus stop` return the VM's
CPU and memory to the host. WSL2 does not yet do so at teardown, and the release depends on two separate
changes.

**Landed (Sprint 9.11): the managed body no longer pins the wall open.** Both idle timeouts previously
carried `-1`, so the shared utility VM stayed resident holding the full memory balloon indefinitely — a
`project down` that looked complete could leave the entire budget committed until the next reboot or a
manual `wsl --shutdown`. `-1` was adopted to stop the distro instance idle-stopping mid-run; a generous
**finite** duration prevents that just as well while guaranteeing the host eventually recovers the memory.
The managed body now emits six hours in milliseconds for both `[general] instanceIdleTimeout` and
`[wsl2] vmIdleTimeout`, derived from a single `managedWslIdleTimeoutHours` constant in
`HostBootstrap.Cluster.Cordon` rather than a literal at either call site. Six hours is an order of
magnitude beyond the longest lifecycle this project runs, so no run can be idle-stopped in the gaps
between its `wsl -d` steps.

**Landed (Sprints 11.10/5.7): teardown releases the wall.** `project down` now emits
`ReleaseGlobalWslWall` followed by `wsl --shutdown`. The order is load-bearing — the utility VM re-reads
the file on its next cold boot, so releasing *after* the shutdown would publish the managed body one more
time. The shutdown is the same disclosed global side effect already performed on bring-up. Release
restores the exact origin bytes, or their absence, from the journalled origin record; a foreign
replacement of the managed file is refused as a `Conflict` and left intact rather than deleted.

An operator who needs the memory back outside a `project down` can still run `wsl --shutdown` by hand; it
is non-destructive and the utility VM restarts on next use. See
[durable Windows runs](durable_windows_runs.md) for why a finished-looking session may still be holding
the wall.

## Durable share

WSL drvfs already exposes the Windows project directory below `/mnt/<drive>/...`; no attach command is
needed. The provider waits for that path and reconciles the stable Docker-visible alias
`/var/tmp/hostbootstrap-demo-data`, which is then carried through kind and the pod.

Direct-host builds use the canonical host path and create no alias. Provider guests, including WSL,
still use an ordinary shared alias pathname that cannot supply an identity-authoritative cleanup
receipt; all lanes also lack the required destroy/up/readback proof. See
[durable state](../architecture/durable_state.md).

## Lifecycle caveat

Current teardown is a root cleanup plus project provider hook, not recursive dispatch through the WSL
child before termination/unregister. WSL unregister removes the distro VHDX, but host-shared `.data`
should remain outside it; that outcome is not yet live-gated.

## Validation

Historical Windows runs are evidence, not present-tense closure. The current code has changed since those
runs and the demo profile/durable-readback defects remain open. Closure requires a current Windows run
covering platform reconcile, install/no-op, project up, daemon placement, host durable write,
destroy/up/readback, recursive teardown, and restoration of `.wslconfig`.

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
