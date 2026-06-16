# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [system-components.md](system-components.md)

> **Purpose**: Summarize the current phase responsibilities, why the phase order matters, and the
> dependency edges between phases.

## Current Architecture

`hostbootstrap` is the Haskell `hostbootstrap-core` library (under `core/`) plus a thin Python
bootstrapper (rooted at the repository root). `hostbootstrap-core` owns host-tool resolution, substrate
detection, install-and-verify `ensure` reconcilers, cluster lifecycle and cordoning, project-local Dhall
schema machinery, the binary-context command gate, the standardized harness, the self-reference lift, and
the composable optparse command tree project binaries extend.

The Python CLI exposes `doctor` / `build` / `run` / `update` / `base`. Its runtime boundary is the
pre-binary bootstrap: derive the project name from the Cabal file, assert irreducible host minimums,
ensure the host toolchain, build the project binary host-native, trigger the binary's idempotent
`config init --if-missing`, and exec it. Python does not read or write Dhall, ensure Docker, build the
project container, size a VM, apply resource cordons, or run cluster lifecycle operations. `update` is
an explicit pipx self-update command for the bootstrapper itself; normal commands do not auto-update,
auto-check GitHub freshness, or fail because a newer wrapper commit exists.

Every normal project-binary command reads a sibling `<project>.dhall` before dispatch. The config carries
project identity, resource budget, Docker/build inputs, runtime context, command authority, and child
projection defaults. Bootstrap/inspection commands (`help`, `version`, `config init`, `config schema`,
`config show`, `config path`, and static `config render`) are the explicit ungated exceptions.
The context model is being hardened from flat role/capability fields into a topology-aware contract:
provider-backed execution frames, a current frame, runtime witnesses, and command predicates that fail
before side effects when the binary is not actually running in the declared frame.

## Phase Responsibilities

### Phase 0 — documentation and governance

Phase 0 defines documentation governance: metadata blocks, the `DEVELOPMENT_PLAN/` structure, the
documentation validator, the family doc-floor, taxonomy checks, and doctrine clarity. It is `Done` and
has no remaining work.

### Phase 1 — hostbootstrap-core scaffolding

Phase 1 owns the `hostbootstrap-core` Cabal package shape: the `HostBootstrap.*` library namespace, the
bare executable, the GHC/tooling pin, the `runHostBootstrapCLI progName projectSpec` project entrypoint,
and the explicit `runBareHostBootstrapCLI` entrypoint for the bare core executable. It is `Done`.

### Phase 2 — host tools and config

Phase 2 owns host-tool resolution, typed host configuration, fail-fast host minimum checks, and substrate
detection. External tools resolve through the closed `HostTool` enumeration to absolute paths; supported
substrates are `apple-silicon`, `linux-cpu`, and `linux-gpu`. It is `Done`.

### Phase 3 — ensure reconcilers

Phase 3 owns the install-and-verify `ensure` suite. Each host dependency is an idempotent reconciler with
a host-applicability predicate and reconcile action, exposed as an optparse subcommand. A wrong-host
invocation fails fast with a one-line diagnostic. It is `Done`; the `ensure incus` reconciler is owned by
Phase 11.

### Phase 4 — project-local Dhall and command tree

Phase 4 owns the project-local `<project>.dhall` schema and the composable command tree. `ProjectConfig`
validates project identity against the Cabal-derived name and carries Dockerfile inputs, resources, deploy
knobs, runtime context, and child-projection defaults. It is `Done`.

### Phase 5 — cluster lifecycle and resource cordoning

Phase 5 owns kind/Helm lifecycle semantics, the never-delete-`.data` invariant, production/test cluster
profiles, and fail-closed `cluster up` behavior. The lifecycle consumes the resource cordon and runs in
the active execution context. It is `Done`.

### Phase 6 — base image and thin Python bootstrapper

Phase 6 owns the no-baked-binary base-image rule and the thin Python bootstrapper. Every project builds
its binary host-native; the base image warms dependencies for project-container builds. Python derives the
project name from the Cabal file, builds the binary, triggers `config init --if-missing`, and execs it
without reading or writing Dhall. It also owns the explicit `hostbootstrap update` command for the
pipx-installed wrapper itself. It is `Done`.

### Phase 7 — consumer adoption

Phase 7 owns the consume-as-library contract. Consumers extend the core command tree rather than
re-implementing core verbs. The documented hierarchy is L0 `hostbootstrap-core`, L1 `daemon-substrate`,
and L2 `{jitML, infernix}`, with `mcts` and `hostbootstrap-demo` consuming L0 directly. It is `Done`;
consumer repository wiring is tracked in those repositories.

### Phase 8 — Dhall generation and the four-stream extension

Phase 8 owns binary-generated Dhall: the reusable `Core.dhall` vocabulary, `HostBootstrap.Config.Vocab`,
`HostBootstrap.Dhall.Gen`, the `ConfigArtifact` registry, `config schema`, static `config render`,
`config init`, and child projection helpers. The four extension streams are CLI append, Dhall vocabulary
embed, schema-registry concat, and harness seams. It is `Done`.

### Phase 9 — Applied budget cordon and one canonical parser

Phase 9 owns the enforced budget ceiling: one canonical `parseQuantity`, shared argument builders,
`verifyBudget` and `fitsBudget`, and the Linux `docker update` kind-node cordon applied by `cluster up`
after `kind create` and before Helm. `resolveHostCapacity` is substrate-aware: Apple silicon reads
`sysctl` `hw.ncpu`/`hw.memsize` through the resolved `HostTool Sysctl`, while Linux reads `/proc`.
It is `Done`; the incus VM storage cordon is part of Phase 11.

### Phase 10 — Standardized test harness and run-models

Phase 10 owns the standardized test harness and run-model vocabulary. `runMatrix` drives a `Seams`
record over isolated per-case profiles, budget slicing, the delete guard, guaranteed teardown, and
case-local setup failure handling. The four run-models are `OneShot`, `HostNative`, `HostDaemon`, and
`Cluster`; every binary inherits `test` and `check-code`. It is `Done`.

### Phase 11 — incus first-class host-provider

Phase 11 owns the incus host-provider axis and self-reference lift. `HostTarget = Local | InVM` handles
tool-level dispatch; `HostBootstrap.Lift` handles subcommand-level context stacks (`Local`, `InVM`,
`InContainer`) by invoking the binary's own subcommand in the nested context. It is `Active` again to add
the Lima VM provider used by the Apple Silicon demo path and to keep the provider-aware lift
validated across core and demo.

### Phase 12 — Layered warm store

Phase 12 owns the layered warm store. `core.freeze` warms the base/core/shared web-build closure for L0
and L1 consumers; `daemon.freeze` warms daemon-family dependencies. Both freezes are generated in-image
and never committed. It is `Done`.

### Phase 13 — hostbootstrap-demo worked app

A self-contained worked consumer under `demo/` demonstrates the main surfaces: pristine-host bootstrap
inside a managed Linux VM, project-container build, harness cluster lifecycle, web/SPA generation,
Playwright e2e from the base-provided browser runtime in the project image, and the single-representation
deploy chain. The demo uses Lima for the VM provider on Apple Silicon and native Incus on Linux.
It uses sibling `hostbootstrap-demo.dhall` configs for host, VM, container, and service/daemon contexts.
It is `Active` until the stricter context-topology runtime gate is validated end to end. The real Apple
Silicon Lima lifecycle is validated.

### Phase 14 — Composable-operation algebra and composition methodology

Phase 14 owns the composition methodology: operations as the composable unit, self-reference lift as the
context-crossing primitive, deploy and runtime business logic as the same algebra, the L0
`HostBootstrap.RoleLifecycle` skeleton, and the single-representation doctrine. The standardized test
harness is the one representation of the test/deploy workflow and is lifted as a whole. It is `Active` to
specify and validate arbitrary provider-backed topology frames instead of a fixed Incus-oriented lift
story.

### Phase 15 — Binary context config and command gating

Phase 15 owns runtime binary-context config and command gating. Each copy of a project binary reads a
sibling `<project>.dhall`; the role is data inside the file rather than part of the filename. Normal
commands fail fast with exit code 1 when the local config is missing, malformed, for another project, or
not authorized for the requested command. It is `Active` to complete topology/witness hardening so illegal
states such as a VM-scoped kind cluster created on the host Docker daemon cannot be represented as valid.

## Dependency edges

```text
phase-0  →  phase-1  →  phase-2  →  phase-3  →  phase-4  →  phase-5  →  phase-6  →  phase-7
                                                                                          │
the global-architecture phases fan in on the inversion buildout and converge on the demo: │
  phase-8  (depends on 4)                                                                  │
  phase-9  (depends on 5, 8)                                                               │
  phase-10 (depends on 8, 9)                                                               │
  phase-11 (depends on 3, 9, 10)                                                           │
  phase-12 (depends on 6, 8)                                                               │
  phase-13 (depends on 8, 9, 10, 11, 12)  ← the demo exercises all of them ───────────────┘
  phase-14 (builds on 11; the composition methodology the demo's chain exercises via 13)
  phase-15 (builds on 6, 8, 11, 13, 14; makes each lifted/runtime context explicit)
```

Each edge is a hard prerequisite: the later phase consumes a surface the earlier phase delivers. The
edges are recorded in the phase documents when a phase is not yet complete.

## What is intentionally not a phase

- A separate doc-validator phase. The validator is a Phase-0 quality-gate deliverable, tracked in
  [phase-0-documentation-and-governance.md](phase-0-documentation-and-governance.md), not its own
  phase.
- A consumer product-feature phase. `hostbootstrap` borrows the governance shape from its consumers
  but adopts none of their runtime surfaces, daemon-role models, or hardware-correctness cadence;
  those remain consumer concerns (see [development_plan_standards.md § S](development_plan_standards.md)).
- A separate "release" phase. The library is consumed by sibling path with deps served from the
  base-image warm store; there is no
  Hackage release ceremony.
- A separate self-update phase. `hostbootstrap update` belongs to Phase 6 because it is part of the
  thin Python bootstrapper surface.
