# Lima VM Provider

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [demo runbook](../operations/demo_runbook.md), [development plan](../../DEVELOPMENT_PLAN/phase-11-incus-host-provider.md)

> **Purpose**: Describe the Lima VM provider used by the worked demo on Apple Silicon to represent a
> pristine Linux environment without relying on an Incus VM.

## TL;DR

- The Apple Silicon demo VM provider is Lima, reached through the resolved `HostTool Lima`
  (`toolCommandName Lima = "limactl"`).
- `ensure lima` installs the provider with Homebrew when `limactl` is absent.
- `HostBootstrap.Lima` owns pure argv builders for `limactl start`, `limactl shell`, `limactl copy`,
  `limactl list`, and guarded `limactl delete`.
- The demo still uses a real VM as the pristine environment. It does not fall back to a host Docker
  container.
- Native Linux keeps the Incus VM path.

## Provider Contract

Lima is the Apple Silicon VM provider for the demo's pristine Linux host. The demo creates a named
`ubuntu-24.04` instance, stages the working tree into `/tmp/hostbootstrap`, runs the normal
`hostbootstrap run` flow inside the VM, builds the project image inside the VM, and lifts `test all` into
the project container on the VM's Docker daemon.

The pure command shapes are:

```text
limactl start -y --timeout 15m --name=<instance> --containerd none --cpus N --memory GiB --disk GiB --vm-type vz template:ubuntu-24.04
limactl shell <instance> -- <command>
limactl copy <source> <instance>:<target>
limactl delete <instance> --force
```

`--containerd none` is intentional. The demo proves Docker reconciliation inside the pristine guest, so
Lima's managed containerd/rootless containerd boot scripts are not part of the runtime contract.
`--timeout 15m` prevents a provider readiness problem from becoming an unbounded lifecycle hang.

Deletion is prefix-guarded. A caller must supply the project guard prefix, and the builder refuses to
emit a destructive command for any instance name outside that namespace.

## Relationship To Colima And Incus

Colima remains the Apple Docker-provider path for direct Docker workloads. Incus remains the native Linux
VM provider and an explicit Incus workflow on Apple when a user chooses to manage one. The worked demo's
default Apple Silicon VM path is Lima because it represents a pristine Linux VM without requiring Incus
nested-VM support.
