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
The context model is topology-aware: provider-backed execution frames, a current frame, runtime
witnesses, and command predicates fail before side effects when the binary is not actually running in the
declared frame.

The command topology is the **chain-is-the-project** model: the orchestration verbs collapse into a single
recursive `project init|up|down|destroy` lifecycle that interprets a pure `chain :: RootConfig -> [Step]`
value, `context` is a read-only introspection command, and `test` is decoupled from deploy (see
[development_plan_standards.md § Y/§ Z](development_plan_standards.md)).

The **unified-harness / fixed-surface / resource-SSoT** correction spans phases 10, 13, 14, 15, 16, 17, and
18: the command surface is **fixed** to `project` / `test` / `service` / `context` / `check-code` (no
per-project verbs; `hostbootstrap-core` is a library of composable tools, § P); the test harness **drives
the real `project up`** under a test config rather than re-expressing bring-up (§ W); the declared budget is
the **one ceiling = the VM wall** with the cluster a **slice within it** (no doubling, § O); each
`<project>.dhall` carries an explicit, possibly multi-role context generated from forwarded parameters
(§ X); and long-running roles run through the new `service` command (§ AA). The correction is **complete —
all of phases 10, 13, 14, 15, 16, 17, and 18 are `Done`**: the code is code-check-validated (`cabal test
all`, `cabal build all --ghc-options=-Werror`, fourmolu/hlint, the Python gate), and the **full demo
lifecycle `project up` runs end-to-end on both native Incus/Linux and a 16 GiB Apple-Silicon host**.
`test run all` reports **`3/3 passed` on both** Apple-Silicon/Lima (2026-06-20) and native Incus/Linux
(2026-06-21): every case runs in the **VM frame** via the self-reference lift, so each reachability probe
reaches the in-cluster NodePort regardless of whether the provider forwards the guest port to the host
(see [phase-17](phase-17-chain-driven-test-and-context-introspection.md)). Dependencies are **forward-only** — no earlier phase is
blocked by a later one; the core cordon/parser phases (5, 9) stay `Done` because the doubling is demo-side.

The **generic-project-model** correction (phase 19, § BB) is **newly reopened and documentation-only**:
`hostbootstrap-core` is to own **no hardcoded defaults** and become parameterized over a project's own
config type (`ProjectSpec cfg tcfg`), with defaults living only in a project-owned `psInit`, `project init`
and the harness sharing that one builder, the harness **generating** the run's `<project>.dhall` from a thin
`test.dhall` override, and a pure `SecretRef` vocabulary for secrets-strict consumers. Phases 4, 8, 10, 15,
and 17 are reopened (`Active`); phase 19 (`Planned`) owns the work and the superseded surfaces are listed in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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
knobs, runtime context, and child-projection defaults. It is `Active` — **reopened by phase 19** (§ BB):
`ProjectConfig`'s core-owned defaults and its status as a fixed universal type are superseded by the
project-owned `psInit` and the generic `ProjectSpec cfg tcfg`. The command-tree migration is done: the new surface — `config init` -> `project init` (Python trigger updated), `cluster` -> `project up|down|destroy`,
`context create` -> the `context-init` chain step, and `config show|schema|render|path` folded into the
read-only `context` command (core `cabal test` green; the recursive interpreter it surfaces is phase-16).

### Phase 5 — cluster lifecycle and resource cordoning

Phase 5 owns kind/Helm lifecycle semantics, the never-delete-`.data` invariant, production/test cluster
profiles, and fail-closed `cluster up` behavior. The lifecycle consumes the resource cordon and runs in
the active execution context. It is `Done`: cluster bring-up/teardown is interpreted as `deploy-kind` /
`deploy-chart` chain steps under `project up` / `project down` / `project destroy` (phase-16). The core
cordon upholds budget = VM wall / cluster = slice (§ O); the demo-side budget-doubling is corrected in
phase-13, so this core phase stays closed.

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

### Phase 8 — Dhall generation and the extension contract

Phase 8 owns binary-generated Dhall: the reusable `Core.dhall` vocabulary, `HostBootstrap.Config.Vocab`,
`HostBootstrap.Dhall.Gen`, the `ConfigArtifact` registry, `config schema`, static `config render`,
`config init`, and child projection helpers. The four extension streams are CLI append, Dhall vocabulary
embed, schema-registry concat, and harness seams. It is `Active` — **reopened by phase 19** (§ BB): `ProjectSpec`
is parameterized as `ProjectSpec cfg tcfg` with the project-owned `psInit` / `psTestInit` / `psTestConfig`
seams and a pure `SecretRef` vocabulary.

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
`Cluster`; every binary inherits `test` and `check-code`. It is `Done`: the harness **engine** is recast to
drive the real `project up` under the test surface (one `project up` per distinct test config) instead of
standing up isolated per-case clusters via `Seams` — the harness owns no second bring-up path (§ W) — and
owns the run's `.test_data` lifecycle under a self-created-only delete-guard. Real-run-validated by
`test run all` reporting `3/3 passed` (2026-06-20). It is `Active` — **reopened by phase 19** (§ BB): the
harness must **generate** the run's `<project>.dhall` from the `test.dhall` override via the project-owned
`psTestConfig` (reusing `psInit`) and delete the generated config on teardown, rather than driving
`project up` against a pre-existing config.

### Phase 11 — incus first-class host-provider

Phase 11 owns the incus host-provider axis and self-reference lift. `HostTarget = Local | InVM` handles
tool-level dispatch; `HostBootstrap.Lift` handles subcommand-level context stacks (`Local`, `InVM`,
`InContainer`) by invoking the binary's own subcommand in the nested context. The Lima VM provider used
by the Apple Silicon demo path is implemented and validated through the full demo lifecycle. It is `Done`.

### Phase 12 — Layered warm store

Phase 12 owns the layered warm store. `core.freeze` warms the base/core/shared web-build closure for L0
and L1 consumers; `daemon.freeze` warms daemon-family dependencies. Both freezes are generated in-image
and never committed. It is `Done`.

### Phase 13 — hostbootstrap-demo worked app

A self-contained worked consumer under `demo/` demonstrates the main surfaces: pristine-host bootstrap
inside a managed Linux VM, project-container build, harness cluster lifecycle, web/SPA generation,
Playwright e2e across all three browser engines (chromium, firefox, webkit) from the base-provided browser runtime in the project image, and the single-representation
deploy chain. The demo uses Lima for the VM provider on Apple Silicon and native Incus on Linux.
It uses sibling `hostbootstrap-demo.dhall` configs for host, VM, image-build container, runtime
container, and service/daemon contexts. It is `Done`: the contributed `demoChain` interpreted by
`project up` drove the unified-harness / resource-SSoT / fixed-surface correction to a real-run close on a
16 GiB Apple-Silicon host (2026-06-20) — the demo's test surface drives the real `project up` (no second
bring-up), the VM is sized to the budget with the cluster a slice within it, and `web serve` / `web bridge`
moved to `service run web` / the build-image step. The full `project up` lifecycle serves HTTP 200 (8-pod
`arm64` Harbor via the dual-arch `ghcr.io/octohelm/harbor/*` images) and `test run all` reports `3/3
passed` (incl. the Playwright e2e lifted into the VM frame).

### Phase 14 — Composable-operation algebra and composition methodology

Phase 14 owns the composition methodology: operations as the composable unit, self-reference lift as the
context-crossing primitive, deploy and runtime business logic as the same algebra, the L0
`HostBootstrap.RoleLifecycle` skeleton, and the single-representation doctrine. The standardized test
harness is the one representation of the test/deploy workflow. It is `Done`: the single-representation
doctrine is recast in both code and the canonical doc so the harness **reuses the chain** (drives `project
up`) rather than being a separate engine lifted alongside it (§ W); `composition_methodology.md` is the
canonical home (`project up` as the recursive/fractal interpreter, Python as the metal-frame instance, the
`[Step]` chain as the single representation, the harness as a driver of that chain, with a WRONG/RIGHT block
and a validated `## Current Status`).

### Phase 15 — Binary context config and command gating

Phase 15 owns runtime binary-context config and command gating. Each copy of a project binary reads a
sibling `<project>.dhall`; the role is data inside the file rather than part of the filename. Normal
commands fail fast with exit code 1 when the local config is missing, malformed, for another project, not
authorized for the requested command, or missing required topology witnesses. It is `Done`: each
`<project>.dhall` carries an **explicit context** and may declare **multiple roles** (project + service,
generated by `project init --also-role` via `Context.addRole`), context relationships are pure compositional
lifts, and child configs are generated from parameters **forwarded from the parent** (§ X); `context` stays
read-only and uniform over all configs. The realigned contract (`context` introspection, `config init` ->
`project init`, `validateRuntimeContext`, multi-role generation) is built and validated. It is `Active` —
**reopened by phase 19** (§ BB): the binary-context coupling becomes the generic `cfg -> BinaryContext`
accessor on `ProjectSpec cfg tcfg`, so the gate is expressed over a project-defined config type rather than
the fixed `ProjectConfig`.

### Phase 16 — Project lifecycle command and step-chain interpreter

Phase 16 owns the `project init|up|down|destroy` lifecycle command and the `Step` algebra it interprets.
A project's deploy is a pure `chain :: RootConfig -> [Step]` value; `project up` interprets it recursively
(run the current frame's steps, then provision → build the pb → hand off `pb project up` into the next
frame — the fractal bootstrap), is idempotent, and renders the pure chain under `--dry-run`. `project
down` stops without deleting; `project destroy` deletes but preserves `.data`. The `Step` algebra, the
recursive interpreter, and the `project` command are built and real-run-validated (2026-06-18). It is
`Done`: the command surface is **fixed and closed** — `project` / `test` / `service` / `context` /
`check-code`, with `ProjectSpec` carrying no `ProjectCommand` deltas (`hostbootstrap-core` is a library of
composable tools, § P) — and the build-time `web bridge` is re-homed into the build-image step. The fixed
surface is real-run-validated by the full `project up` + `test run all` run on Apple Silicon (2026-06-20).

### Phase 17 — Chain-driven test surface and context introspection

Phase 17 owns the decoupled `test init` / `test run <suite>|all` surface and the read-only `context`
command that renders the global lift composition with the current frame highlighted. It is `Done`:
`test run` **drives the real `project up`**, enforces the two hard fail-fast safety preconditions (refuse if
a `<project>.dhall` exists; refuse if a production cluster is running), uses `.test_data` (never `.data`)
under the L0 self-created-only delete-guard (`withSelfCreatedTestData`), and `context` is read-only and
uniform over all `<project>.dhall`s (§ Z, § X). Real-run-validated by `test run all` reporting `3/3 passed`
(2026-06-20). It is `Active` — **reopened by phase 19** (§ BB): `test.dhall` becomes a thin override and
`test run` **generates** the run's `<project>.dhall` from it via the project-owned `psTestConfig`, closing
the § Z code-vs-contract drift where the demo reuses a pre-existing config.

### Phase 18 — Service runtime command

Phase 18 owns the third DSL-driven core command, `service` (`init` / `schema` / `run`), for a project's
long-running roles (the `HostDaemon`/service run-model). `service run` is a leaf-frame pod entrypoint (not
an orchestrator) that fails fast unless the config declares a service role + valid variant; a binary
defines its service variants via a project-contributed service-handler registry (`HostBootstrap.Service`,
threaded through `ProjectSpec` with `withServices`); there is no `service down` (lifetime owned by the k8s
controller, torn down by `project destroy`); `project up`'s `deploy-chart` step deploys the pod whose
entrypoint is `service run`, its config delivered by a ConfigMap overriding the baked container
`<project>.dhall` (§ AA). It is `Done`: the command, registry, and demo `web serve` → `service run web`
migration landed in code and are **real-run-validated** — the live demo's web pod runs `service run web` and
serves HTTP 200 on the 16 GiB Apple-Silicon host (2026-06-19).

### Phase 19 — generic project model and no core defaults

Phase 19 makes `hostbootstrap-core` a generic library with **no hardcoded defaults**, parameterized over a
project's own config type. `ProjectSpec cfg tcfg` couples core to `cfg` only through the lift authority
(`cfg -> BinaryContext`, `BinaryContext -> cfg -> cfg`); defaults live only in a project-owned `psInit`,
which `project init` and the harness both reuse (DRY); `test.dhall` is a thin override and the harness
**generates** the run's `<project>.dhall` from it (`psTestConfig`), then deletes the generated config and
self-created `.test_data` on teardown (closing the § Z code-vs-contract drift); and a pure `SecretRef`
vocabulary keeps a secrets-strict consumer's production configs plaintext-free (§ BB). It is `Planned`
(documentation-only); it reopens phases 4, 8, 10, 15, and 17, which become `Active` because their `Done`
scope assumed core-owned defaults, a fixed universal config type, and a `test`-reuses-existing-config flow.

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
  phase-16 (reopens/builds on 4, 5, 14, 15; the project lifecycle command + the [Step] interpreter + the fixed surface)
  phase-17 (builds on 16, 10; the test surface that drives project up + the read-only context command)
  phase-18 (builds on 15, 16; the service runtime command + the service-handler registry) ← Done; service run web real-run-validated in the demo
  phase-19 (reopens 4, 8, 10, 15, 17; the generic project model: no core defaults, ProjectSpec cfg/tcfg, harness-generated config) -- Planned, documentation-only
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
