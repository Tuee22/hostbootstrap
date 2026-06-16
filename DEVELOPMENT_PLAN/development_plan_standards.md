# hostbootstrap Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md)

> **Purpose**: Define how the `hostbootstrap` development plan is organized, updated, and kept
> aligned with implementation, validation, and the governed `documents/` suite.

`hostbootstrap` is the reusable host-management layer for the project family
([`daemon-substrate`](https://github.com/Tuee22/daemon-substrate),
[`mcts`](https://github.com/Tuee22/mcts), [`infernix`](https://github.com/Tuee22/infernix), and
[`jitML`](https://github.com/Tuee22/jitML)).
It provides a Haskell `hostbootstrap-core` library plus a thin Python bootstrapper. This file is
canonical for `hostbootstrap`'s own plan; each consuming project keeps its own plan standards.

## Core Principles

### A. Continuous Execution-Ordered Narrative

The plan reads as one ordered, dependency-aware description of the current Haskell-core library plus
thin Python bootstrapper consumed by project binaries.

- Each phase is written after the previous phase in dependency order.
- When a later phase depends on an earlier phase's closure obligation, the later phase names that
  dependency explicitly instead of duplicating the earlier phase's ownership.
- Phase 0 is always documentation and governance. Its **foundational** deliverables — the metadata
  standard, this plan tree, and the documentation validator — gate every code-writing phase. Follow-on
  documentation obligations are tracked explicitly without changing the status of unrelated code phases.
- Newly discovered gaps are handled by adding explicit follow-on work, not by leaving stale
  completion claims in older documents.

### B. Detailed, Implementation-Oriented Content

The plan is intentionally concrete.

- Include real files, module paths, command shapes, and validation gates where they materially
  clarify what must be built.
- Examples need not be verbatim implementation, but they must not contradict the supported
  architecture.
- When the plan cites a consumer project, it distinguishes the reusable `hostbootstrap` concern
  from consumer-specific behavior that remains out of scope here.

### C. Honest Completion Tracking

Status describes the current repository state, not the intended future state.

| Status | Meaning |
|--------|---------|
| `Done` | Implemented and validated; no remaining work |
| `Active` | Partially closed; remaining work is listed explicitly |
| `Blocked` | Waiting on a named prerequisite |
| `Planned` | Ready to start; dependencies are already satisfied |

Rules:

- `Done` requires passing validation, aligned docs, and no remaining work in that phase's scope.
- `Active` requires a `Remaining Work` section.
- `Blocked` requires a `Blocked by` line naming the prerequisite phase or sprint.
- If Phase 0 is still open, later code-writing phases use `Blocked`, not `Planned`.
- A later phase may stay `Done` while an earlier phase is `Active`/`Blocked` only when the open
  item is a clearly named external dependency the later phase calls out.
- `Active` remaining work may be **real-run/real-build-gated** — validated by a real host run or a
  base-image build rather than the canonical code-check. Such work is **in scope and open**, never "out
  of scope"; the phase stays `Active` until the real run or build closes it (see the
  [README Validation Policy](README.md)).

### D. Declarative Current-State Language

Plan documents describe the supported architecture in present-tense declarative language. Cleanup
obligations and obsolete surface names belong in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), not in phase narrative.

### E. One Canonical Folder Model

The authoritative plan lives in this exact layout:

```text
DEVELOPMENT_PLAN/
├── development_plan_standards.md
├── README.md
├── 00-overview.md
├── system-components.md
├── phase-0-documentation-and-governance.md
├── phase-1-hostbootstrap-core-scaffolding.md
├── phase-2-host-tools-and-config.md
├── phase-3-ensure-reconcilers.md
├── phase-4-skeletal-dhall-and-command-tree.md
├── phase-5-cluster-lifecycle-and-resource-cordoning.md
├── phase-6-base-image-and-thin-python-bootstrapper.md
├── phase-7-consumer-migration.md
├── phase-8-dhall-generation-and-extension.md
├── phase-9-applied-cordon-and-one-parser.md
├── phase-10-standardized-test-harness.md
├── phase-11-incus-host-provider.md
├── phase-12-layered-warm-store.md
├── phase-13-hostbootstrap-demo.md
├── phase-14-composition-methodology.md
├── phase-15-binary-context-config.md
└── legacy-tracking-for-deletion.md
```

Phase numbering may grow as later work is scoped. Adding or renaming a phase requires updating this
file, `README.md`, `00-overview.md`, and `system-components.md` in the same change.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative inventory for:

- `hostbootstrap-core` Haskell module surfaces (`HostBootstrap.*`)
- the `ensure` reconcilers and their host applicability
- the project-local `<project>.dhall` schema
- the runtime binary-context fields inside that local config
- the thin Python bootstrapper surface
- the explicit pipx self-update surface for the Python bootstrapper
- the base image contents and warm Cabal store
- the optparse command tree that consuming project binaries extend

When the host-management architecture changes, update the component inventory in the same change.

### G. Phase Document Requirements

Each phase document groups its sprint-level sections under one `## Sprints` parent, with each
sprint nested one level deeper, in this format:

```markdown
## Sprints

### Sprint X.Y: Name [STATUS]

**Status**: Done | Active | Planned | Blocked
**Implementation**: `path/to/file` (required for Done, recommended for Active)
**Blocked by**: sprint id(s) (required for Blocked)
**Docs to update**: `documents/...`, `README.md`

#### Objective

#### Deliverables

#### Validation

#### Remaining Work
```

Additional sections (`Module Surface`, `Command Surface`, `Reconciler Contract`) are encouraged
when they clarify closure criteria. The decimal-insert form (`X.Y.Z`) is permitted when later
scoping splits a sprint and renumbering would churn more cross-references than it is worth.

### H. Documentation Requirements Section

Every phase document ends with a `## Documentation Requirements` section:

```markdown
## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/X.md` - design contract

**Engineering docs to create/update:**
- `documents/engineering/Y.md` - technical note

**Cross-references to add:**
- align the relevant plan and README entry points
```

Before Phase 0 closes, paths under `documents/` may not exist yet; they still appear in
`Docs to update` and `Documentation Requirements` so obligations are explicit.

### I. Explicit Cleanup and Removal Ledger

[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the authoritative cleanup
ledger for obsolete Python modules, the shelled `dhall-to-json` path, the three-execution-model
schema, and any stale compatibility surface. `Pending` lists existing cleanup obligations, `Retained
Current Surfaces` distinguishes intentional current code from cleanup work, and `Removed Surfaces`
names obsolete surfaces that must stay absent.

### J. README and Documents Harmony

The plan and the governed `documents/` suite must agree on current-state implementation status.
The root `README.md` is the finished-shape orientation document. It must not claim a capability is
implemented unless the plan marks the owning phase `Done`.

- `00-overview.md`, all phase files, and `system-components.md` use the same phase names and
  current-state claims.
- `README.md`, `AGENTS.md`, and `CLAUDE.md` are governed root documents; root docs that are not
  canonical for a topic summarize and link to the canonical `documents/` home.

## hostbootstrap-Specific Contracts

### K. Host-Tool Resolution Doctrine

External tools are resolved through a closed `HostTool` enumeration to absolute paths in
`hostbootstrap-core`. No library or project code calls `proc "<bare-command-name>"` that resolves
through `$PATH`; every invocation reads an absolute path from typed host configuration. The enum includes
the host-provider tool `incus` (§ U); the in-VM tools it dispatches to are the VM's own `$PATH` binaries
reached through the single resolved host `incus exec` (the VM is a separate machine — the doctrine governs
host invocation).

### L. Substrate and Ensure-Reconciler Contract

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) is owned by `hostbootstrap-core`.
**The purpose of the `ensure` suite is that the project binary is never blocked by a host dependency
that simply isn't installed.** Each host dependency is an idempotent `ensure` reconciler — a
host-applicability predicate plus a reconcile action — exposed as an optparse subcommand
(`ensure docker`, `ensure colima`, `ensure cuda`, `ensure homebrew`, `ensure ghc`, `ensure tart`,
`ensure incus`). A reconcile action **installs** the dependency if absent and is a verified no-op if
present (install-and-verify, not check-only), so an absent-but-installable dependency is **installed,
never a hard stop**. The **only** hard fail-fast surface in the entire system is the Python wrapper's
host minimums (§ M) — the irreducible host floor that cannot be auto-installed. The *one* fail-fast
inside the `ensure` suite is a reconciler run on the **wrong host** (an applicability misuse, e.g.
`ensure tart` on Linux) — a one-line diagnostic and a non-zero exit — which is a misuse error, **not**
an absent dependency; the two must never be conflated. `ensure incus` is the first reconciler applicable
on **both** apple-silicon and linux — on Apple it starts the Colima-backed Incus provider, and on Linux
it initializes the native daemon that encapsulates a fresh linux host (§ U). The
kube tools (`kubectl`/`helm`/`kind`) are baked into the L0 base image and the cluster lifecycle that
drives them is L0 (Phase 5), so they need no separate host reconciler in the in-container path;
GPU-specific cluster tooling (`nvkind`) is the candidate a GPU consumer or the mid-layer
(`daemon-substrate`) contributes via the four-stream merge (§ T).

### M. Python-Thin / Haskell-Core Boundary

The Python bootstrapper does only the **minimum to build the project binary**: derive the project name from
the Cabal file, assert the fail-fast host minimums and ensure the host toolchain prerequisites needed to
**build** the binary, then build the project binary **host-native**, trigger the binary's own idempotent
`config init --if-missing` so a default sibling `<project>.dhall` always exists, and exec it. Python itself
does not read or write Dhall — the triggered `config init` surface belongs to the binary, which owns the
Dhall; the trigger is the one Python step that runs **after** the binary exists and adds no Dhall logic to
Python, so a usable default config is always present without the user running `config init` by hand. Those
**fail-fast host minimums are the only hard
prerequisites in the entire system** — the irreducible host floor the wrapper cannot itself install (OS
version, passwordless sudo, Xcode CLT, Homebrew as the toolchain root); **every other host dependency the
binary needs is installed by the `ensure` suite (§ L) when the binary runs, so the binary is never
blocked by something merely absent.** The bootstrapper does **not** ensure Docker and does **not** build
the project container — those are not pre-binary necessities; the project binary, once running, ensures
Docker (provisioning the per-project Colima/incus VM on Apple), builds the project container, drives the
cluster, and does everything else it reasonably can. There is **no copy-out**: a binary built inside a
Linux container cannot exec on a general host such as Apple silicon, which is why the binary is built
host-native and the Python layer must ensure the host build toolchain first. All other host-management
logic lives in `hostbootstrap-core`; new host logic defaults to the project binary (Haskell), and a
Python addition must be justified by the pre-binary bootstrapping constraint.

The Python layer also owns its own explicit pipx self-update path, because that command replaces the
pipx-installed bootstrapper before or outside any project binary. This is distribution lifecycle, not
host-management logic: it is not an `ensure` reconciler and it must not contain Docker, Dhall, VM,
cluster, resource, or cordon behavior. With no versioned Python release channel, the canonical update
primitive is a forced pipx reinstall from the direct VCS requirement for the default branch. Self-update
is operator-invoked only; `doctor`, `build`, `run`, and `base` must not auto-update, auto-check GitHub
freshness, or fail merely because the wrapper is not at the latest commit.

### N. Host-Native Binary Build

Every project's binary is built **host-native** on every substrate — it is **not** built inside a Linux
container and copied out, because a binary built in a Linux container cannot exec on a general host (e.g.
Apple silicon). The universal pre-binary host dependency is therefore the **build toolchain**, not Docker.

- The Python bootstrapper ensures the host build toolchain (Homebrew → `ghcup` → GHC/Cabal on Apple; the
  equivalent on Linux) — the prerequisites to build the binary — then builds `./.build/<binary>`
  host-native, triggers the binary's idempotent `config init --if-missing` (the binary writes the Dhall,
  Python does not), and execs it. A
  `./.build/<binary>` and a default `./.build/<binary>.dhall` are always present on the host.
- The project **container** is a separate artifact the **project binary** builds (via Docker, `FROM` the
  base image) once it is running — the workload image and the mandatory code-check quality gate. The
  Python layer neither ensures Docker nor builds the container (§ M).
- Tart is build-only on Apple (Swift/Metal artifacts copied to `./.build/`); no built binary runs inside
  the Tart VM.
- Inside an incus VM (§ U) the same host-native build applies — the VM is a fresh linux host: the
  pipx-installed `hostbootstrap` ensures the toolchain, builds the binary host-native, and execs it; the
  binary then ensures Docker and builds the container in the VM. The worked demo's pristine-host bootstrap
  counts **3 builds** — a metal orchestrator build plus, inside the pristine VM, the host-native binary
  build and the binary-driven project-container build — a demo-only illustration, not the standard
  workflow.

### O. Resource Budget and Cordoning

The host-level `<project>.dhall` declares a per-project resource budget (`cpu`, `memory`, `storage`) —
the one ceiling the project may not exceed. The project binary reads that value from its active config and
projects narrower resource envelopes into child configs (§ X). It is enforced with defense in depth: a
Dhall-time `assert`
(`Budget/fitsWithin`) at render, the pure `verifyBudget`/`fitsBudget` before bring-up, and the applied
wall at runtime — a sized Colima VM (Apple), a sized incus VM (§ U), the applied `docker update`
kind-node cap (Linux), or `docker run` caps (one-shot). All VM/node sizing is emitted by **one**
canonical quantity parser/argument builder in `hostbootstrap-core` and applied by the **project binary**
(the per-project Colima/incus VM via `ensure docker`; the kind-node cap via `cluster up`); the Python
bootstrapper does **not** ensure Docker or cordon (§ M), so there is no second budget interpreter.
Storage is cordoned where the substrate allows (Colima `--disk` / incus `root,size` / a quota'd hostPath
on Linux), since `docker update` has no storage flag. The budget flows from the local host config into
child config projections, then into both the spinup cordon and the binary-generated configs.

### P. optparse Command-Tree Extension Contract

`hostbootstrap-core` exposes its subcommands as a composable optparse value plus a project entrypoint
(`runHostBootstrapCLI progName projectSpec`). A project binary extends the core tree through named
`ProjectCommand` values and a `ProjectSpec` that carries the non-empty test suite, project `check-code`
action, and project `ConfigArtifact` delta. The entrypoint validates those extension points before parser
construction: project commands cannot shadow core verbs, duplicate commands/cases/artifacts are rejected,
the test suite must be non-empty, and `check-code` is supplied by construction rather than silently
defaulted. This CLI tree is the first of the four parallel extension streams the library hierarchy
composes additively (§ T). The bare `hostbootstrap` binary (`hostbootstrap-core`'s own executable) uses
the separate `runBareHostBootstrapCLI` entrypoint; it is built like any project binary, not baked into the
base image.

### Q. Configuration via Dhall

Configuration is typed Dhall in distinct roles:

- the **local runtime config** `<project>.dhall`, generated by the built project binary, read from next to
  the executable before normal command dispatch, and edited by the user for host-level settings;
- the **generated child config** `<project>.dhall`, materialized by a parent binary at VM, container,
  daemon, and service boundaries as a narrower projection;
- the **rich project/deploy** Dhall and the **per-case test** Dhall, both **generated by the project
  binary** from a reusable Dhall vocabulary, each carrying the budget assertion. The ungated
  `config render` surface renders static registry examples; runtime deploy and child projections are
  emitted by commands that have already validated the active local config.

The project binary also **emits its own schema** (`config schema`) and default config (`config init`),
reflected from its decoder types where possible so the schema cannot drift. Python derives the project
name from the Cabal file and has no Dhall-facing configuration role beyond triggering the binary's
idempotent `config init --if-missing` after the build so a default config always exists; it never reads or
writes Dhall itself.

### R. Quality Gate Contract

Static quality is a first-class requirement. The Haskell formatter is `ormolu`/`fourmolu` and
`hlint` runs against supported source roots, both pinned in the base image. Every image build, base
or derived, gates on the project's canonical `check-code` — for a derived image, a single in-Dockerfile
`RUN <project> check-code` stage whose body is project-defined. The standardized test harness's
`<project> test` report card is the project-level validation gate. The mechanical documentation
validator (`HostBootstrap.DocValidator`) runs through the code-check. The plan
distinguishes mechanically enforced gates from editor-only guidance.

### S. Imported Practices and Explicit Non-Adoption

`hostbootstrap` borrows the governance shape (metadata blocks, phase plan structure, completion
tracking, declarative current-state language) from the consumer projects. It does not adopt any
consumer's product features, runtime surfaces, daemon-role model, or hardware-correctness
validation cadence; those remain consumer concerns. Non-adopted external doctrine must not be
treated as a current blocker or completion criterion. The four run-models and the standardized test
harness, however, are `hostbootstrap`-**owned** contracts that downstream refactors follow (§ T).

### T. Library Hierarchy, Four-Stream Extension, and Run-Models

The reusable surface is a three-level Cabal library hierarchy: `hostbootstrap-core` (L0) ◄
`daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2); `mcts` consumes L0 directly. Each level adds only its
delta to **four parallel streams**, one additive merge idiom each: the optparse **CLI tree**
(`runHostBootstrapCLI progName projectSpec`, with named `ProjectCommand` deltas appended after validation
and never shadowed); the **Dhall vocabulary** (`let C = ./Core.dhall`, embedded, never redefined); the
**schema-gen** `ConfigArtifact` registry (concatenated across levels through `ProjectSpec`); and the
**test-harness** `Seams` (threaded through a non-empty `TestSuite`). A project integrates in one of two
modes: freeze-import + the base-image `LABEL`/`ENTRYPOINT` contract (no Cabal dependency), or
`source-repository-package` + the `runHostBootstrapCLI` extension. The system runs one of four
**run-models** — `OneShot` (one-shot `docker run`), `HostNative` (host-native build + host exec),
`HostDaemon` (a long-running host service), `Cluster` (kind+Helm) — selected by
`(verb × detected-substrate × library-layer × generated-topology)`, never declared in Dhall.

### U. Host-Provider Axis And The Self-Reference Lift

A project binary crosses an execution-context boundary by invoking its **own** subcommand in the nested
context — the self-reference lift (`HostBootstrap.Lift`). Contexts compose as a stack of layers,
outermost-first; the empty stack is the local host. `incus` is the VM layer (a target linux host is the
local host or an incus VM, reached by one `incus exec`); a container is the `docker run --rm` layer
(whose `ENTRYPOINT` is the binary); the stack nests — host → VM → container folds to
`incus exec <vm> -- docker run --rm <image> <subcmd>`. Before a nested call crosses a boundary, the
caller creates the callee's `<project>.dhall` (§ X), so the callee can explicitly
reason about its place even though it runs the same command tree. Each nested call runs the same command
tree, so a step runs "locally", and the reconcilers stay context-agnostic (`HostConfig -> IO ()`) while
dispatch is guarded by the local binary context. The argv fold is pure (unit-tested) and honors § K: only
the outermost host
dispatch names a tool the resolver maps to an absolute path; every nested tool is the target's own bare
`$PATH` name. The two-case `HostTarget = Local | InVM` is the tool-level lift, kept alongside; the
subcommand-level lift generalizes it to the n-level stack (`Local | InVM | InContainer`). `incus` is
provisioned by `ensure incus` (§ L) and each layer is budget-cordoned by the one canonical parser (§ O).
L0 owns only the generic lift; the *specific* chain (the worked demo's host → VM → container) is project
logic. `incus` is **not** standardized for all workflows — the demo uses it to encapsulate a fresh linux
host — but it is fully supported. See
[composition_methodology](../documents/architecture/composition_methodology.md).

### V. Layered Warm Store

The base-image warm Cabal store freeze is split by library layer: `core.freeze` (base +
`hostbootstrap-core` closure; imported by `mcts` and `daemon-substrate`) and `daemon.freeze`
(daemon-family deps; imported only by the daemon apps). Both are generated in-image by `cabal freeze` and
**never committed** (`.dockerignore`/`.gitignore` exclude them); each project imports only its layer's
fragment(s), so cache-hit and version-pinning track the hierarchy.

### W. Single Representation And The Lifted Test Workflow

An operation has exactly **one** representation. The standardized test harness (`HostBootstrap.Harness`:
`runMatrix` + `Seams`) is the context-agnostic test engine — it brings up an isolated per-case
environment, runs the case body, and tears it down, invoking its reconcilers (e.g. `clusterUp`) as
`HostConfig -> IO ()` **locally**, unaware of any enclosing context. The harness is therefore a **lift
target**, not a lift-aware component: there is **no** `LiftContext` inside it, and that is correct (per the
self-reference-lift rule, § U). A consumer composes its deploy as a **single** explicit lift sequence
(§ U) whose final compute step **lifts the whole test workflow** into the project container in the VM — it
folds to `incus exec <vm> -- docker run --rm <image> test all`. Inside that lifted context the harness
runs `clusterUp` "locally" on the VM's Docker (the mounted socket), so the kind cluster lives **in the
VM**, reached with no second "bring up a cluster" path. Re-expressing cluster bring-up / Harbor / web-serve
/ e2e as a **separate** chain of lifted ops alongside the harness is a **redundant representation**: it
duplicates the harness and double-creates clusters when it lifts a harness case. There is one
representation, and the harness is it. Cross-references: § T (the harness and the four-stream extension)
and § U (the self-reference lift the deploy sequence is built from).

### X. Binary Context Configuration And Command Gating

Every project binary must know where it is in the global composition chain through a sibling runtime
config file:

```text
<project>.dhall
```

Python derives `<project>` from the Cabal file, builds the host-native binary, triggers its idempotent
`config init --if-missing`, and execs it. The built binary owns `config init` / schema / help surfaces for
creating the first host-level `./.build/<project>.dhall`; the post-build trigger merely ensures that
default is present (the binary writes it, Python does not). After that, each nested project binary receives
or creates its own local config before it runs:

- a VM bootstrap creates a VM-local context before launching the project binary inside the VM;
- a project Dockerfile installs the binary, then runs
  `config init --role vm-project-container --output /usr/local/bin/<project>.dhall` before any normal
  command;
- a Kubernetes workload receives its context from the controller that owns identity and durable placement;
  for durable services, that controller is a `StatefulSet`.

The context shape is project-extensible, but it must carry enough typed information for local command
gating: project/binary identity, context kind, parent chain, local capabilities, allowed command classes,
resource envelope, and child-context creation rules. Bootstrap/inspection entrypoints are the only binary
entrypoints allowed to run without an existing sibling context: help/version, `config init`,
`config schema`, `config show FILE`, `config path`, and static `config render`. All normal commands fail
fast with exit code 1 when the context file is missing, fails to decode, names a different
project/binary, claims unverifiable local capabilities, or does not permit the requested command. A
daemon/service command must refuse to start unless the context declares a daemon/service role;
host-orchestrator commands must refuse to run inside a cluster-service pod.

Phase 15 implements this contract in the shared substrate: the built project binary creates the host-level
default with `config init`, parent/container creation surfaces materialize nested configs, and normal
command dispatch uses the sibling project config as its runtime authority.
