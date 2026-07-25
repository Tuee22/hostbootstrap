# WSL2 Host Provider

**Status**: Authoritative source
**Supersedes**: the cached-rootfs/`wsl --import` runtime narrative
**Referenced by**: [documents index](../README.md), [applied cordon](applied_cordon.md), [resource budgeting](resource_budgeting.md), [ensure reconcilers](ensure_reconcilers.md), [durable state](../architecture/durable_state.md)

> **Purpose**: Describe the active Windows WSL2 provider and distinguish it from unused import
> builders and historical validation claims.

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

Pure `wsl --import`/rootfs helpers still exist, but the current provider does not download or consume a
cached rootfs tarball. Documentation must not present that older design as the live path.

## Platform reconciliation

`ensure wsl2` handles WSL/VMP feature and platform readiness. A required Windows reboot is reported to
the operator; the binary does not reboot the host. Readiness is not yet an unforgeable universal
capability—see [readiness](../architecture/readiness.md).

The thin Python bootstrap happens before this provider exists. It requires winget and Windows
PowerShell, but downloads the pinned GHCup executable directly with `Invoke-WebRequest`; winget does not
install the Haskell toolchain. See
[Python/Haskell boundary](../architecture/python_haskell_boundary.md).

## Resource wall and global effect

WSL2 has no per-distro CPU or memory limit. The provider merges managed `[general]`/`[wsl2]` sections
into the user's global `%UserProfile%\.wslconfig`. Initial creation follows that write with
`wsl --shutdown` before install. On an existing distro, current reconcile merges the file again but runs
shutdown only when the distro is stopped; a running distro is deliberately left live, so changed
CPU/memory values may not take effect during that invocation. The target must return
`Unchanged | Migrated | Refused` from an observation of the effective wall rather than calling a file
rewrite an applied cordon.

Target planning derives a pure exact `ProviderWallSpec ... wallSpecId`, `EffectiveBudget`, and proved
`BudgetPartition` before touching this shared state. A journaled same-spec reservation plus exclusive
platform lock/CAS authorizes the initial shared-wall call. The `ProviderWallReservation ... reservationId
fence` retains that lock across the call; only authoritative applied/unchanged observation consumes it and
jointly mints the live `ProviderWallAuthority ... wallSpecId wallEpoch fence` plus epoch-indexed
`WslGlobalWallLease`. The post-observation lease is not circularly required before it exists. An unknown
result exposes recovery/reprobe state, not later mutation authority. Subsequent reconciliation or
restoration requires the live authority, lease, and exact partition projection, with the epoch/fence
revalidated at the call.

The provider later restores a saved original when one existed. If the original file was absent and a run
crashes after its first write, current backup-exists inference has no durable absence marker: retry can
save the generated file as the “original” and teardown then restores generated content instead of
absence. Sprint 11.10's target records present bytes or absent state in an identity-bound receipt before
mutation and restores only through that receipt. Shutdown affects the shared WSL utility VM and stops
every distro, so it is a global side effect rather than a project-local wall.

The managed body includes processors, memory, swap equal to the memory amount, and idle-timeout settings.
Storage is the per-distro `--vhd-size` cap supplied only when the selected install route registers a new
distro. The current existing-distro path neither observes nor resizes its VHDX, so that cap is not an
effective-wall reconciliation. Windows capacity preflight includes system-drive free space.

## Durable share

WSL drvfs already exposes the Windows project directory below `/mnt/<drive>/...`; no attach command is
needed. The provider waits for that path and reconciles the stable Docker-visible alias
`/var/tmp/hostbootstrap-demo-data`, which is then carried through kind and the pod.

The direct alias implementation has a separate first-run bug; WSL and all other lanes still lack the
required destroy/up/readback proof. See [durable state](../architecture/durable_state.md).

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

- [Incus](incus.md), [Lima](lima.md) — peer provider implementations.
- [durable state](../architecture/durable_state.md) — drvfs carry and stable alias.
- [applied cordon](applied_cordon.md) — the global WSL2 CPU/memory wall.
- [lifecycle state model](../architecture/lifecycle_state_model.md) — target capabilities and ownership.
