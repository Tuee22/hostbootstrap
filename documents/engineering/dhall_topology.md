# Dhall Topology

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [schema](schema.md), [resource_budgeting](resource_budgeting.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [python_haskell_boundary](../architecture/python_haskell_boundary.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: Define how the topology frames in a binary's sibling `<project>.dhall` drive the recursive
> `project` chain — frames are parameters and a witness contract, never the chain shape — and how each
> project binary verifies it occupies its declared frame before acting.

## TL;DR

- The chain shape is **code**: `chain :: RootConfig -> [Step]` is the project's identity, owned by the
  project binary and interpreted recursively by `project up`. It is not in any `.dhall`.
- `.dhall` carries **parameters + context + witness**, never the shape. The sibling `<project>.dhall`
  parameterizes the chain (budgets, ports, replicas, optional structural flags) and declares the
  topology frame the binary occupies.
- The `topologyFrames` list (frames plus parent references) is the **map of the recursive descent**:
  each frame is one segment of the `project up` chain, and the same data names where every binary copy
  sits in that descent.
- Each binary copy verifies it is in the frame its `.dhall` describes — `currentFrame` plus runtime
  witnesses — or fails fast before side effects. This is how a per-frame handoff stays honest.
- The context-init step inside `project up` mints the narrower child `<project>.dhall` for the next
  frame; children never reach back to read the parent's host config.
- [composition_methodology](../architecture/composition_methodology.md) is the canonical home of the
  chain / recursive-interpreter / fractal-bootstrap model; this document defers to it and describes only
  the Dhall side.

## The Chain Is Code; The Dhall Is Parameters

The recursive lift chain is a Haskell value, `chain :: RootConfig -> [Step]`, and it **is** the
project — its single representation (see
[composition_methodology](../architecture/composition_methodology.md)). The sibling `<project>.dhall`
does not encode that chain. It supplies three things and nothing more:

| Concern | What it carries | Used for |
|---|---|---|
| **Parameters** | project/user settings: Dockerfile path, resource budget, ports, HA replicas, feature flags, and any optional structural flag (e.g. skip the VM and go straight to Docker) | inputs to `chain rootCfg`, so the chain stays a pure function of root params |
| **Context** | the topology frame the binary occupies: `topologyFrames`, `currentFrame`, command/capability/resource authority | naming the binary's segment of the recursive descent |
| **Witness** | locally checkable runtime witnesses for the current frame | proving the process is actually in the frame it claims |

Because optional structural variation is a root-`.dhall` flag rather than a different file shape, the
chain remains a pure function of root parameters. The `.dhall` never becomes a second representation of
the chain.

## Topology Frames Drive The Recursive Chain

The local config carries the binary's complete picture of the composed topology. The common shape is:

```text
topology.frames       provider-backed nodes such as host, Lima/Incus VM, Docker container, cluster, pod
topology.currentFrame the frame this process claims to occupy
context               the command/capability/resource authority for that current frame
witnesses             local checks that prove the process is actually in that frame
```

The `topologyFrames` list — frames plus `topologyParentId` references — is the map of the recursive
descent. Each frame is one segment of the `project up` chain: `project up` interprets the current
frame's steps, then hands off `pb project up` into the next frame, where the child copy reads its own
sibling `<project>.dhall` and continues. The frame list is open-ended, so a project can represent
`host -> VM -> container -> kind cluster -> pod` or `host -> VM -> Pulumi role -> EKS cluster -> workload`
without the core library learning every provider in advance. The core checks the common frame graph and
command gate; higher layers add provider payloads and witness checks.

This is the data behind the `context` command (read-only introspection): `context` renders the global
lift composition — `topologyFrames` / `parentChain` — with the current frame highlighted, so an
operator can see where a binary copy sits in the descent without running it.

## Each Binary Verifies Its Frame

The frame list says where the descent goes; the witnesses say where the running process actually **is**.
Before side effects, a binary copy verifies that its declared `currentFrame` exists in `topologyFrames`,
that its ancestors exist, that the requested command is allowed by the current frame, and that the
runtime witnesses match the process environment. If the witnesses do not prove the claimed frame, the
binary fails fast with a non-zero exit.

This per-frame fail-fast is what makes the recursive handoff trustworthy: each `pb project up` segment
owns its frame and refuses to run another frame's work. A baked image-build config is not authority to
run VM-scoped workflows on whatever Docker daemon happens to be reachable.

- **WRONG**: bake `/usr/local/bin/<project>.dhall` with VM-project-container authority and then rely on
  `docker run <image> project up` to work from any host. This is wrong because it silently makes the
  current Docker daemon authoritative and can create a kind cluster outside the VM the topology intended.
- **RIGHT**: bake only an image-build config for Dockerfile-time gates. The context-init step inside the
  parent's `project up` materializes a child config for the exact frame it is launching, and the child
  verifies its witnesses before dispatch.

## Generated Child Configs

When `project up` crosses a frame boundary, the context-init step first mints the next local config at
the target path. The child config is a projection:

- it carries only the settings the child needs;
- it carries a narrower context and allowed command set for a named child frame;
- it carries the appropriate resource envelope or budget slice;
- it carries local witnesses the child process can verify;
- it never grants unrelated host, Docker-build, VM-orchestration, or service authority.

A host config may contain the full project budget and deploy settings; a cluster-service config should
contain only the service role, its local resource envelope, and the service settings it needs to serve.
Children never reach back to read the parent's host config. See
[config_generation](config_generation.md) for how the context-init step mints these files.

- **WRONG**: make a service pod read the host's `<project>.dhall` directly so it can see fields such as
  replica count or image tag. This is wrong because it leaks host-level authority and couples a child to
  a parent file path.
- **RIGHT**: the parent reads its own config, validates it, and the context-init step generates a
  narrower service `<project>.dhall` before the service starts.

## The Configuration Set

| Config | Shape | Produced by | Read by |
|------|-------|-------------|---------|
| Local runtime `<project>.dhall` | Project parameters plus the current topology frame (context + witness) | Written by `project init` (host root); minted by the context-init step inside `project up` for child frames; edited by the user for host-level settings | The project binary before normal command dispatch |
| Generated child `<project>.dhall` | Narrow projection of parameters plus child frame authority | The context-init step inside `project up`, at each VM/container/daemon/service boundary | The child binary copy |
| Rich project/deploy Dhall | Runtime/deploy records composed from the reusable vocabulary | The project binary | The project binary |
| Per-case test-harness Dhall | One typed value per test case | The project binary / test harness | The project binary / test harness |

## Rich And Test Dhall

The rich project/deploy Dhall and per-case test-harness Dhall are artifacts the project binary emits,
along with their schemas. `hostbootstrap-core` owns the reusable vocabulary and the context spine;
project-specific rich schemas are generated by the project binary. The per-case test Dhall belongs to the
`test` surface — `test init` writes `test.dhall`, and `test run <suite>|all` consumes the typed values
(see [testing](testing.md)). This keeps a single canonical home per concern: Python owns only pre-binary
build mechanics, the local `<project>.dhall` owns the binary's current frame and parameters, and the rich
and test artifacts are owned by the project binary.

## Current Status

Implemented today, the project binary owns default local config generation (via the flat `config init`
verb), pure child projection helpers, and command gating through the sibling `<project>.dhall`. The
context authority is already topology-aware: runtime configs carry provider-backed `topologyFrames`, a
`currentFrame`, and locally checked witnesses, and the binary verifies its frame before side effects. The
flat command surface in place today is `config`/`context create`/`ensure`/`cluster`/`test all`, and the
demo drives its lifecycle through the demo's `vm` and `deploy` verbs over a hand-written chain in
`demo/src/HostBootstrapDemo/Chain.hs`.

The target this document describes is the recursive `project` chain: `chain :: RootConfig -> [Step]`
interpreted by `project up`, with `project init` writing the root config, the context-init step minting
child configs, and `context` reduced to read-only introspection. The recursive `project` interpreter, the
`[Step]` chain, and the `context`/`test init`/`test run` split are **not yet implemented** — the topology
data and per-frame fail-fast above are the implemented substrate the target builds on. See
[composition_methodology](../architecture/composition_methodology.md) for the model and
`DEVELOPMENT_PLAN/` for phase status.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — canonical home of the chain,
  the recursive `project up` interpreter, and the fractal-bootstrap model.
- [config_generation](config_generation.md) — the context-init step that mints child `<project>.dhall`
  files inside `project up`.
- [binary_context_config](../architecture/binary_context_config.md) — how a binary decides whether a
  command belongs in its frame.
- [schema](schema.md) — the typed `<project>.dhall` schema, including the topology-frame records.
