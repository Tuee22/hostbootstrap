# Binary Context Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [composition_methodology](composition_methodology.md), [dhall_topology](../engineering/dhall_topology.md), [development plan](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md)

> **Purpose**: Define the "know your place" authority contract every project binary uses to reason
> explicitly about where it is running in a composed host/VM/container/cluster topology.

## TL;DR

- The runtime config file is the executable's sibling `<project>.dhall`; the runtime-context fields live
  inside that file.
- The binary always has one default lookup rule. The role is inside the Dhall value, not encoded in the
  filename.
- A normal command fails fast with exit code 1 when the config is missing or the requested command is not
  commensurate with the declared context.
- Python does not create the host context in the target model. The built binary has ungated config
  initialization/inspection commands and owns default generation.
- Parent binaries generate narrower child configs at VM, container, daemon, and service boundaries.

## Current Status

[Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md) implements command gating through the
project-local sibling `<project>.dhall`. Python does not create runtime config. The built binary owns
ungated default generation, schema/help, validation, child-config projection, and the normal command gate
that reads the context authority embedded in the local config.

## The Contract

The project binary is not a blind command receiver. It is the local interpreter of a pure, typed global
composition. A caller may lift a subcommand across several boundaries, but the callee still has enough
typed information to know which segment of the composition it is responsible for.

The canonical lookup path is:

```text
<directory containing executable>/<project>.dhall
```

Examples:

| Context | Binary location | Config file location |
|---|---|---|
| Host binary | `./.build/<project>` | `./.build/<project>.dhall` |
| VM host-native binary | VM-local `./.build/<project>` or installed path | sibling `<project>.dhall` |
| Ad-hoc project container binary | `/usr/local/bin/<project>` | `/usr/local/bin/<project>.dhall` |
| Cluster service or daemon binary | container entrypoint path | sibling path mounted or materialized by the controller |

There should not be alternate automatic filenames such as `<project>.host.dhall` or
`<project>.service.dhall`. Those names require the binary to choose a role before it has read the file that
declares its role. An explicit `--config FILE` may exist for inspection, testing, and bootstrap tooling, but
normal dispatch defaults to the single sibling path.

## Context Shape

The context portion of the local config carries these concepts:

| Field family | Purpose |
|---|---|
| Project identity | project name, binary name, and source root |
| Context kind | host orchestrator, VM orchestrator, VM project container, cluster service, daemon, one-shot job, or test harness |
| Role name | optional project-specific role label such as `webservice`, `worker`, or `host` |
| Parent chain | the pure lift/composition stack that led here, including host -> VM -> container -> cluster when applicable |
| Local capabilities | tools and services this context may use, such as Docker socket, kind network, Kubernetes API, or durable store |
| Allowed command classes | which command families are valid in this context |
| Resource envelope | the budget slice or cordon this context is inside |
| Child-context rules | how this binary may create the next config file before launching a nested binary |

Project-specific logic may extend the value, but it must not make a child reach back to the parent's config
or treat missing config as implicit authority.

## Creation Flow

Context files are created at the boundary where the next binary becomes meaningful:

1. Python derives `<project>` from the Cabal file, builds `./.build/<project>`, and execs the requested
   binary command. It does not read or write Dhall.
2. The built binary exposes ungated config surfaces such as `config path`, `config schema`, `config init`,
   and `config show FILE`. A user can generate the first host config with `config init` and then edit the
   user-owned settings.
3. A host or VM binary creates a VM-local or container-local `<project>.dhall` before launching the nested
   binary.
4. The project Dockerfile bakes a narrow ad-hoc container config at `/usr/local/bin/<project>.dhall` after
   installing the binary and before `check-code`.
5. A service or daemon receives a role-specific config from the controller or launcher that owns identity
   and durable placement. For stateful Kubernetes services, that is usually a `StatefulSet`.

The initialization and inspection entrypoints are the only binary entrypoints allowed to run without an
existing sibling config: help/version, `config path`, `config schema`, `config init`, `config show FILE`,
and `config render`. `config render` prints static typed artifact examples from the in-scope registry,
fails fast on an unknown `--artifact`, and does not project child runtime authority. All other normal
commands load and validate the config before dispatch.

## Command Gating

Every non-bootstrap/inspection command starts by loading the sibling config file. It fails fast with exit
code 1 when:

- `<project>.dhall` is absent;
- the Dhall does not decode against the binary's config/context schema;
- the config names a different project or binary;
- the requested command is not valid for the context kind or role;
- the config claims capabilities the binary cannot verify locally.

Examples:

- `role serve` or another long-running daemon command is valid only in a daemon/service context.
- A host-orchestrator-only command such as `vm up` is invalid in a cluster-service pod.
- A cluster-service process must not run host-level bootstrap commands, even if those command names exist
  in the same optparse tree.

This turns the global composition into an explicit local precondition. A nested binary still runs the same
command tree, but it refuses work that does not belong to its declared place.

## Docker Defaults And Service Overrides

A Docker image should normally contain a safe default ad-hoc container config so commands such as
`docker run --rm <image> test all` can work without a mounted file. That baked config should be narrow:
`VMProjectContainer` or equivalent, with only container/test/build capabilities.

A long-running service or daemon should not rely on the baked ad-hoc config. Its controller or launcher
must mount or materialize a role-specific file at the same canonical path. The same image can therefore
serve both ad-hoc and service contexts while each container instance reads exactly one local file.

## Config Snapshot And Daemons

For short-lived commands, the config is read once at startup and treated as immutable for that invocation.
Changes on disk affect future invocations only.

For daemons and services, the default is the same: read once, validate, log the config path and hash, and
run under that snapshot until restart or an explicit reconcile. Live reload is optional project work and
must never live-reload authority fields such as project identity, context kind, parent chain, capabilities,
or allowed command classes.

Daemon logs should make the active authority obvious. A startup event should include project, binary,
context kind, role name, config path, config hash, source root, and resource envelope. Projects that carry
version/build metadata should include it in the same startup event. Logs should go to stdout/stderr by
default so systemd, Docker, Kubernetes, or incus can collect and rotate them.

## Demo Contexts

The worked demo has four runtime contexts:

| Context | Role |
|---|---|
| Host | metal-side orchestrator: ensure incus, size and launch the VM, destroy it behind the guard |
| VM | fresh Linux host: re-establish the host-native binary and build the project container |
| Container on the VM | lifted test workflow: run `test all`, bring up per-case kind clusters, run e2e |
| Cluster service | chart-launched webservice pod: serve only the service role |

The same command tree exists in each copy of the binary. Each copy reads a different local `<project>.dhall`
and therefore accepts a different subset of commands.

## See Also

- [composition_methodology](composition_methodology.md) - the self-reference lift and the
  one-operation-one-representation rule.
- [python_haskell_boundary](python_haskell_boundary.md) - Python's pre-binary boundary.
- [dhall_topology](../engineering/dhall_topology.md) - where the binary context fields fit in the Dhall
  configuration model.
