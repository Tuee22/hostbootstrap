# Lima VM Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [demo runbook](../operations/demo_runbook.md), [wsl2](wsl2.md), [development plan](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)

> **Purpose**: Describe the Lima VM provider used on Apple Silicon to represent a pristine Linux
> environment, and how its lifecycle is expressed through the core `deploy-VM` step kind of the
> `project` lift chain.

## TL;DR

- The Apple Silicon VM provider is Lima, reached through the resolved `HostTool Lima`
  (`toolCommandName Lima = "limactl"`).
- `ensure lima` installs the provider with Homebrew when `limactl` is absent. It runs as part of the
  `deploy-VM` bring-up inside `project up`.
- `HostBootstrap.Lima` owns pure argv builders for `limactl start`, `limactl shell`, `limactl copy`,
  `limactl list`, guarded `limactl delete`, and `limactl stop` (the stop-without-delete capability).
- The VM lifecycle is driven by the core `deploy-VM` step kind plus the project teardown: `project up`
  brings the named instance up, `project down` stops it without deleting, and `project destroy` deletes
  the instance **and its disk** — nothing written inside the guest survives it.
- Staging into the guest is one-way: `copyToVMArgs` emits `limactl copy` host → guest and has no
  copy-from-guest counterpart, so a guest-side write has no path back to the host. See
  [durable state](../architecture/durable_state.md).
- On Apple Silicon a real Lima VM is the pristine host; native Linux uses the Incus VM path. The Step
  algebra is shared — only the provider builders differ.
- The recursive `project` interpreter drives these steps across the composed frame stack.

## Provider Contract

Lima is the Apple Silicon VM provider for the pristine Linux host. The chain provisions a named
`ubuntu-24.04` instance, stages the working tree into the guest, builds the project binary in the VM,
ensures Docker in the VM, builds the project image, and runs the workload against the VM's Docker daemon.
Each of those is a [`Step`](../architecture/composition_methodology.md), and the Lima provider supplies
the VM-level steps of that chain.

The pure command shapes are:

```text
limactl start -y --timeout 15m --name=<instance> --containerd none --cpus N --memory GiB --disk GiB --vm-type vz template:ubuntu-24.04
limactl shell <instance> -- sudo -H <command>
limactl copy <source> <instance>:<target>
limactl stop <instance>
limactl delete <instance> --force
```

`--containerd none` is intentional. The chain proves Docker reconciliation inside the pristine guest, so
Lima's managed containerd/rootless containerd boot scripts are not part of the runtime contract.
`--timeout 15m` prevents a provider readiness problem from becoming an unbounded lifecycle hang.

Deletion is prefix-guarded. A caller supplies the project guard prefix, and the builder refuses to
emit a destructive command for any instance name outside that namespace. `limactl stop` carries no such
guard because it is non-destructive — it halts the instance and leaves it (and its disk) intact for a
later `project up` to bring back to running.

## VM Lifecycle In The Chain

The Lima VM lifecycle runs through the core `deploy-VM` step kind that the chain interprets, plus the
project teardown that `project down` and `project destroy` drive. The same provider builders serve
bring-up, stop, and teardown:

| Phase | Lima builder | Effect | Driven by |
|---|---|---|---|
| bring-up | `limactl start …` | start the named instance and wait for it to answer | `project up` |
| stop | `limactl stop <instance>` | stop the instance, delete nothing | `project down` |
| delete | guarded `limactl delete <instance> --force` | delete the instance | `project destroy` |

- `deploy-VM` runs `limactl start` to bring the named instance up and waits for the VM to answer a shell
  before the chain proceeds.
- `project down` is the **stop-without-delete** path. It halts the VM so the host reclaims CPU and
  memory, but preserves the instance and its disk; a subsequent `project up` brings the same instance
  back.
- `project destroy` routes deletion through the prefix-guarded `limactl delete` builder, so a partial or
  already-stopped stack tears down cleanly and idempotently.

Teardown is best-effort and tolerates a partially-provisioned stack: a missing or already-stopped
instance is reported and skipped, not an error. `limactl delete --force` removes the instance's disk
along with the instance, so on a lifted topology nothing written inside the guest — including a
guest-side `.data` — survives `project destroy`. The never-delete-`.data` invariant is a property of the
*cluster* teardown's removal set, not of frame deletion; see
[durable state](../architecture/durable_state.md).

A host directory reaches the Lima guest through the same host-path share primitive the other lanes use.
Lima declares its **host-side share** as the create-time mount argument on `limactl start` (its
`ShareReconcile`); the **guest-side alias** — the stable Docker-visible symlink to the share — is the
**same** pure `AliasState` classifier every lane shares; and **mount-readiness** gates it, a retrying
`Ready` witness proving the share present and writable before the alias is minted. See
[readiness](../architecture/readiness.md) and [durable state](../architecture/durable_state.md).

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

`HostTool Lima`, the `HostBootstrap.Lima` argv builders (including the prefix-guarded delete), and
`ensure lima` are exercised by the core tests. The Apple Silicon VM lifecycle runs through the core
`deploy-VM` step kind and the recursive `project up` interpreter:

- `project up` starts the Lima instance, enters it through passwordless `sudo -H`, stages the working tree into the guest, builds the project
  binary host-native in the VM, ensures Docker in the VM, builds the project image, and hands `project
  up` down into the next frame.
- `project down` stops the Lima instance through the `limactl stop` builder, preserving the instance and
  its disk for a later `project up`.
- `project destroy` deletes the guard-prefixed instance through the `limactl delete` builder.

The VM-provider axis is tracked in the development plan
([phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)).

## See Also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain /
  `[Step]` / recursive-interpreter model this provider plugs into.
- [incus](incus.md) — the native Linux VM provider that interprets the same `deploy-VM` step kind.
- [wsl2](wsl2.md) — the Windows VM provider that interprets the same `deploy-VM` step kind.
- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure lima` follows.
- [demo runbook](../operations/demo_runbook.md) — the demo lifecycle that exercises the Lima VM steps.
- [phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) — the development plan for the
  VM-provider axis.
