# Binary Context Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [composition_methodology](composition_methodology.md), [dhall_topology](../engineering/dhall_topology.md), [development plan](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md)

> **Purpose**: Define the "know your place" context contract every project binary uses to reason
> explicitly about where it is running in a composed host/VM/container/cluster topology.

## TL;DR

- `hostbootstrap.dhall` is the static bootstrap input. It is read only by the Python bootstrapper.
- Every project binary reads a sibling `project-binary-context-config.dhall` before normal command
  dispatch. This file tells that binary where it is in the global composition chain.
- A normal command fails fast with exit code 1 when the context file is missing or the command is not
  commensurate with the declared context.
- Context files are created during bootstrap: the Python CLI creates the host-level context, and each
  nested binary creates the next context before handing work across a boundary.
- In Kubernetes, pods receive their context file through the controller that owns identity and durable
  placement. For stateful services, that is a `StatefulSet`.

## Current Status

[Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md) implements this contract in the
shared substrate: `HostBootstrap.Context` decodes, renders, discovers, validates, and gates sibling
context files; the Python bootstrapper writes the first host-level context; the core command tree gates
normal commands; and the demo project verbs declare their command classes. `config show FILE` remains the
explicit static-base inspection path. Kubernetes controller wiring is project-specific: a service
controller or manifest generator must mount or materialize the context beside the service binary.

## The Contract

The project binary is not a blind command receiver. It is the local interpreter of a pure, typed global
composition. A caller may lift a subcommand across several boundaries, but the callee still has enough
typed information to know which segment of the composition it is responsible for.

The canonical runtime context file is:

```text
project-binary-context-config.dhall
```

It lives next to the executable that reads it:

| Context | Binary location | Context file location |
|---|---|---|
| Host binary | `./.build/<project>` | `./.build/project-binary-context-config.dhall` |
| VM host-native binary | VM-local `./.build/<project>` or installed path | sibling of that VM binary |
| Project container binary | `/usr/local/bin/<project>` | `/usr/local/bin/project-binary-context-config.dhall` |
| Cluster service binary | container entrypoint path | sibling path mounted or materialized by the controller |

The filename is intentionally separate from `hostbootstrap.dhall`. The static-base file answers "what
project should the Python bootstrapper build?" The context file answers "which role in the composed
system is this already-built binary currently allowed to perform?"

## Context Shape

The implemented Dhall type carries these concepts:

| Field family | Purpose |
|---|---|
| Project identity | project name, binary name, and source root |
| Context kind | host orchestrator, VM orchestrator, VM project container, cluster service, daemon, one-shot job, or test harness |
| Parent chain | the pure lift/composition stack that led here, including host -> VM -> container -> cluster when applicable |
| Local capabilities | tools and services this context may use, such as Docker socket, kind network, Kubernetes API, or durable store |
| Allowed command classes | which command families are valid in this context |
| Resource envelope | the budget slice or cordon this context is inside |
| Child-context rules | how this binary may create the next context file before launching a nested binary |

Project-specific logic may extend the type, but it must not make `hostbootstrap.dhall` a runtime input
again. The context file is the runtime authority.

## Creation Flow

Context files are created at the boundary where the next binary becomes meaningful:

1. The Python bootstrapper reads `hostbootstrap.dhall`, builds `./.build/<project>`, and idempotently
   writes the host-level `./.build/project-binary-context-config.dhall` before it execs the binary.
2. The host-level project binary can create a VM-level context with
   `<project> context create vm OUTPUT` before a VM bootstrap launches or execs the project binary inside
   the VM.
3. The project container creates its own context during the Dockerfile build after the binary is
   installed. The Dockerfile uses the project binary's context-creation entrypoint, exposed for this
   purpose as `--create-container-config`, and stores the resulting Dhall next to the container binary.
4. A cluster service receives its context from the Kubernetes controller that owns its identity. The
   binary can render the service context with `<project> context create service OUTPUT`; durable services
   should use a `StatefulSet` so pod identity, storage, and the mounted or materialized context remain
   aligned.

The creation entrypoint is the only bootstrap operation allowed to run without an existing sibling
context file. All normal commands load and validate the context before dispatch.

## Command Gating

Every normal command starts by loading the sibling context file. It fails fast with exit code 1 when:

- `project-binary-context-config.dhall` is absent;
- the Dhall does not decode against the binary's context schema;
- the context names a different project or binary;
- the requested command is not valid for the context kind;
- the context claims capabilities the binary cannot verify locally.

Examples:

- `role serve` or another long-running daemon command is valid only in a daemon/service context.
- A host-orchestrator-only command such as `vm up` is invalid in a cluster-service pod.
- A cluster-service process must not run host-level bootstrap commands, even if those command names exist
  in the same optparse tree.

This turns the global composition into an explicit local precondition. A nested binary still runs the
same command tree, but it refuses work that does not belong to its declared place.

## Demo Contexts

The worked demo has four runtime contexts:

| Context | Role |
|---|---|
| Host | metal-side orchestrator: ensure incus, size and launch the VM, destroy it behind the guard |
| VM | fresh Linux host: re-establish the host-native binary and build the project container |
| Container on the VM | lifted test workflow: run `test all`, bring up per-case kind clusters, run e2e |
| Cluster service | the webservice pod launched by the chart: serve only the service role |

The same binary may exist in all four contexts, but each copy reads a different sibling context file and
therefore accepts a different subset of commands.

## See Also

- [composition_methodology](composition_methodology.md) - the self-reference lift and the
  one-operation-one-representation rule.
- [python_haskell_boundary](python_haskell_boundary.md) - the static bootstrap input versus binary-owned
  runtime lifecycle.
- [dhall_topology](../engineering/dhall_topology.md) - where the binary context tier fits in the Dhall
  configuration model.
