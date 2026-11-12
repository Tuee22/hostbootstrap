# Lima VM Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [demo runbook](../operations/demo_runbook.md), [wsl2](wsl2.md), [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)

> **Purpose**: Describe the Lima VM provider used on Apple Silicon to represent a pristine Linux
> environment, and how its lifecycle is expressed through the core `deploy-vm` step kind (`DeployVMId`) of the
> `project` lift chain.

## TL;DR

- The Apple Silicon VM provider is Lima, reached through the resolved `HostTool Lima`
  (`toolCommandName Lima = "limactl"`).
- `ensure lima` installs the provider with Homebrew when `limactl` is absent. It runs as part of the
  `deploy-vm` bring-up inside `project up`.
- The active lower-boundary separation assigns the pure `LimaVM` target and inner `limactl shell` renderer
  to `HostBootstrap.Lift.Context`. `HostBootstrap.Lima` reexports them and owns the builders for the sized
  create (`limactl start … template:ubuntu-24.04`), the writable `--mount-only` share argument,
  `limactl copy`, guarded `limactl delete`, and `limactl stop` (the stop-without-delete capability). The
  existence probe (`limactl list -q`) and the unsized start of an existing instance are written in the
  `SubstrateProvider` value itself; the module's `statusVMArgs` (`limactl list --format json`) has no
  caller outside its tests.
- The VM lifecycle is driven by the core `deploy-vm` step kind plus the project teardown: `project up`
  brings the named instance up, `project down` stops it without deleting, and `project destroy` deletes
  the instance **and its disk**. Host durable `.data` is mounted from outside that disk.
- Source staging through `copyToVMArgs` is one-way. Durable data uses a separate Lima host-path mount,
  which is visible from both host and guest through the stable alias. See
  [durable state](../architecture/durable_state.md).
- On Apple Silicon a real Lima VM is the pristine host; native Linux uses the Incus VM path. The Step
  algebra is shared — only the provider builders differ.
- The recursive `project` interpreter drives these steps across the composed frame stack.
- "Frame" on this page carries two of the [glossary](../README.md#glossary) senses: the composed frame
  stack, the guest frame, and the next frame are the default **topology** sense; a frame that declares an
  ownership row or supplies a guarded removal is the **frame table** sense, of which Lima is one row.

## Provider Contract

Lima is the Apple Silicon VM provider for the pristine Linux host. The chain provisions a named
`ubuntu-24.04` instance, stages the working tree into the guest, builds the project binary in the VM,
ensures Docker in the VM, builds the project image, and runs the workload against the VM's Docker daemon.
Each of those is a [`Step`](../architecture/composition_methodology.md), and the Lima provider supplies
the VM-level steps of that chain. Its selected `SubstrateProvider` is abstract and carries the complete
lower `LiftContext` without exposing construction or record update. The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
implements common discovery as a closed, ordered set of daemon, permission, VM-capability, and egress
probes over raw outcomes; a private classifier reads each probe by its exit status, and only a not-ready
probe is retried, within a bounded policy (the classification table is in
[incus](incus.md#provider-discovery)). Discovery runs after provider settlement when guest facts are needed; its generative capability
is descriptive and indexed to the exact opaque managed provider/backend/generation, never mutation
authority. Native Lima confirmation belongs to the
[Apple-Silicon-substrate phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md), whose
current status and remaining acceptance runs are recorded in the development-plan index.

Lima and WSL2 are **one guest-VM backend row**, not two. Both admit a declaration through the same
guard sequence and both build the same backend specification value, so the construction is written once
and each realization is a value naming what actually differs: its host guard, its closed provider kind,
the tool it needs resolved, and how it spells itself and the thing it names in a refusal. A third
guest-VM provider is another such value rather than another copy of the function. That is the substrate
axis behaving as a lift rather than a fork, which is what the frame table asks for.

Guest-route selection matches every closed provider kind explicitly. Lima and WSL2 select their
own argument renderer; an Incus or Direct kind inside a guest-VM specification refuses before the
bound execution continuation runs. There is no default Lima route. The backend identity includes the
provider kind even when both tools resolve to the same executable path; the backend suite checks
that shared-path case with the same VM name, resource envelope and share.

The pure command shapes are:

```text
# create a new instance
limactl start -y --timeout 15m --name=<instance> --containerd none --cpus N --memory GiB --disk GiB --vm-type vz [--mount-only <host-.data>:w] template:ubuntu-24.04
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
`--mount-only <host-.data>:w` is present when the plan declares a durable share: it replaces Lima's
default read-only mount of the host home directory, so the declared host `.data` directory is the only
host directory the guest sees, and the only one it can write.

Deletion is prefix-guarded, and the guard is one computation every frame's removal goes through rather
than one written per provider. A caller supplies the project guard prefix; this module supplies only what
Lima calls the thing being removed and the argument vector for a name the guard has already admitted.
The row passes that admitted name through to its vector by convention; the callback's types do not
enforce this. A name outside the namespace refuses, and so do the two degenerate inputs that make the
guard vacuous: an empty prefix, which
is a prefix of every name, and an empty instance name. `limactl stop` carries no such guard because it is
non-destructive — it halts the instance and leaves it (and its disk) intact for a later `project up` to
bring back to running.

## VM Lifecycle In The Chain

The Lima VM lifecycle runs through the core `deploy-vm` step kind that the chain interprets, plus the
project teardown that `project down` and `project destroy` drive. The same provider builders serve
bring-up, stop, and teardown. The table describes the dispatcher builder call sites; prepared
backend operations enter the recorded transaction described below.

| Phase | Lima builder | Effect | Driven by |
|---|---|---|---|
| first bring-up | sized `limactl start … template:ubuntu-24.04` | create the named instance with CPU/memory/disk arguments and wait for it to answer | `project up` |
| existing bring-up | none; readiness polls `limactl shell <instance> -- sudo -H true` | treat the listed instance as this plan's, without comparing or changing its resource wall, and wait for it to answer | `project up` |
| reach for teardown | `limactl start <instance>` | start a stopped instance so its retained children can be reached | `project destroy` |
| stop | `limactl stop <instance>` | stop the instance, delete nothing | `project down` |
| delete | guarded `limactl delete <instance> --force` | delete the instance | `project destroy` |

- `deploy-vm` runs the sized template start only when `limactl list -q` does not list the instance. For a
  listed instance the forward route launches nothing and issues no `limactl start`: it polls the guest
  shell for up to 60 one-second attempts before the chain proceeds. Under a Harness test case a listed
  instance is refused instead, because the run expects a fresh guest. The code does not
  observe/resize/refuse a stale CPU, memory, or disk wall through those dispatcher call sites. The
  [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md)
  supplies the lower result/capacity algebra, while the
  [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
  owns the provider-authoritative Lima realization.
- `project down` is the **stop-without-delete** path. It halts the VM so the host reclaims CPU and
  memory, but preserves the instance and its disk. The contract is that a subsequent `project up` brings
  the same instance back; the forward route does not start a stopped instance (see
  [current status](#current-status)).
- `project destroy` routes provider deletion through the prefix-guarded `limactl delete` builder. The
  recursive lifecycle visits every admitted child first, aggregates independent reverse failures, and
  deletes the plan's Lima instance only after its descendants settle.

The recorded provider realization (shared with WSL2) holds all four ownership clauses through
the [guest-VM transaction](../architecture/ownership_invariant.md#per-backend-clause-matrix).
It refuses an unrecorded or differently claimed VM, even when the configured name matches.
Creation publishes origin before a create-only command; readiness starts an owned Stopped instance
once and a Running instance zero times. The recorded backend checks the parent lease and current
native identity around share probes, discovery and guest work. Forward stop/delete remain explicit
Unsupported operations; the retained plan adapter owns reverse lifecycle. The older dispatcher
builders described above are separate call sites whose adoption remains in the development plan.

Owned provisioning through the recorded backend compares the native JSON listing's top-level
`cpus`, `memory` and `disk` fields with the declared canonical budget. Memory and disk are
integer bytes; the three fields must fit their native signed representation and the canonical
positive bounds. Missing fields, fractions, zero/negative quantities, overflow and string-unit fields
refuse. Creation configuration does not supply a missing native observation. The transaction re-enters
the stored binding and checks the fresh claim and kernel directory identity before comparing.

Equivalent quantities return `ProvisionAlreadyOwned` without another create/start or origin
publication. CPU, memory or disk drift returns the shared typed `Conflict` with declared and observed
quantities and destroy-and-reprovision as the remedy. The protected record, including its version,
is unchanged on both equal and mismatching readback. Static cases exercise the total parser and
compiled-client protocol with actual temporary directory identities; the
[Apple Silicon acceptance](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md) owns real Lima
confirmation.


`limactl delete --force` removes the instance's own disk, but the demo's
canonical `<project-root>/.data` is a host directory mounted into Lima and is not intentionally removed
with the VM. The cluster removal set also excludes it. The Harness `durable-readback` case proves the exact
host root across an engine-owned destroy/recreate before terminal run-root release; see
[durable state](../architecture/durable_state.md).

A host directory reaches the Lima guest through the same host-path share primitive the other lanes use.
Lima declares its **host-side share** as the create-time `--mount-only` argument on `limactl start` (its
`HostPathShare` has no post-create `ShareReconcile`); the **guest-side alias** — the stable Docker-visible
symlink to the share — uses the common prepared alias boundary. That core boundary accepts only the exact
opaque managed provider/share authorities, holds its clauses through the row the frame declares rather
than a front-end process, and recovers an unbound (prepared) or bound (managed) origin record before
identity-conditional release. The demo opens the exact plan-owned provider/share resources and executes
that prepared alias transaction through the project binary installed in the admitted guest frame. See
[ownership invariant](../architecture/ownership_invariant.md),
[ownership seam](../architecture/ownership_seam.md), [readiness](../architecture/readiness.md),
and [durable state](../architecture/durable_state.md).

The `deploy-vm` step kind is the reuse unit, not a Lima-specific command: the same kind is interpreted
with Incus builders on native Linux (see [incus](incus.md)). A project does not re-implement VM
management; it places `deploy-vm` in its chain and the interpreter selects the provider for the current
substrate. The model itself — the chain as the project, the recursive interpreter, and the single
representation — is owned by [composition_methodology](../architecture/composition_methodology.md); this
document describes the Lima provider's contribution to it.

## `ensure lima`

`ensure lima` (`HostBootstrap.Ensure.Lima`) is the install-and-verify reconciler for the provider: it
probes `limactl`, installs it with Homebrew (`brew install lima`) when absent, and re-verifies. It
applies only on Apple Silicon and fails fast on a wrong host. It runs as part of the `deploy-vm`
bring-up in `project up`, ahead of `limactl start`. See [ensure reconcilers](ensure_reconcilers.md) for
the reconciler contract.

## Relationship To Colima And Incus

Colima is the Apple Docker-provider path for direct Docker workloads. Incus is the native Linux VM
provider and an explicit Incus workflow on Apple when a user manages one. On Apple Silicon the chain's
`deploy-vm` step uses Lima because it represents a pristine Linux VM without requiring Incus nested-VM
support; on native Linux the same `deploy-vm` step uses the Incus builders. On Windows the same
`deploy-vm` step uses the WSL2 builders — WSL2 is the Windows peer of Lima, the platform's first-class
Linux VM (see [wsl2](wsl2.md)).

## Current Status

`HostTool Lima`, the lower target/inner transport renderer, the `HostBootstrap.Lima` lifecycle builders
(including the prefix-guarded delete), and
`ensure lima` are exercised by the core tests. The Apple Silicon VM lifecycle runs through the core
`deploy-vm` step kind and current-frame Chain; the recursive `project up` interpreter continues
through authenticated child entries:

- `project up` creates the Lima instance (or treats a listed one as this plan's), enters it through passwordless `sudo -H`, stages the working tree into the guest, builds the project
  binary host-native in the VM, ensures Docker in the VM, builds the project image, and hands `project
  up` down into the next frame.
- `project down` stops the Lima instance through the `limactl stop` builder, preserving the instance and
  its disk for a later `project up`.
- `project destroy` deletes the guard-prefixed instance through the `limactl delete` builder.

The VM-provider axis is tracked in the development plan
([host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)).

The recorded backend now refuses name-only adoption and starts an owned stopped VM before polling.
The [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) records the
shared backend's static ownership evidence. The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)
owns the remaining dispatcher adoption. Native Apple lifecycle confirmation belongs to the
terminal substrate acceptance.

The recorded Apple acceptance run exercised the full ten-row demo matrix through four fresh Lima guests. Each guest
used the admitted CPU/memory/disk wall, the writable durable share and shipped guest-alias row, pinned GHC,
Docker, project-image build/check, cluster/workload lifecycle, host Metal daemon, and terminal deletion.
Both variants also destroyed and recreated the guest within one run and read the same durable marker after
reattachment. Exact host/version/duration evidence lives in the
[Apple-Silicon-substrate phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md).

## See Also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain /
  `[Step]` / recursive-interpreter model this provider plugs into.
- [incus](incus.md) — the native Linux VM provider that interprets the same `deploy-vm` step kind.
- [wsl2](wsl2.md) — the Windows VM provider that interprets the same `deploy-vm` step kind.
- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure lima` follows.
- [demo runbook](../operations/demo_runbook.md) — the demo lifecycle that exercises the Lima VM steps.
- [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) — the development plan for the
  VM-provider axis.

The guest-VM backend admits command reports through the shared provider report classifier. Successful
commands must be quiet on standard error and carry bounded, control-free output; ordinary non-zero
readiness remains retryable. Static cases execute compiled CLI fixtures through the production command
interpreter. The [host providers phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
records shared report handling and recorded ownership behavior. Native Lima VM lifecycle confirmation
belongs to the [Apple Silicon acceptance](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md).

The ownership transaction's command vocabulary separates create-only from starting an existing
instance. Creation receives structured configuration on stdin, including the record's claim in ordinary
environment metadata, the admitted budget and one exact writable mount. Its image-only base introduces
no default host-home mount. Native JSON observations retain the exact instance name, Running/Stopped
state, absolute instance directory, creation claim and numeric CPU/memory/disk limits; the directory still needs a real kernel identity
observation before it can be bound. Duplicate names, malformed fields, unknown states and controls
refuse through the shared report boundary. This vocabulary alone grants no ownership or permission
to run a command; the backend enters the recorded transaction before interpreting it.
Lima's [create CLI](https://lima-vm.io/docs/reference/limactl_create/) documents stdin configuration,
and its [instance schema](https://github.com/lima-vm/lima/blob/master/pkg/limatype/lima_instance.go)
carries the observed directory and configuration fields.
The recorded guest-VM driver now acquires an owned directory namespace and holds its lease around a
separate protected VM-record entry. It records absence before create-only, binds the observed native
instance-directory identity, and requires the exact creation claim on every admission. A lost create
response leaves the origin record available for recovery without a second creation. Dependent guest
commands check the parent lease and the native identity on both sides; a changed claim or replacement
refuses. The backend route now uses this driver for each of its guest-VM effects.
