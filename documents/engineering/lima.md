# Lima VM Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [demo runbook](../operations/demo_runbook.md), [development plan](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)

> **Purpose**: Describe the Lima VM provider used on Apple Silicon to represent a pristine Linux
> environment, and how its lifecycle is expressed as the core VM step kinds (`deploy-VM` /
> `down` / `destroy`) of the `project` lift chain.

## TL;DR

- The Apple Silicon VM provider is Lima, reached through the resolved `HostTool Lima`
  (`toolCommandName Lima = "limactl"`).
- `ensure lima` installs the provider with Homebrew when `limactl` is absent. It is invoked as a chain
  step within `project up`, not as a primary verb.
- `HostBootstrap.Lima` owns pure argv builders for `limactl start`, `limactl shell`, `limactl copy`,
  `limactl list`, guarded `limactl delete`, and `limactl stop` (the stop-without-delete capability).
- The VM lifecycle is three core step kinds in the lift chain: `deploy-VM` brings the named instance up,
  `down` stops it without deleting, and `destroy` stops then deletes it. `.data` is always preserved.
- On Apple Silicon a real Lima VM is the pristine host; native Linux keeps the Incus VM path. The Step
  algebra is shared — only the provider builders differ.
- The recursive `project` interpreter that drives these steps is the **target** model; today the same
  lifecycle is reached through the flat demo `vm`/`deploy` verbs. See [`## Current Status`](#current-status).

## Provider Contract

Lima is the Apple Silicon VM provider for the pristine Linux host. The chain provisions a named
`ubuntu-24.04` instance, stages the working tree into the guest, builds the project binary in the VM,
ensures Docker in the VM, builds the project image, and runs the workload against the VM's Docker daemon.
Each of those is a [`Step`](../architecture/composition_methodology.md), and the Lima provider supplies
the VM-level steps of that chain.

The pure command shapes are:

```text
limactl start -y --timeout 15m --name=<instance> --containerd none --cpus N --memory GiB --disk GiB --vm-type vz template:ubuntu-24.04
limactl shell <instance> -- <command>
limactl copy <source> <instance>:<target>
limactl stop <instance>
limactl delete <instance> --force
```

`--containerd none` is intentional. The chain proves Docker reconciliation inside the pristine guest, so
Lima's managed containerd/rootless containerd boot scripts are not part of the runtime contract.
`--timeout 15m` prevents a provider readiness problem from becoming an unbounded lifecycle hang.

Deletion is prefix-guarded. A caller must supply the project guard prefix, and the builder refuses to
emit a destructive command for any instance name outside that namespace. `limactl stop` carries no such
guard because it is non-destructive — it halts the instance and leaves it (and its disk) intact for a
later `deploy-VM` to reconcile back to running.

## VM Lifecycle As Core Step Kinds

The Lima VM lifecycle is expressed as three core step kinds that the chain interprets. They mirror the
three `project` lifecycle commands, so the same provider builders serve bring-up, stop, and teardown:

| Step kind | Lima builder | Effect | Driven by |
|---|---|---|---|
| `deploy-VM` | `limactl start …` (probe-first) | reconcile the named instance to running | `project up` |
| `down` | `limactl stop <instance>` | stop the instance, delete nothing | `project down` |
| `destroy` | `limactl stop` then guarded `limactl delete <instance> --force` | stop, then delete the instance | `project destroy` |

- `deploy-VM` is idempotent: it probes `limactl list` and only starts an instance that is not already
  running, so re-running `project up` reconciles toward a running VM rather than failing on a live one.
- `down` is the **stop-without-delete** capability. It halts the VM so the host reclaims CPU and memory,
  but preserves the instance and its disk; a subsequent `deploy-VM` brings the same instance back. This
  is the new provider capability the `project down` surface depends on.
- `destroy` stops first, then routes deletion through the prefix-guarded `limactl delete` builder, so a
  partial or already-stopped stack tears down cleanly and idempotently.

Teardown (`down` and `destroy`) is best-effort and tolerates a partially-provisioned stack: a missing or
already-stopped instance is not an error. Across the whole lifecycle the demo's persistent `.data` is
preserved — destroying the VM removes the compute frame, not the durable store.

The step kinds are the reuse unit, not Lima-specific commands: the same `deploy-VM` / `down` / `destroy`
kinds are interpreted with Incus builders on native Linux (see [incus](incus.md)). A project does not
re-implement VM management; it places these core step kinds in its chain and the interpreter selects the
provider for the current substrate. The model itself — the chain as the project, the recursive
interpreter, and the single representation — is owned by
[composition_methodology](../architecture/composition_methodology.md); this document only describes the
Lima provider's contribution to it.

## `ensure lima`

`ensure lima` (`HostBootstrap.Ensure.Lima`) is the install-and-verify reconciler for the provider: it
probes `limactl`, installs it with Homebrew (`brew install lima`) when absent, and re-verifies. It
applies only on Apple Silicon and fails fast on a wrong host. Within the target model it is invoked as a
chain step in the `deploy-VM` sequence of `project up`, ahead of `limactl start`; the standalone
`ensure lima` verb is retained only as a hidden debug surface. See
[ensure reconcilers](ensure_reconcilers.md) for the reconciler contract.

## Relationship To Colima And Incus

Colima remains the Apple Docker-provider path for direct Docker workloads. Incus remains the native Linux
VM provider and an explicit Incus workflow on Apple when a user chooses to manage one. On Apple Silicon
the chain's VM steps use Lima because it represents a pristine Linux VM without requiring Incus
nested-VM support; on native Linux the same `deploy-VM` / `down` / `destroy` steps use the Incus builders.

## Current Status

The recursive `project` interpreter and the `project up` / `project down` / `project destroy` command
surface are the **target** model and are not yet implemented. The `project` command, the `[Step]` chain
value, and the recursive descent across frames are described here as the architecture, not as shipped
code.

What is implemented today:

- `HostTool Lima`, the `HostBootstrap.Lima` argv builders (including the prefix-guarded delete), and
  `ensure lima` exist and are exercised by the core tests.
- The Apple Silicon VM lifecycle is reached through the demo's flat `vm` / `deploy` verbs, which run a
  hand-written deploy chain — not yet the core `[Step]` interpreter.
- The `limactl stop` builder backs the **stop-without-delete** capability that `project down` will use;
  the surfacing of a dedicated `down` lifecycle command is part of the target.

The migration of these flat verbs onto the core `deploy-VM` / `down` / `destroy` step kinds and the
recursive `project up` interpreter is tracked in the development plan
([phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) for the VM-provider axis). Until that
lands, treat the flat verbs as the current entry point and the `project` chain as the direction.

## See Also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain /
  `[Step]` / recursive-interpreter model this provider plugs into.
- [incus](incus.md) — the native Linux VM provider that interprets the same `deploy-VM` / `down` /
  `destroy` step kinds.
- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure lima` follows.
- [demo runbook](../operations/demo_runbook.md) — the demo lifecycle that exercises the Lima VM steps.
- [phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) — the development plan for the
  VM-provider axis.
