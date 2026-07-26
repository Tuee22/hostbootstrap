# Incus Host Provider

**Status**: Authoritative source
**Supersedes**: the historical `HostTarget`/`runInTarget` and demo-local provider-readiness paths
**Referenced by**: [ensure reconcilers](ensure_reconcilers.md), [applied cordon](applied_cordon.md), [durable state](../architecture/durable_state.md), [lifecycle state model](../architecture/lifecycle_state_model.md)

> **Purpose**: Describe the active Incus provider path, its total capability probe, and the remaining
> provider-lifecycle limits without presenting deleted predecessor abstractions as current.

## Current Status

Native Linux CPU uses an Incus VM as its provider frame. The project selects a
`SubstrateProvider` whose `LiftLayer`, launch/stop/destroy effects, shell arguments, file-push arguments,
optional resource-reconcile action, and host-share reconcile describe Incus. For Incus the optional
cordon reconcile is absent. Generic provider code interprets those fields:

- on first creation, launch the named VM with `limits.cpu`, `limits.memory`, and `root,size`;
- when the named VM already exists, run only `incus start` without comparing or changing those limits;
- attach the host `.data` share as an Incus disk device;
- wait for VM/network/share readiness;
- stage source/config and build/install the project binary;
- hand off the project subcommand with `incus exec`;
- stop on `project down`, or force-delete the guarded project VM on `project destroy`.

Host-side `incus` is resolved through `HostTool`; commands inside the guest intentionally use the
guest's own tool lookup.

Before that provider value is used, `HostBootstrap.Ensure.Incus` converges the native provider and runs
a total final observation. Its pure `IncusProviderStatus` distinguishes:

- missing client;
- absent, permission-denied, or otherwise unreachable daemon;
- missing KVM/QEMU/OVMF VM capability;
- unavailable image-server egress; and
- fully ready.

Only the final branch can mint the opaque `IncusProviderCapability`. On Linux the reconcile path installs
the client plus ACL support, initializes/restarts the daemon when needed, establishes immediate socket
access, installs QEMU/OVMF, preserves the Incus bridge through `DOCKER-USER`, and re-runs the complete
probe. The former demo-local `ensureIncusProvider` compensation was deleted. Apple uses the same final
capability observation after converging its Colima-backed Incus provider.

`SubstrateProvider` plus `Lift` is the single provider/dispatch model. The former public
`HostBootstrap.HostTarget` module, its result-free reboot loop, and the unconsumed reboot/readiness
helpers were deleted.

The Incus capability is deliberately narrow: it proves the final provider observation made by the
reconciler, not permanent readiness, ownership of a VM, or authorization for an unrelated mutation.
Prepared provider operations and receipt-driven teardown still follow the general contract in
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Lifecycle caveat

The current root teardown does not recursively enter the Incus child and invoke the lifecycle verb before
stopping/deleting the VM. It invokes current-frame cleanup and then the demo's provider teardown hook.
Deleting the VM removes nested compute incidentally. See
[cluster lifecycle](cluster_lifecycle.md).

The host durable root is carried into Incus through a disk device and exposed to Docker through
`/var/tmp/hostbootstrap-demo-data`; it is not merely guest-root-disk state. The destroy/up/readback
guarantee remains unvalidated. The ordinary guest alias pathname also cannot mint the standards'
same-privilege-resistant ownership receipt; that provider projection remains an open Sprint 11.10
integration item. See [durable state](../architecture/durable_state.md).

## Resource wall

`incusSizingArgs` applies:

```text
limits.cpu=<N>
limits.memory=<GiB>GiB
root,size=<GiB>GiB
```

These are real per-VM CPU, memory, and storage walls for a newly created VM. Current reconcile-to-running
does not observe an existing VM's effective limits or resize/refuse it when the declaration changes; it
starts the existing VM unchanged. The in-VM kind cluster computes a local slice, but that does not repair
a stale outer wall. Phase 9 supplies the result algebra; Sprints 5.7/11.10 still own its
provider-authoritative Incus application.

## Validation

Current unit coverage of argv builders is not a provider closure gate. Closure requires a native Linux
run proving create/no-op/restart, share readiness, durable readback, recursive teardown ordering, and
ownership-safe destroy. The total probe table is unit-tested, but a macOS run is not evidence for this
native-Linux gate. Status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [WSL2](wsl2.md) and [Lima](lima.md) — peer provider values.
- [durable state](../architecture/durable_state.md) — Incus host share and stable alias.
- [applied cordon](applied_cordon.md) — resource parsing and walls.
- [composition methodology](../architecture/composition_methodology.md) — frame handoff.
