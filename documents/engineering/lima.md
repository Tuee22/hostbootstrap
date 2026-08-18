# Lima VM Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [demo runbook](../operations/demo_runbook.md), [wsl2](wsl2.md), [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)

> **Purpose**: Describe the Lima VM provider used on Apple Silicon to represent a pristine Linux
> environment, and how its lifecycle is expressed through the core `deploy-VM` step kind of the
> `project` lift chain.

## TL;DR

- The Apple Silicon VM provider is Lima, reached through the resolved `HostTool Lima`
  (`toolCommandName Lima = "limactl"`).
- `ensure lima` installs the provider with Homebrew when `limactl` is absent. It runs as part of the
  `deploy-VM` bring-up inside `project up`.
- The active lower-boundary separation assigns the pure `LimaVM` target and inner `limactl shell` renderer
  to `HostBootstrap.Lift.Context`. `HostBootstrap.Lima` reexports them and owns lifecycle builders for
  `limactl start`, `limactl copy`, `limactl list`, guarded `limactl delete`, and `limactl stop` (the
  stop-without-delete capability).
- The VM lifecycle is driven by the core `deploy-VM` step kind plus the project teardown: `project up`
  brings the named instance up, `project down` stops it without deleting, and `project destroy` deletes
  the instance **and its disk**. Host durable `.data` is mounted from outside that disk.
- Source staging through `copyToVMArgs` is one-way. Durable data uses a separate Lima host-path mount,
  which is visible from both host and guest through the stable alias. See
  [durable state](../architecture/durable_state.md).
- On Apple Silicon a real Lima VM is the pristine host; native Linux uses the Incus VM path. The Step
  algebra is shared — only the provider builders differ.
- The recursive `project` interpreter drives these steps across the composed frame stack.

## Provider Contract

Lima is the Apple Silicon VM provider for the pristine Linux host. The chain provisions a named
`ubuntu-24.04` instance, stages the working tree into the guest, builds the project binary in the VM,
ensures Docker in the VM, builds the project image, and runs the workload against the VM's Docker daemon.
Each of those is a [`Step`](../architecture/composition_methodology.md), and the Lima provider supplies
the VM-level steps of that chain. Its selected `SubstrateProvider` is abstract and carries the complete
lower `LiftContext` without exposing construction or record update. The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
implements common discovery as closed daemon, permission, VM, egress, and guest-tool requests over raw
outcomes. Private parsers require strict single-line tool/marker/identity reports and bound retry to
`NotReady`. Discovery runs after provider settlement when guest facts are needed; its generative capability
is descriptive and indexed to the exact opaque managed provider/backend/generation, never mutation
authority. Native Lima confirmation remains in the
[Apple-Silicon-substrate phase](../../DEVELOPMENT_PLAN/phase-25-apple-silicon-substrate.md).

The pure command shapes are:

```text
# create a new instance
limactl start -y --timeout 15m --name=<instance> --containerd none --cpus N --memory GiB --disk GiB --vm-type vz template:ubuntu-24.04
# start an existing instance
limactl start <instance>
limactl shell <instance> -- sudo -H <command>
limactl copy <source> <instance>:<target>
limactl stop <instance>
limactl delete <instance> --force
```

`--containerd none` is intentional. The chain proves Docker reconciliation inside the pristine guest, so
Lima's managed containerd/rootless containerd boot scripts are not part of the runtime contract.
`--timeout 15m` prevents a provider readiness problem from becoming an unbounded lifecycle hang.

Deletion is prefix-guarded, and the guard is one computation every frame's removal goes through rather
than one written per provider. A caller supplies the project guard prefix; this module supplies only what
Lima calls the thing being removed and the argument vector for a name the guard has already admitted, so
it cannot render a destructive command for a name the guard would have refused. A name outside the
namespace refuses, and so do the two degenerate inputs that make the guard vacuous: an empty prefix, which
is a prefix of every name, and an empty instance name. `limactl stop` carries no such guard because it is
non-destructive — it halts the instance and leaves it (and its disk) intact for a later `project up` to
bring back to running.

## VM Lifecycle In The Chain

The Lima VM lifecycle runs through the core `deploy-VM` step kind that the chain interprets, plus the
project teardown that `project down` and `project destroy` drive. The same provider builders serve
bring-up, stop, and teardown:

| Phase | Lima builder | Effect | Driven by |
|---|---|---|---|
| first bring-up | sized `limactl start … template:ubuntu-24.04` | create the named instance with CPU/memory/disk arguments and wait for it to answer | `project up` |
| existing bring-up | `limactl start <instance>` | start the existing instance without comparing or changing its resource wall | `project up` |
| stop | `limactl stop <instance>` | stop the instance, delete nothing | `project down` |
| delete | guarded `limactl delete <instance> --force` | delete the instance | `project destroy` |

- `deploy-VM` runs the sized template start only when the instance is absent. For an existing instance it
  runs the unsized start and waits for the VM to answer a shell before the chain proceeds. Current code
  does not observe/resize/refuse a stale CPU, memory, or disk wall. The
  [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
  supplies the lower result/capacity algebra, while the
  [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
  owns the provider-authoritative Lima realization.
- `project down` is the **stop-without-delete** path. It halts the VM so the host reclaims CPU and
  memory, but preserves the instance and its disk; a subsequent `project up` brings the same instance
  back.
- `project destroy` routes provider deletion through the prefix-guarded `limactl delete` builder. The
  broader lifecycle does not yet return typed idempotent results or recursively visit every child.

Teardown is best-effort. `limactl delete --force` removes the instance's own disk, but the demo's
canonical `<project-root>/.data` is a host directory mounted into Lima and is not intentionally removed
with the VM. The cluster removal set also excludes it. End-to-end reattachment and readback after destroy
remain unvalidated; see [durable state](../architecture/durable_state.md).

A host directory reaches the Lima guest through the same host-path share primitive the other lanes use.
Lima declares its **host-side share** as the create-time mount argument on `limactl start` (its
`HostPathShare` has no post-create `ShareReconcile`); the **guest-side alias** — the stable Docker-visible
symlink to the share — uses the common prepared alias boundary. That core boundary accepts only the exact
opaque managed provider/share authorities, holds its clauses through the row the frame declares rather
than a front-end process, and recovers `prepared`/`managed`/`releasing` origin states before
identity-conditional release. The demo's current Lima call site still threads compatibility readiness and
creates/removes the alias by pathname, so that call site mints no receipt. Replacing it — together with
establishing the project binary in the guest that the alias's row runs in — belongs to the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). See
[ownership invariant](../architecture/ownership_invariant.md),
[ownership seam](../architecture/ownership_seam.md), [readiness](../architecture/readiness.md),
and [durable state](../architecture/durable_state.md).

The `deploy-VM` step kind is the reuse unit, not a Lima-specific command: the same kind is interpreted
with Incus builders on native Linux (see [incus](incus.md)). A project does not re-implement VM
management; it places `deploy-VM` in its chain and the interpreter selects the provider for the current
substrate. The model itself — the chain as the project, the recursive interpreter, and the single
representation — is owned by [composition_methodology](../architecture/composition_methodology.md); this
document describes the Lima provider's contribution to it.

## `ensure lima`

`ensure lima` (`HostBootstrap.Ensure.Lima`) is the install-and-verify reconciler for the provider: it
probes `limactl`, installs it with Homebrew (`brew install lima`) when absent, and re-verifies. It
applies only on Apple Silicon and fails fast on a wrong host. It runs as part of the `deploy-VM`
bring-up in `project up`, ahead of `limactl start`. See [ensure reconcilers](ensure_reconcilers.md) for
the reconciler contract.

## Relationship To Colima And Incus

Colima is the Apple Docker-provider path for direct Docker workloads. Incus is the native Linux VM
provider and an explicit Incus workflow on Apple when a user manages one. On Apple Silicon the chain's
`deploy-VM` step uses Lima because it represents a pristine Linux VM without requiring Incus nested-VM
support; on native Linux the same `deploy-VM` step uses the Incus builders. On Windows the same
`deploy-VM` step uses the WSL2 builders — WSL2 is the Windows peer of Lima, the platform's first-class
Linux VM (see [wsl2](wsl2.md)).

## Current Status

`HostTool Lima`, the lower target/inner transport renderer, the `HostBootstrap.Lima` lifecycle builders
(including the prefix-guarded delete), and
`ensure lima` are exercised by the core tests. The Apple Silicon VM lifecycle runs through the core
`deploy-VM` step kind and current-frame Chain; the target recursive `project up` interpreter continues
through authenticated child entries:

- `project up` starts the Lima instance, enters it through passwordless `sudo -H`, stages the working tree into the guest, builds the project
  binary host-native in the VM, ensures Docker in the VM, builds the project image, and hands `project
  up` down into the next frame.
- `project down` stops the Lima instance through the `limactl stop` builder, preserving the instance and
  its disk for a later `project up`.
- `project destroy` deletes the guard-prefixed instance through the `limactl delete` builder.

The VM-provider axis is tracked in the development plan
([host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)).

A disposable Apple validation on 2026-07-26 exercised the exact production command shapes with a unique
instance: 2 CPUs, 4 GiB memory, 20 GiB disk, VZ, containerd disabled, one writable host share, guest DNS
egress, already-running no-op, stop/start recovery, and exact deletion. The disposable instance and
mount directory were removed, and no pre-existing Lima instance was present. This evidence covers the
Lima lifecycle slice only; it does not prove the common prepared alias backend through a real Lima guest,
the demo's adoption of that backend, or another provider.

## See Also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain /
  `[Step]` / recursive-interpreter model this provider plugs into.
- [incus](incus.md) — the native Linux VM provider that interprets the same `deploy-VM` step kind.
- [wsl2](wsl2.md) — the Windows VM provider that interprets the same `deploy-VM` step kind.
- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure lima` follows.
- [demo runbook](../operations/demo_runbook.md) — the demo lifecycle that exercises the Lima VM steps.
- [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) — the development plan for the
  VM-provider axis.
