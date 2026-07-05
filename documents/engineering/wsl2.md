# WSL2 Host Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [applied cordon](applied_cordon.md), [resource budgeting](resource_budgeting.md), [ensure reconcilers](ensure_reconcilers.md), [incus](incus.md), [lima](lima.md), [demo runbook](../operations/demo_runbook.md), [development plan](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)

> **Purpose**: Describe the WSL2 host-provider VM used on Windows to represent a pristine Linux
> environment — the peer of Lima (Apple Silicon) and Incus (native Linux) — and how its lifecycle is
> expressed through the core `deploy-VM` step kind of the `project` lift chain.

## TL;DR

- The Windows VM provider is WSL2, reached through the resolved `HostTool Wsl`
  (`toolCommandName Wsl = "wsl"`). It is the third metal substrate's VM frame — the structural peer of
  Lima on Apple Silicon and Incus on native Linux.
- `ensure wsl2` enables the WSL2 / Virtual Machine Platform feature and verifies WSL2 platform readiness.
  The project-owned VM step registers that project's own named `Ubuntu-24.04` distro when absent.
- `HostBootstrap.Wsl2` owns pure argv builders for `wsl --import`, `wsl -d <distro> --`,
  `wsl --terminate`, guarded `wsl --unregister`, and the `wsl --shutdown` managed-stop
  (stop-without-delete).
- The VM lifecycle is driven by the core `deploy-VM` step kind plus the project teardown: `project up`
  brings the named distro up, `project down` shuts it down without deleting, and `project destroy`
  unregisters it. `.data` is always preserved.
- The first `wsl --install` may require a **host reboot**; the provider detects the reboot-required
  state, instructs the operator, and exits non-zero (the structural peer of the Incus `NeedsReboot`
  reconcile), rather than rebooting Windows itself.
- Docker, kind, and the workload live **inside** the Ubuntu-24.04 distro (detected `linux-cpu`), exactly
  as on the Lima/Incus VM. The Step algebra is shared — only the provider builders differ.

## Provider Contract

WSL2 is the Windows VM provider for the pristine Linux host. The chain provisions a named
`Ubuntu-24.04` distro derived from the project identity (for the demo, `hostbootstrap-demo-vm`), stages the working tree into the guest, builds the project binary in the distro,
ensures Docker in the distro, builds the project image, and runs the workload against the distro's
Docker daemon. Each of those is a [`Step`](../architecture/composition_methodology.md), and the WSL2
provider supplies the VM-level steps of that chain.

The pure command shapes are:

```text
winget install --id Microsoft.WSL --exact  # install the WSL package when absent
wsl --install --no-distribution            # enable WSL2 + Virtual Machine Platform (may require a host reboot)
bcdedit /set hypervisorlaunchtype auto     # ensure the Windows hypervisor is allowed to launch
wsl --install -d Ubuntu-24.04 --name <project>-vm --no-launch --vhd-size <GB>  # project-owned distro registration (storage cordon) when absent
wsl --set-default-version 2
wsl --import <distro> <install-dir> <rootfs.tar.gz> --version 2
wsl -d <distro> -- <command>
wsl --terminate <distro>
wsl --shutdown
wsl --unregister <distro>
```

A pristine distro is imported from a cached Ubuntu-24.04 root filesystem tarball (a downloaded WSL
rootfs, or a one-time `wsl --export` of a provisioned base), so each run starts from a known-clean
guest rather than a user-mutated default distro.

Deletion is prefix-guarded. A caller supplies the project guard prefix, and the builder refuses to emit
`wsl --unregister` for any distro name outside that namespace. `wsl --terminate` and `wsl --shutdown`
carry no such guard because they are non-destructive — they halt the guest and leave it (and its vhdx)
intact for a later `project up` to bring back to running.

## Reboot-to-Ready

Enabling the WSL2 feature on a host that has never had it can require a **host** reboot before a distro
can launch. A pure classifier reduces a `wsl --status` / install result to a verdict:

```text
classifyWsl2Readiness :: (ExitCode, String, String) -> Ready | NeedsReboot | Unsatisfiable
```

- firmware virtualization is present, OS features and hypervisor launch state are ready, and a distro can
  launch → `Ready`;
- WSL/VMP features or Windows hypervisor boot state were just changed, or Windows reports a restart is
  required → `NeedsReboot`;
- firmware/CPU virtualization is unavailable, or the OS feature cannot be enabled → `Unsatisfiable`.

Unlike the Incus in-VM reboot loop (which reboots the *guest* with `incus restart`), a WSL2
`NeedsReboot` is a **host** reboot: the reconciler prints a clear instruction and exits non-zero so the
operator reboots Windows and re-runs `project up`. It does not reboot the host itself. This mirrors the
`NeedsReboot` shape without taking the destructive host action.

## VM Lifecycle In The Chain

The WSL2 VM lifecycle runs through the core `deploy-VM` step kind that the chain interprets, plus the
project teardown that `project down` and `project destroy` drive. The same provider builders serve
bring-up, stop, and teardown:

| Phase | WSL2 builder | Effect | Driven by |
|---|---|---|---|
| bring-up | `wsl --import …` then `wsl -d <distro> -- …` | import (if absent) and enter the named distro | `project up` |
| stop | `wsl --terminate <distro>` (or `wsl --shutdown`) | halt the distro, delete nothing | `project down` |
| delete | guarded `wsl --unregister <distro>` | unregister the distro and its vhdx | `project destroy` |

- `deploy-VM` imports the named distro from the cached rootfs when absent, then enters it via
  `wsl -d <distro> -- …` and waits for the guest to answer before the chain proceeds.
- `project down` is the **stop-without-delete** path. It terminates the distro so the host reclaims CPU
  and memory, but preserves the distro and its vhdx; a subsequent `project up` brings the same distro
  back.
- `project destroy` routes deletion through the prefix-guarded `wsl --unregister` builder, so a partial
  or already-stopped stack tears down cleanly and idempotently.

Teardown is best-effort and tolerates a partially-provisioned stack: a missing or already-terminated
distro is reported and skipped, not an error. Across the whole lifecycle the demo's persistent `.data`
is preserved — unregistering the distro removes the compute frame, not the durable store.

The `deploy-VM` step kind is the reuse unit, not a WSL2-specific command: the same kind is interpreted
with Lima builders on Apple Silicon (see [lima](lima.md)) and Incus builders on native Linux (see
[incus](incus.md)). A project does not re-implement VM management; it places `deploy-VM` in its chain
and the interpreter selects the provider for the current substrate. The model itself — the chain as the
project, the recursive interpreter, and the single representation — is owned by
[composition_methodology](../architecture/composition_methodology.md); this document describes the WSL2
provider's contribution to it.

## Resource Cordon

The `resources` budget (cordon #1, "the VM is the wall") is applied differently on WSL2 than on Lima or
Incus, and the WSL2 provider is **honest about the difference** rather than pretending parity. Incus
(`limits.memory`) and Lima (`--memory`) give each VM a hard, per-instance memory/CPU cap. **WSL2 has no
per-distro memory or CPU cap** — there is no `wsl --memory`/`--cpu`. The only lever is the *global*,
per-user `%UserProfile%\.wslconfig` `[wsl2]` block, which sizes the **single shared utility VM** that
hosts every distro on the machine. So the WSL2 wall is two cordons of different strengths:

| Dimension | WSL2 mechanism | Strength |
|---|---|---|
| CPU / memory | the global `.wslconfig` `[wsl2]` `processors` / `memory` / `swap` ceiling | global utility-VM ceiling (shared across all distros), not a per-distro wall |
| storage | per-distro VHDX cap, applied at registration via `wsl --install --vhd-size <GB>` | a real per-distro wall |

`wsl2SizingArgs` (the one canonical builder, fed by `parseQuantity`) emits the `[wsl2]` body:
`processors` and `memory` from the budget, plus `swap` sized to the memory budget for OOM headroom — so
a build that fits the budget is not killed by the host reclaiming the under-provisioned utility VM. The
`.wslconfig` carries **no** `vhdx-size` key (it is not a `.wslconfig` setting); storage is the
`--vhd-size` install flag instead.

Because `.wslconfig` is global and requires `wsl --shutdown` to take effect, the WSL2 launch is a
**list of effects**, not a single argv — the structural reason the unified per-substrate lift
(`SubstrateProvider.spLaunch`) returns `[HostEffect]`:

1. write `%UserProfile%\.wslconfig` with the `[wsl2]` ceiling, **backing up** any pre-existing file to
   `<path>.hostbootstrap-demo.bak` (a user's own `.wslconfig` is never clobbered irretrievably);
2. `wsl --shutdown` so the new ceiling applies to the next boot;
3. register the distro with its `--vhd-size` storage cap.

`project destroy` restores the backed-up `.wslconfig` (or removes the one we wrote if there was none).
The preflight predicate that decides whether the host can satisfy the budget reads **total** physical
memory on Windows (CIM `Win32_ComputerSystem.TotalPhysicalMemory`), mirroring Apple's stable
`hw.memsize` — a too-small host fails fast before the expensive build rather than passing on transient
free RAM. The enforcement mechanics, the three rings, and the per-substrate table are owned by
[applied_cordon](applied_cordon.md); this section is the WSL2-specific instance.

## `ensure wsl2`

`ensure wsl2` (`HostBootstrap.Ensure.Wsl2`) is the install-and-verify reconciler for the provider: it
probes firmware virtualization, Windows feature state, Windows hypervisor launch readiness, and
`wsl --status`. Firmware virtualization is a host-floor fact: if the
CPU/firmware support is absent, the reconciler reports `Unsatisfiable` because the project binary cannot
change BIOS/UEFI state. OS-level readiness is reconciler-owned: when absent, it installs the
`Microsoft.WSL` package, enables the WSL2 / Virtual Machine Platform feature, ensures the Windows
hypervisor is configured to launch (for example `hypervisorlaunchtype auto` or an equivalent verified
state), sets WSL default version 2, and then re-verifies. It applies on `windows-cpu` and `windows-gpu`
(`appliesTo = isWindows`) and fails fast on a wrong host. It runs as part of the `deploy-VM` bring-up in
`project up`, ahead of the project-owned distro registration. The project VM step then registers its own
named Ubuntu-24.04 distro (`wsl --install -d Ubuntu-24.04 --name <project>-vm --no-launch --vhd-size <GB>`) if absent and enters it with
`wsl -d <distro> -- …`. On a host that has never enabled WSL2 or whose hypervisor boot state was changed,
it can return the `NeedsReboot` verdict described above. See [ensure reconcilers](ensure_reconcilers.md)
for the reconciler contract.

## winget And The Pre-Binary Frame

WSL2 is the *VM* frame the running binary owns — not pre-binary work. On Windows the thin Python
bootstrapper's pre-binary job mirrors the Apple Silicon path: it asserts the host minimums and ensures
the host build toolchain with **winget** (the Homebrew-analog package manager — a one-time
pipx-via-winget install brings up the bootstrapper itself), then builds the native `hostbootstrap.exe`
host-native and execs it. Enabling WSL2 and importing the distro are reconcilers the **exe** owns
(`ensure wsl2`), exactly as `ensure lima` is owned by the binary on Apple Silicon, not by the Python
layer. See [python_haskell_boundary](../architecture/python_haskell_boundary.md).

## Relationship To Lima And Incus

Lima is the Apple Silicon VM provider and Incus the native Linux VM provider; WSL2 is the Windows peer.
On Windows the chain's `deploy-VM` step uses WSL2 because it is the native, first-class Linux VM the
platform ships, just as `deploy-VM` uses Lima on Apple Silicon and Incus on native Linux. WSL2 is **its
own provider**, not Incus-on-Windows: `ensure incus` stays applicable only on Apple Silicon and Linux.
The CUDA host capability on Windows is a separate, **headless host build** (composition pattern #7) that
runs nvcc on the bare Windows host and stages artifacts into the cluster — it does not run inside the
WSL2 VM. See [ensure reconcilers](ensure_reconcilers.md) and
[composition_patterns](composition_patterns.md).

## Current Status

The WSL2 host provider is the Windows VM frame for the third metal substrate; it is owned by the
development plan ([phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)). The
`HostBootstrap.Wsl2` argv builders (including the prefix-guarded `unregister`), the
`classifyWsl2Readiness` classifier, `HostTool Wsl` System32 resolution, and `ensure wsl2` are
unit-tested as pure values exactly as their Lima/Incus peers are. Live validation on 2026-06-26 and
2026-06-28 enabled the Windows WSL/VMP features, installed `Microsoft.WSL`, reconciled
`hypervisorlaunchtype Auto`, and stopped at the required host reboot. Post-reboot validation on
2026-06-29 crosses that platform gate: `HyperVisorPresent = True`,
`Win32_Processor.VirtualizationFirmwareEnabled = True`, `wsl --status` succeeds with default WSL version
2, and `wsl --list --verbose` can enumerate the managed WSL2 distro.

The demo's binary-owned chain selects WSL2 on Windows, composes the managed distro name from the project
identity (`hostbootstrap-demo-vm`), registers that Ubuntu-24.04 distro if absent, hands off through
`wsl -d <distro> -- ...`, stages source/config under `/root/hostbootstrap`, installs the local Python
bootstrapper through `pipx`, builds the in-distro host-native demo binary, installs Docker in the distro,
and starts the project image build from `docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64`. One live
run reached a tagged `hostbootstrap-demo:local` image and a running kind control-plane; the in-Dockerfile
gate reached pinned `fourmolu`, `hlint` (`No hints`), `cabal -Werror`, `spago build`, and `esbuild`.

Phase 11 **closed 2026-07-01**: the Windows lifecycle completed end to end through `test run all` (`6/6`)
and `project destroy`. The earlier `Wsl/Service/0x80072746` session drop during the in-distro Docker build
was diagnosed as the WSL2 utility VM being terminated under memory pressure because the budget cordon was
**computed but never written**; Sprint 9.7's honest cordon (write `.wslconfig` + `wsl --shutdown` + `swap`,
plus the stable total-memory preflight) fixed the root cause, and the closure run brought up in-distro
Docker/kind/registry/web **without a session drop**, restoring `.wslconfig` on teardown with host `.data`
preserved. (The Windows/WSL2 path is real but remains the most memory-sensitive substrate on a 16 GiB host;
the `push-image` stage can still stall intermittently under memory pressure, though the single-binary in-cluster registry is far lighter than the multi-pod stack it replaced.) Static validation remains clean: the core and demo Cabal
test/build gates and `poetry run python -m hostbootstrap.check_code` pass.

Closure requires one Windows VM lifecycle run end to end through the core `deploy-VM` step kind and the
recursive `project up` interpreter:

- `project up` imports/enters the Ubuntu-24.04 distro, stages the working tree into the guest, builds
  the project binary host-native in the distro, ensures Docker in the distro, builds the project image,
  and hands `project up` down into the next frame.
- `project down` terminates the distro through the `wsl --terminate` / `wsl --shutdown` builder,
  preserving the distro and its vhdx for a later `project up`.
- `project destroy` unregisters the guard-prefixed distro through the `wsl --unregister` builder.

The VM-provider axis is tracked in the development plan
([phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)); the Windows substrate detection it
depends on is [phase 2](../../DEVELOPMENT_PLAN/phase-2-host-tools-and-config.md).

## See Also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain /
  `[Step]` / recursive-interpreter model this provider plugs into.
- [lima](lima.md) — the Apple Silicon VM provider that interprets the same `deploy-VM` step kind.
- [incus](incus.md) — the native Linux VM provider that interprets the same `deploy-VM` step kind.
- [ensure reconcilers](ensure_reconcilers.md) — the reconciler contract `ensure wsl2` follows.
- [composition_patterns](composition_patterns.md) — pattern #7, the headless host build the Windows
  CUDA capability instantiates (distinct from this VM provider).
- [demo runbook](../operations/demo_runbook.md) — the demo lifecycle that exercises the VM steps.
- [phase 11](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md) — the development plan for the
  VM-provider axis.
