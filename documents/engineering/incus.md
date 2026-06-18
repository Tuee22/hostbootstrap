# Incus Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [ensure reconcilers](ensure_reconcilers.md), [applied cordon](applied_cordon.md), [development plan](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)

> **Purpose**: Describe the `incus` host-provider axis — the typed `HostTarget` that parameterizes
> every linux-host operation by `Local` or `InVM`, the `ensure incus` cross-substrate reconciler, the
> VM lifecycle expressed as `deploy-VM`/`down`/`destroy` chain steps (including stop-without-delete),
> the reboot-to-ready reconcile, and the `incusSizingArgs` budget cordon.

## TL;DR

- `incus` is a host-provider axis **orthogonal** to substrate: a target linux host is either the
  local host or an incus VM. It is not a substrate (the VM is a `linux-cpu`/`linux-gpu` machine inside)
  and not a fifth run-model — it parameterizes the host machinery by a typed `HostTarget`.
- `HostTool` carries the `Incus` constructor (`toolCommandName Incus = "incus"`), so the host `incus`
  resolves to an absolute-path `AbsExe` like every other tool — never a bare `$PATH` invocation.
- `ensure incus` is a cross-substrate reconciler: `appliesTo = isAppleSilicon || isLinux`.
  Install-and-verify, probe-first and idempotent. On Apple silicon it provisions the macOS client plus
  a named Colima profile running the Incus runtime; on Linux it provisions the native daemon.
- The incus VM is the native-Linux **VM frame** of the chain. Its bring-up is the `deploy-vm` chain
  step the recursive `project up` interpreter runs; `project down` stops it without deleting, and
  `project destroy` stops then deletes it. The model is owned by
  [composition_methodology](../architecture/composition_methodology.md); this doc describes the
  incus-specific step actions.
- `HostTarget = Local | InVM IncusVM`. `runInTarget` runs the resolved tool directly for `Local` and
  dispatches through one host `incus exec <name> -- <tool> <args>` for `InVM`, with no per-call
  branching at the call sites.
- `incusSizingArgs` sizes the VM from the one canonical `parseQuantity`; unlike `docker update`, incus
  cordons storage at the VM wall, so storage is included.

## The Host-Provider Axis

A linux-host operation runs against one of two **host targets**: the local host, or an incus VM
running on the local host. This is a distinct axis from substrate. Substrate (`apple-silicon`,
`linux-cpu`, `linux-gpu`) describes what the machine *is*; the host target describes *which* machine
the operation runs on. An incus VM is itself a `linux-cpu` or `linux-gpu` machine — the axes compose,
they do not collapse. `incus` is likewise not a fifth run-model: the host target sits underneath the
four run-models in [run models](../architecture/run_models.md). The parameterization detail — every
linux-host operation runs against `Local` or `InVM` with no per-call branching — is in
[build and run model](../architecture/build_and_run_model.md).

The worked demo uses native Incus to encapsulate a fresh Linux host on Linux. On Apple Silicon, the
worked demo uses Lima for that pristine VM; `ensure incus` serves explicit Incus workflows and
remote/provider work. Where neither flow applies, the local host is the default target.

On macOS, `incus` is a client; the Incus daemon runs on Linux. The supported Apple-silicon local
provider is therefore Colima's Incus runtime, started as the named profile `incus`
(`colima start incus --runtime incus`). A plain `brew install incus` followed by `incus list` is not a
usable provider: the client has no daemon until the Colima profile exists or a remote Linux server is
configured. Apple Incus VMs also depend on Apple's nested-virtualization support. The demo therefore does
not use an Incus VM on Apple Silicon; it uses Lima to create the pristine Linux VM.

The two-case `HostTarget = Local | InVM` is the **tool-level** lift: run one resolved tool in a target.
The **subcommand-level self-reference lift** (`HostBootstrap.Lift`) composes contexts as an n-level
stack (`Local | InVM | InContainer`): a binary crosses any boundary by invoking its *own* subcommand in
the nested context, so `incus exec` is the VM layer and `docker run --rm` is the container layer
(folding e.g. to `incus exec <vm> -- docker run --rm <image> <subcmd>`). `HostTarget`/`runInTarget` are
the narrower tool-level lift. See
[composition_methodology](../architecture/composition_methodology.md).

## `ensure incus`

`ensure incus` (`HostBootstrap.Ensure.Incus`) is a **cross-substrate reconciler**: its applicability
predicate is `appliesTo = isAppleSilicon || isLinux`, true on both Apple silicon and Linux. It spans
both substrate families because the supported provider is Colima-backed on Apple or native on Linux.
The reconciler runs as a chain step within `project up` — the VM frame's provider must reach "usable"
(VM capability plus egress) before the chain descends into it — and the standalone `ensure incus`
subcommand is a hidden debug surface.

It follows the standard probe-first, idempotent install-and-verify contract:

- **probe** the provider; if already satisfied, no-op. On Apple this checks the `incus` Colima profile
  and `incus list`; on Linux the resolved client is the provider probe after daemon initialization;
- **install** per substrate — on Apple, `brew install incus`, `brew install colima`, then
  `colima start incus --runtime incus`; on Linux, `apt-get install -y incus` followed by
  `sudo incus admin init --minimal`;
- **re-verify** with the same probe and fail fast if still missing;
- **grant socket access** on linux by adding the invoking non-root user to the `incus-admin`
  group, so future login sessions can talk to `/var/lib/incus/unix.socket`.

The Homebrew steps intentionally use plain `brew install <formula>` commands. Homebrew treats an
already-installed formula as a successful no-op, so the install plan stays declarative and idempotent
without shell-level `brew list || brew install` wrappers.

When the group grant is newly added, the current shell may still lack the supplementary group until
the operator starts a fresh login session or runs `newgrp incus-admin`.

## `HostTarget` and `runInTarget`

```
data HostTarget = Local | InVM IncusVM
```

`runInTarget` is the one dispatch point:

- `runInTarget cfg Local t args` runs the resolved tool `t` directly on the local host.
- `runInTarget cfg (InVM vm) t args` dispatches through **one** host invocation,
  `incus exec <name> -- <tool> <args>`, into the VM.

For the `InVM` case the in-VM `<tool>` is the VM's **own** `$PATH` binary, not a host-resolved
`AbsExe`. The host-tool absolute-path resolution discipline governs **host** invocation only — the VM
is a separate machine, so the tool name crossing the `incus exec` boundary is resolved by the VM's
own `$PATH`. The host side of that single dispatch — the host `incus` — resolves to an absolute-path
`AbsExe` through the `HostTool` enum.

## VM Lifecycle As Chain Steps

The incus VM is the native-Linux VM frame of the chain (`chain :: ProjectConfig -> [Step]`, the single
ordered representation; see [composition_methodology](../architecture/composition_methodology.md),
the canonical home of the model). The VM's bring-up is a **core step kind** the recursive interpreter
runs, and its stop/delete are interpreter teardown operations:

| Interpreter command | VM operation | Incus action |
|---|---|---|
| `project up` | `deploy-vm` step | bring the VM to *running* (idempotent), then hand off `pb project up` into the VM |
| `project down` | stop the VM frame | **stop** the VM without deleting it (stop-without-delete) |
| `project destroy` | delete the VM frame | stop the VM, then delete it and its compute (`.data` preserved) |

`HostBootstrap.Incus` is the pure argv builders plus the IO loop that runs them; the `deploy-vm` step
action and the teardown drive those builders. The builders:

| Builder | Emits |
|---------|-------|
| `createVMArgs` | `incus launch <image> <name> --vm [sizing]` |
| `startVMArgs` | start the named VM |
| `stopVMArgs` | stop the named VM (the `project down` stop-without-delete) |
| `execVMArgs` | `incus exec <name> -- <cmd>` |
| `pushFileArgs` | `incus file push <src> <name><dst>` |
| `rebootVMArgs` | `incus restart <name>` |
| `destroyVMArgs prefix vm` | `incus delete <name> --force`, **guarded** by `prefix` |

### `deploy-vm`: idempotent bring-up and handoff

The `deploy-vm` step under `project up` is **fail-closed** and **idempotent** (reconcile-to-running):
an already-running VM is a no-op, an absent VM is launched and sized, and a stopped VM is started. Once
the VM is up the interpreter descends into the VM frame and hands off `pb project up` — provision the
frame, build/install the pb in it, then continue the chain inside. This is the fractal-bootstrap
descent owned by [composition_methodology](../architecture/composition_methodology.md); the incus
step contributes the native-Linux provisioning leaf.

### `project down`: stop without delete

`project down` **stops** the VM and deletes nothing. The VM-frame teardown emits `stopVMArgs` only — no
`destroyVMArgs` — so the VM, its disk, and `.data` all survive. A subsequent `project up` restarts the
same VM in place. Stop-without-delete is the capability that distinguishes `project down` from
`project destroy`.

### `project destroy`: stop then delete, guarded

`project destroy` stops the VM and then deletes it through the prefix-guarded `destroyVMArgs prefix vm`,
reusing the harness `guardTestDelete` idiom (see
[harness workflow](../architecture/harness_workflow.md)): `incus delete <name> --force` is refused
unless the VM name carries the guard prefix. A non-prefixed name yields no argv at all. `.data` is
preserved across teardown — the never-delete-`.data` invariant holds at the VM frame exactly as it
does at the cluster frame (see [cluster lifecycle](cluster_lifecycle.md)).

### WRONG / RIGHT

- **WRONG**: invoke a bare `$PATH` `incus` on the host and emit an unguarded
  `incus delete <name> --force`. This is wrong on both counts. A bare `$PATH` `incus` bypasses the
  closed `HostTool` resolution, so the host might run a shadowed or absent binary instead of the
  resolved tool. An unguarded force-delete will destroy any VM whose name reaches it — including one
  the operator did not create — with no mechanical floor under the operation.
- **RIGHT**: resolve the host `incus` to an `AbsExe` through the `HostTool` enum
  (`toolCommandName Incus = "incus"`), and route destruction through the prefix-guarded
  `destroyVMArgs prefix vm`, which refuses to emit a delete argv for any name that does not carry the
  guard prefix.

## Reboot-to-Ready

Bringing Docker up inside a fresh VM can require a reboot (for example, to pick up a new group
membership). The pure classifier reduces a `docker info` result to a verdict:

```
classifyDockerReadiness :: (ExitCode, String, String) -> Ready | NeedsReboot | Unsatisfiable
```

- success → `Ready`;
- a permission/group failure → `NeedsReboot`;
- anything else → `Unsatisfiable`.

`rebootDockerToReady` is the IO loop around it: it probes `docker info` in the VM, runs
`incus restart` on `NeedsReboot` and retries bounded by `maxReboots`, succeeds on `Ready`, and fails
fast on `Unsatisfiable`. The classifier is pure and unit-tested; the loop is the only IO.

## `incusSizingArgs` Budget Cordon

`incusSizingArgs :: Resources -> Either String [String]` lives in `HostBootstrap.Cluster.Cordon` and
draws every quantity from the **one** canonical `parseQuantity`, the same parser the rest of
[applied cordon](applied_cordon.md) uses. It sizes the VM:

```
["limits.cpu=N", "limits.memory=<GiB>GiB", "root,size=<GiB>GiB"]
```

Unlike `docker update`, which carries no storage flag and so drops storage from its argv, incus
cordons storage at the VM wall via `root,size`. Storage is therefore **included** here — the VM
boundary holds CPU, memory, and disk together. See [resource budgeting](resource_budgeting.md) for
the declared budget field and [applied cordon](applied_cordon.md) for the per-substrate storage
cordon table.

## Current Status

`ensure incus` is a reconciler the chain runs, and the incus VM frame's lifecycle is the recursive
interpreter's: the `deploy-vm` step brings the VM to *running* under `project up` and hands off
`pb project up` into it, `project down` stops the VM frame without deleting it, and `project destroy`
stops then prefix-guarded-deletes it. The `HostBootstrap.Incus` argv builders, `runInTarget` dispatch,
the reboot-to-ready loop, and `incusSizingArgs` carry these operations. The pure pieces — the argv
builders, the `classifyDockerReadiness` classifier, and `incusSizingArgs` — are unit-tested, and the
IO dispatch is exercised live. [Phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)
is the development plan for this surface.

## See Also

- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure incus` follows.
- [applied cordon](applied_cordon.md) — the one canonical parser and the storage cordon.
- [cluster lifecycle](cluster_lifecycle.md) — the cluster-frame chain steps and the shared
  never-delete-`.data` invariant.
- [build and run model](../architecture/build_and_run_model.md) — the `HostTarget` parameterization.
- [harness workflow](../architecture/harness_workflow.md) — the `guardTestDelete` delete-guard idiom.
- [composition_methodology](../architecture/composition_methodology.md) — the canonical home of the
  chain-is-the-project model and the n-level self-reference lift that generalizes the two-case
  `HostTarget`.
- [phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) — the development plan for this
  surface.
