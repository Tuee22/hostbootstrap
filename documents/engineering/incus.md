# Incus Host Provider

**Status**: Authoritative source
**Supersedes**: the claim that `HostTarget`/`runInTarget` and `rebootDockerToReady` drive the live provider
**Referenced by**: [ensure reconcilers](ensure_reconcilers.md), [applied cordon](applied_cordon.md), [durable state](../architecture/durable_state.md), [lifecycle state model](../architecture/lifecycle_state_model.md)

> **Purpose**: Describe the active Incus provider path and identify stale provider abstractions that
> remain in source but are not the runtime architecture.

## Current Status

Native Linux CPU uses an Incus VM as its provider frame. The project selects a
`SubstrateProvider` whose `LiftLayer`, launch/stop/destroy effects, shell arguments, file-push arguments,
optional resource-reconcile action, and host-share reconcile describe Incus. For Incus the optional
resource reconcile is absent. Generic provider code interprets those fields:

- on first creation, launch the named VM with `limits.cpu`, `limits.memory`, and `root,size`;
- when the named VM already exists, run only `incus start` without comparing or changing those limits;
- attach the host `.data` share as an Incus disk device;
- wait for VM/network/share readiness;
- stage source/config and build/install the project binary;
- hand off the project subcommand with `incus exec`;
- stop on `project down`, or force-delete the guarded project VM on `project destroy`.

Host-side `incus` is resolved through `HostTool`; commands inside the guest intentionally use the
guest's own tool lookup.

## Stale surfaces

`HostTarget = Local | InVM IncusVM`, `runInTarget`, the Docker-readiness classifier associated with it,
and `rebootDockerToReady` still exist in the source tree, but they have no production call sites in the
demo provider lifecycle. They are not the central dispatch point and must not be taught as the active
architecture.

The target is one provider abstraction, not parallel `HostTarget` and `SubstrateProvider` models:

- provider-specific data builds one typed provider value;
- generic folds interpret launch, shell, copy, share, stop, and destroy;
- every reconcile returns an explicit create/adopt/repair/no-op/conflict result;
- readiness and destructive actions consume opaque capabilities/ownership tokens.

The capability contract lives in
[lifecycle state model](../architecture/lifecycle_state_model.md).

## Lifecycle caveat

The current root teardown does not recursively enter the Incus child and invoke the lifecycle verb before
stopping/deleting the VM. It invokes current-frame cleanup and then the demo's provider teardown hook.
Deleting the VM removes nested compute incidentally. See
[cluster lifecycle](cluster_lifecycle.md).

The host durable root is carried into Incus through a disk device and exposed to Docker through
`/var/tmp/hostbootstrap-demo-data`; it is not merely guest-root-disk state. The destroy/up/readback
guarantee remains unvalidated. See [durable state](../architecture/durable_state.md).

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
a stale outer wall. Sprint 9.10 owns `Unchanged | Migrated | Refused` existing-wall reconciliation.

## Validation

Current unit coverage of argv builders is not a provider closure gate. Closure requires a native Linux
run proving create/no-op/restart, share readiness, durable readback, recursive teardown ordering, and
ownership-safe destroy. Status and scheduling belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [WSL2](wsl2.md) and [Lima](lima.md) — peer provider values.
- [durable state](../architecture/durable_state.md) — Incus host share and stable alias.
- [applied cordon](applied_cordon.md) — resource parsing and walls.
- [composition methodology](../architecture/composition_methodology.md) — frame handoff.
