# Incus Host-Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [ensure reconcilers](ensure_reconcilers.md), [applied cordon](applied_cordon.md), [development plan](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)

> **Purpose**: Describe the `incus` host-provider axis — the typed `HostTarget` that parameterizes
> every linux-host operation by `Local` or `InVM`, the `ensure incus` cross-substrate reconciler, the
> VM lifecycle argv builders and `incus exec` dispatch, the reboot-to-ready reconcile, and the
> `incusSizingArgs` budget cordon.

## TL;DR

- `incus` is a host-provider axis **orthogonal** to substrate: a target linux host is either the
  local host or an incus VM. It is not a substrate (the VM is still `linux-cpu`/`linux-gpu` inside)
  and not a fifth run-model — it parameterizes the existing machinery by a typed `HostTarget`.
- `HostTool` gained the `Incus` constructor (`toolCommandName Incus = "incus"`), so the host `incus`
  resolves to an absolute-path `AbsExe` like every other tool — never a bare `$PATH` invocation.
- `ensure incus` is the first cross-substrate reconciler: `appliesTo = isAppleSilicon || isLinux`.
  Install-and-verify, probe-first and idempotent. On Apple silicon it provisions the macOS client plus
  a named Colima profile running the Incus runtime; on Linux it provisions the native daemon.
- `HostTarget = Local | InVM IncusVM`. `runInTarget` runs the resolved tool directly for `Local` and
  dispatches through one host `incus exec <name> -- <tool> <args>` for `InVM`, with no per-call
  branching at the call sites.
- The `HostBootstrap.Incus` lifecycle is pure argv builders plus an IO loop; `destroyVMArgs` is
  name-prefix delete-guarded, reusing the harness `guardTestDelete` idiom.
- `incusSizingArgs` sizes the VM from the one canonical `parseQuantity`; unlike `docker update`, incus
  cordons storage at the VM wall, so storage is included.

## The Host-Provider Axis

A linux-host operation can run against one of two **host targets**: the local host, or an incus VM
running on the local host. This is a distinct axis from substrate. Substrate (`apple-silicon`,
`linux-cpu`, `linux-gpu`) describes what the machine *is*; the host target describes *which* machine
the operation runs on. An incus VM is itself a `linux-cpu` or `linux-gpu` machine — the axes compose,
they do not collapse. `incus` is likewise not a fifth run-model: the four run-models in
[run models](../architecture/run_models.md) are unchanged, and the host target sits underneath them.
The parameterization detail — every linux-host operation runs against `Local` or `InVM` with no
per-call branching — is in [build and run model](../architecture/build_and_run_model.md).

`incus` is not standardized for all workflows. The worked demo uses it to encapsulate a fresh linux
host; outside that, the local host is the default target. It is fully supported either way.

On macOS, `incus` is a client; the Incus daemon runs on Linux. The supported Apple-silicon local
provider is therefore Colima's Incus runtime, started as the named profile `incus`
(`colima start incus --runtime incus`). A plain `brew install incus` followed by `incus list` is not a
usable provider: the client has no daemon until the Colima profile exists or a remote Linux server is
configured. Apple Incus VMs also depend on Apple's nested-virtualization support, so older Apple
silicon that cannot run nested VMs needs a remote Linux provider for VM lifecycle work.

The two-case `HostTarget = Local | InVM` described here is the **tool-level** lift (run one resolved tool
in a target). It is generalized by the **subcommand-level self-reference lift** (`HostBootstrap.Lift`),
which composes contexts as an n-level stack (`Local | InVM | InContainer`): a binary crosses any boundary
by invoking its *own* subcommand in the nested context, so `incus exec` is the VM layer and
`docker run --rm` is the container layer (folding e.g. to `incus exec <vm> -- docker run --rm <image>
<subcmd>`). `HostTarget`/`runInTarget` are retained as the narrower tool-level lift. See
[composition_methodology](../architecture/composition_methodology.md).

## `ensure incus`

`ensure incus` (`HostBootstrap.Ensure.Incus`) is the **first cross-substrate reconciler**: its
applicability predicate is `appliesTo = isAppleSilicon || isLinux`, true on both Apple silicon and
Linux. Every other reconciler in [ensure reconcilers](ensure_reconcilers.md) applies to a single
substrate family; `ensure incus` is the first that spans them, because the supported provider can be
Colima-backed on Apple or native on Linux.

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
own `$PATH`. The host side of that single dispatch — the host `incus` — is still resolved to an
absolute-path `AbsExe` through the `HostTool` enum.

## VM Lifecycle

`HostBootstrap.Incus` is pure argv builders plus the IO loop that runs them. The builders:

| Builder | Emits |
|---------|-------|
| `createVMArgs` | `incus launch <image> <name> --vm [sizing]` |
| `startVMArgs` | start the named VM |
| `stopVMArgs` | stop the named VM |
| `execVMArgs` | `incus exec <name> -- <cmd>` |
| `pushFileArgs` | `incus file push <src> <name><dst>` |
| `rebootVMArgs` | `incus restart <name>` |
| `destroyVMArgs prefix vm` | `incus delete <name> --force`, **guarded** by `prefix` |

`destroyVMArgs` is **name-prefix delete-guarded**, reusing the harness `guardTestDelete` idiom (see
[harness workflow](../architecture/harness_workflow.md)): `incus delete <name> --force` is refused
unless the VM name carries the guard prefix. A non-prefixed name yields no argv at all.

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

## See Also

- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure incus` follows.
- [applied cordon](applied_cordon.md) — the one canonical parser and the storage cordon.
- [build and run model](../architecture/build_and_run_model.md) — the `HostTarget` parameterization.
- [harness workflow](../architecture/harness_workflow.md) — the `guardTestDelete` delete-guard idiom.
- [composition_methodology](../architecture/composition_methodology.md) — the n-level self-reference lift
  that generalizes the two-case `HostTarget`.
- [phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) — the development plan for this
  surface.
