# hostbootstrap Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md)

> **Purpose**: Define how the `hostbootstrap` development plan is organized, updated, and kept
> aligned with implementation, validation, and the governed `documents/` suite.

`hostbootstrap` is the reusable host-management layer for the project family
([`daemon-substrate`](https://github.com/Tuee22/daemon-substrate),
[`mcts`](https://github.com/Tuee22/mcts), and the future consumers
[`infernix`](https://github.com/Tuee22/infernix) and [`jitML`](https://github.com/Tuee22/jitML)).
It provides a Haskell `hostbootstrap-core` library plus a thin Python bootstrapper. This file is
canonical for `hostbootstrap`'s own plan; each consuming project keeps its own plan standards.

## Core Principles

### A. Continuous Execution-Ordered Narrative

The plan reads as one ordered buildout from the current pure-Python CLI to the target
Haskell-core library plus thin Python bootstrapper consumed by every project binary.

- Each phase is written after the previous phase in dependency order.
- When later implementation lands before an earlier phase's closure obligation, the later phase
  names the open dependency explicitly instead of pretending the prerequisite is closed.
- Phase 0 is always documentation and governance. Its **foundational** deliverables — the metadata
  standard, this plan tree, and the landed documentation validator — must close before any code-writing
  phase is marked `Active` or `Done`. Once that foundation has closed, Phase 0 may **reopen** to `Active`
  for an expanded doc-coverage obligation (e.g. a new architecture contract) without forcing the
  already-implemented code phases back to `Blocked`; the foundational closure, not Phase 0's momentary
  status, is what gates them.
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

### D. Declarative Current-State Language

Plan documents describe the intended supported architecture in present-tense declarative language.
Cleanup history belongs in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), not
in phase narrative.

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
└── legacy-tracking-for-deletion.md
```

Phase numbering may grow as later work is scoped. Adding or renaming a phase requires updating this
file, `README.md`, `00-overview.md`, and `system-components.md` in the same change.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative inventory for:

- `hostbootstrap-core` Haskell module surfaces (`HostBootstrap.*`)
- the `ensure` reconcilers and their host applicability
- the static-base `hostbootstrap.dhall` schema
- the thin Python bootstrapper surface
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
schema, and any stale compatibility surface. Each item names its location, why it is slated for
removal, and the owning phase or sprint. When cleanup lands, move the item from pending to
completed.

### J. README and Documents Harmony

The plan and the governed `documents/` suite must agree on current-state implementation status.
The root `README.md` is the finished-shape orientation document and may describe the target shape
even when not fully implemented, but it must not claim a capability is `Done`.

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
Each host dependency is an `ensure` reconciler — an idempotent value with a host-applicability
predicate and a reconcile action — exposed as an optparse subcommand (`ensure docker`,
`ensure colima`, `ensure cuda`, `ensure homebrew`, `ensure ghc`, `ensure tart`, `ensure incus`). A
reconcile action **installs** the dependency if absent and is a verified no-op if present
(install-and-verify, not check-only). A reconciler run on the wrong host fails fast with a one-line
diagnostic and a non-zero exit. `ensure incus` is the first reconciler applicable on **both**
apple-silicon and linux — it installs the host-provider that encapsulates a fresh linux host (§ U). The
kube tools (`kubectl`/`helm`/`kind`) are baked into the L0 base image and the cluster lifecycle that
drives them is L0 (Phase 5), so they need no separate host reconciler in the in-container path;
GPU-specific cluster tooling (`nvkind`) is the candidate a GPU consumer or the mid-layer
(`daemon-substrate`) contributes via the four-stream merge (§ T).

### M. Python-Thin / Haskell-Core Boundary

The Python bootstrapper does only what must run **before any project binary exists**: assert the
fail-fast host minimums and ensure the host toolchain prerequisites needed to **build** the binary, then
build the project binary **host-native** and exec it. It does **not** ensure Docker and does **not**
build the project container — those are not pre-binary necessities; the project binary, once running,
ensures Docker (provisioning the per-project Colima/incus VM on Apple), builds the project container,
drives the cluster, and does everything else it reasonably can. There is **no copy-out**: a binary built
inside a Linux container cannot exec on a general host such as Apple silicon, which is why the binary is
built host-native and the Python layer must ensure the host build toolchain first. All other
host-management logic lives in `hostbootstrap-core`; new host logic defaults to the project binary
(Haskell), and a Python addition must be justified by the pre-binary bootstrapping constraint.

### N. Host-Native Binary Build

Every project's binary is built **host-native** on every substrate — it is **not** built inside a Linux
container and copied out, because a binary built in a Linux container cannot exec on a general host (e.g.
Apple silicon). The universal pre-binary host dependency is therefore the **build toolchain**, not Docker.

- The Python bootstrapper ensures the host build toolchain (Homebrew → `ghcup` → GHC/Cabal on Apple; the
  equivalent on Linux) — the prerequisites to build the binary — then builds `./.build/<binary>`
  host-native and execs it. A `./.build/<binary>` is always present on the host.
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

The static-base `hostbootstrap.dhall` declares a per-project resource budget (`cpu`, `memory`,
`storage`) — the one ceiling the project may not exceed. It is enforced with defense in depth: a
Dhall-time `assert` (`Budget/fitsWithin`) at render, the pure `verifyBudget`/`fitsBudget` before
bring-up, and the applied wall at runtime — a sized Colima VM (Apple), a sized incus VM (§ U), the
applied `docker update` kind-node cap (Linux), or `docker run` caps (one-shot). All VM/node sizing is
emitted by **one** canonical quantity parser/argument builder in `hostbootstrap-core` and applied by the
**project binary** (the per-project Colima/incus VM via `ensure docker`; the kind-node cap via
`cluster up`); the Python bootstrapper does **not** ensure Docker or cordon (§ M), so there is no second
budget interpreter. Storage is cordoned where the substrate allows (Colima `--disk` / incus `root,size` /
a quota'd hostPath on Linux), since `docker update` has no storage flag. The budget flows from the static
tier into both the spinup cordon and the binary-generated configs.

### P. optparse Command-Tree Extension Contract

`hostbootstrap-core` exposes its subcommands as a composable optparse value plus a generic
entrypoint (`runHostBootstrapCLI progName projectCommands`). A project binary extends the core tree
with its own subcommands rather than re-implementing core verbs. This CLI tree is the first of the four
parallel extension streams the library hierarchy composes additively (§ T). The skeletal `hostbootstrap`
binary (`hostbootstrap-core`'s own executable) is the core tree with no project commands; it is built
like any project binary, not baked into the base image.

### Q. Configuration via Dhall

Configuration is typed Dhall in two kinds across three tiers:

- the **static-base** `hostbootstrap.dhall` (project, dockerfile, resource budget), identical in shape
  across projects, **read pre-binary by the Python bootstrapper via a pinned `dhall-to-json`** (Python
  has no project binary to call in-process yet; `dhall_tool.py` is retained for exactly this);
- the **rich project/deploy** Dhall and the **per-case test** Dhall, both **generated by the project
  binary** (`config render`) from a reusable Dhall vocabulary, each carrying the budget assertion.

The project binary also **emits its own schema** (`config schema`), reflected from its decoder types so
the schema cannot drift. `hostbootstrap-core` owns the static-base decoder (which also backs the
in-process `config show` after the binary exists) and the generation substrate; the rich schemas are the
binary's own. An anti-drift check keeps `Type.dhall` and the Python-side `package.dhall` the same shape.

### R. Quality Gate Contract

Static quality is a first-class requirement. The Haskell formatter is `ormolu`/`fourmolu` and
`hlint` runs against supported source roots, both pinned in the base image. Every image build, base
or derived, gates on the project's canonical `check-code` — for a derived image, a single in-Dockerfile
`RUN <project> check-code` stage whose body is project-defined. The standardized test harness's
`<project> test` report card is the project-level validation gate. The mechanical documentation
validator (`HostBootstrap.DocValidator`) is **landed** and runs through the code-check. The plan
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
(`runHostBootstrapCLI progName (lower ++ delta)`, appended, never shadowed); the **Dhall vocabulary**
(`let C = ./Core.dhall`, embedded, never redefined); the **schema-gen** `ConfigArtifact` registry
(concatenated across levels); and the **test-harness** `Seams`. A project integrates in one of two modes:
freeze-import + the base-image `LABEL`/`ENTRYPOINT` contract (no Cabal dependency), or
`source-repository-package` + the `runHostBootstrapCLI` extension. The system runs one of four
**run-models** — `OneShot` (one-shot `docker run`), `HostNative` (host-native build + host exec),
`HostDaemon` (a long-running host service), `Cluster` (kind+Helm) — selected by
`(verb × detected-substrate × library-layer × generated-topology)`, never declared in Dhall.

### U. Host-Provider Axis (incus)

`incus` is a first-class host-provider axis orthogonal to substrate: a target linux host is either the
local host or an incus VM (`HostTarget = Local | InVM`). Anything `hostbootstrap` deploys on an
unvirtualized linux host it can deploy inside an incus VM (build, ensure docker, kind, Harbor, run, the
harness) via a single `incus exec` dispatch; the VM is budget-cordoned by the one canonical parser (§ O).
`incus` is installed by `ensure incus` (§ L) and is **not** standardized for all workflows — it is used
in the worked demo to encapsulate a fresh linux host — but it is fully supported.

### V. Layered Warm Store

The base-image warm Cabal store freeze is split by library layer: `core.freeze` (base +
`hostbootstrap-core` closure; imported by `mcts` and `daemon-substrate`) and `daemon.freeze`
(daemon-family deps; imported only by the daemon apps). Both are generated in-image by `cabal freeze` and
**never committed** (`.dockerignore`/`.gitignore` exclude them); each project imports only its layer's
fragment(s), so cache-hit and version-pinning track the hierarchy.
