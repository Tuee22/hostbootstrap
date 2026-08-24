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

The active lower-boundary separation assigns pure `Wsl2VM` target data and the inner
`wsl -d <distro> -- ...` renderer to `HostBootstrap.Lift.Context`. `HostBootstrap.Wsl2` reexports them and
owns distro/lifecycle builders. For compatibility it reexports prerequisite helpers whose implementations
— diagnostics, output normalization, virtualization classification, and `bcdedit` rendering — are owned by
`HostBootstrap.Ensure.Wsl2`. The active
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
and [ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) pin that dependency
direction.

The selected `SubstrateProvider` is abstract and carries the complete lower `LiftContext` without exposing
construction or record update. Common discovery owns closed daemon, permission, VM, and egress requests,
accepts only raw outcomes from its executor, and privately classifies the complete result vocabulary —
that classification being a total function over a closed sum, so it is reached by application rather than
through a substitution point. Tool paths, markers, identities, and backend reports must be exact
single-line results. Its fresh generative capability is post-settlement and indexed to the exact opaque
managed provider/backend/generation; provider mutation does not consume it. This is the same interface
used by Incus and Lima rather than a WSL-specific dispatch fold.

It then enters the distro with `wsl -d <distro> -- ...`, stages source, builds/installs the Linux project
binary, ensures the in-distro Docker daemon, builds the project image, and hands the chain into the
container frame. `project down` restores the journalled global-wall origin and then runs global
`wsl --shutdown`; `project destroy` additionally uses guarded `wsl --unregister`. The guard is the one
every frame's destructive removal goes through, not a WSL2 copy of it: this provider supplies only the noun
its refusal reads in and the argument vector for a name the guard has already admitted. A distro outside
the project's namespace refuses, and so do the two degenerate inputs that make the guard vacuous — an empty
prefix, which is a prefix of every name, and an empty distro name.

The unused `wslImportArgs`/cached-rootfs builder was deleted. `wslInstallArgs` is now the sole
registration builder and has both a production consumer and tests.

## Platform reconciliation

`ensure wsl2` handles WSL/VMP feature and platform readiness. A required Windows reboot is reported to
the operator; the binary does not reboot the host. The
[canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)'s
readiness authority is opaque and resource-indexed. The common provider discovery/capability boundary is
implemented, while the baseline prepared provider mutation backend covers Incus and Direct; native WSL2
mutation confirmation remains in the
[Windows-and-WSL2-substrate phase](../../DEVELOPMENT_PLAN/phase-27-windows-and-wsl2-substrate.md). See
[readiness](../architecture/readiness.md).

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
`%UserProfile%` where the wall lives, never from caller input.

Target planning derives a pure exact `ProviderWallSpec ... wallSpecId`, `EffectiveBudget`, and proved
`BudgetPartition` before touching this shared state. The same-spec reservation is minted only from the exact
plan/provider operation's durable `PreparedGate`; it retains that gate's session, fence, attempt, and journal
version, not an OS handle. The exact WSL owning adapter consumes the reservation and retains the OS-released
exclusive lock of clause 1 across the initial shared-wall call. Only its package-private backend-result bridge
may produce the settlement permit that jointly mints the live
`ProviderWallAuthority ... wallSpecId wallEpoch fence` plus epoch-indexed `WslGlobalWallLease`; a caller-shaped
raw observation cannot do so. The post-observation lease is not circularly required before it exists. An
unknown result exposes recovery/reprobe state, not later mutation authority. Subsequent reconciliation or
restoration requires the live authority, lease, and exact partition projection, with the epoch/fence
revalidated at the call.

The wall is acquired through the host-wall backend, which holds all four
[ownership invariant](../architecture/ownership_invariant.md) clauses. A backup pathname alone cannot
prove ownership: it records no absent origin, cannot bind the live object's identity, and cannot exclude
concurrent cooperating mutations.

The implementation is split so that the ownership logic is not Windows-only:

| Module | Role |
|--------|------|
| `HostBootstrap.Wsl2.GlobalWall` | the pure phase machine, receipts, and conflicts |
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
`LockFileEx` with `LOCKFILE_EXCLUSIVE_LOCK` the exclusive open. The 64-bit file index is unique and
stable on NTFS; a non-NTFS profile volume returns `Unsupported` rather than assuming it. A byte-range
lock is not affine to the acquiring OS thread, so the row needs neither a named mutex nor the threaded
RTS.

Because the driver takes its primitives from a row, every phase, conflict, and crash-resume branch is
executed against a real kernel on whichever kernel the gate host runs — `device:inode` identity, an
`fcntl` exclusive open and `link(2)` on POSIX, the handle-based pair and `CreateHardLinkW` on Windows.
The shared pure model and codec suites remain platform-neutral. A run of the driver suite is therefore
evidence for the one row that ran it; confirming it against the other row is a second gate host's, and
that is the [host-portability acceptance phase](../../DEVELOPMENT_PLAN/phase-28-host-portability-acceptance.md)'s.
Windows-gated validation exercised the production entrypoint directly against a temporary `USERPROFILE`;
its native apply/restore/origin/replacement cases passed. The broader WSL2 provider lifecycle matrix
remains separate from this focused adapter evidence.

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
CPU and memory to the host. WSL2 now releases its shared utility-VM wall through two coordinated teardown
effects.

The managed body uses finite idle timeouts: six hours in milliseconds for
`[general] instanceIdleTimeout` and `[wsl2] vmIdleTimeout`, derived from
the single `managedWslIdleTimeoutHours` constant in `HostBootstrap.Cluster.Cordon.Foundation` (and
reexported by the configuration facade). Six hours is an order of magnitude beyond the longest lifecycle
this project runs, so no run can be idle-stopped in the gaps between its `wsl -d` steps. These finite
timeouts are an interrupted-run backstop: normal teardown does not wait for either timeout to expire.

`project down` emits `ReleaseGlobalWslWall` followed by `wsl --shutdown`. The order is load-bearing: the
utility VM re-reads the file on its next cold boot, so releasing *after* shutdown would publish the
managed body one more time. Release restores the exact origin bytes, or their absence, from the
journalled origin record; a foreign replacement of the managed file is refused as a `Conflict` and left
intact rather than deleted. Shutdown is the same disclosed global side effect already performed on
bring-up, stops every WSL distro, and returns the utility VM's CPU and memory to the host.

If a run is interrupted before `project down` reaches these effects, an operator can still run
`wsl --shutdown` by hand; it is non-destructive, stops every distro, and the utility VM restarts on next
use. See
[durable Windows runs](durable_windows_runs.md) for why a finished-looking session may still be holding
the wall.

## Durable share

WSL drvfs already exposes the Windows project directory below `/mnt/<drive>/...`; no attach command is
needed. The provider waits for that path and reconciles the stable Docker-visible alias
`/var/tmp/hostbootstrap-demo-data`, which is then carried through kind and the pod.

The common prepared alias backend uses the WSL guest facts and hidden guest executor retained by discovery
for the exact opaque managed WSL provider and share authorities. It admits only retained `GuestFlock`; a
discovered `GuestLockf` remains descriptive `Unsupported` because the lock namespaces are not
interchangeable. Its explicit-absence/fresh-nonce `prepared` record lives inside that host-backed drvfs
target, is fsynced and read back before the alias effect, and is bound to the symlink's exact device/inode
in `managed`. Conditional release first persists the observation-version-fenced `releasing` record and
then removes only that exact identity. Crash retries recover each durable state rather than adopting an
exact-looking pathname.

The worked demo still has to adopt this route in place of its legacy pathname call; that call site cannot
supply an identity-authoritative cleanup receipt. Direct-host builds use the canonical host path and
create no alias. All lanes also lack the required destroy/up/readback proof. See
[durable state](../architecture/durable_state.md) and the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

## Lifecycle caveat

Current teardown is a root cleanup plus project provider hook, not recursive dispatch through the WSL
child before termination/unregister. WSL unregister removes the distro VHDX, but host-shared `.data`
should remain outside it; that outcome is not yet live-gated.

## Validation

The current Windows `project up`/`project down` gate exercised the wall-release observable: the
managed wall was active during bring-up, teardown restored an absent `.wslconfig` origin exactly, and
the following global shutdown left neither a running distro nor a resident utility VM. Dated command
and test detail belongs in the
[Windows-and-WSL2-substrate phase](../../DEVELOPMENT_PLAN/phase-27-windows-and-wsl2-substrate.md).

That earlier result does not close the current WSL2 hardware acceptance. Existing-VHDX reconciliation,
fresh verification of recursive teardown and durable readback, and the remaining native provider matrix stay
open in their owning phase.

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
