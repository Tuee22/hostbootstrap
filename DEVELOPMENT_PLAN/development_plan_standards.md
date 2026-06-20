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
├── phase-16-project-lifecycle-command.md
├── phase-17-chain-driven-test-and-context-introspection.md
├── phase-18-service-runtime-command.md
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
host-provider tools such as `colima` and `incus` (§ U); the in-VM tools they dispatch to are the VM's own
`$PATH` binaries reached through a single resolved host provider command (the VM is a separate machine —
the doctrine governs host invocation).

### L. Substrate and Ensure-Reconciler Contract

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) is owned by `hostbootstrap-core`.
**The purpose of the `ensure` suite is that the project binary is never blocked by a host dependency
that simply isn't installed.** Each host dependency is an idempotent `ensure` reconciler — a
host-applicability predicate plus a reconcile action — exposed as an optparse subcommand
(`ensure docker`, `ensure colima`, `ensure lima`, `ensure cuda`, `ensure homebrew`, `ensure ghc`,
`ensure tart`, `ensure incus`). A reconcile action **installs** the dependency if absent and is a verified no-op if
present (install-and-verify, not check-only), so an absent-but-installable dependency is **installed,
never a hard stop**. The **only** hard fail-fast surface in the entire system is the Python wrapper's
host minimums (§ M) — the irreducible host floor that cannot be auto-installed. The *one* fail-fast
inside the `ensure` suite is a reconciler run on the **wrong host** (an applicability misuse, e.g.
`ensure tart` on Linux) — a one-line diagnostic and a non-zero exit — which is a misuse error, **not**
an absent dependency; the two must never be conflated. `ensure incus` is the first reconciler applicable
on **both** apple-silicon and linux — on Apple it prepares the Colima-backed Incus provider for explicit
Incus workflows, and on Linux it initializes the native daemon that encapsulates a fresh linux host (§ U).
The worked demo's default Apple Silicon VM path uses Lima, not an Incus VM. The
kube tools (`kubectl`/`helm`/`kind`) are baked into the L0 base image and the cluster lifecycle that
drives them is L0 (Phase 5), so they need no separate host reconciler in the in-container path;
GPU-specific cluster tooling (`nvkind`) is the candidate a GPU consumer or the mid-layer
(`daemon-substrate`) contributes via the extension-stream merge (§ T). The `ensure` reconcilers are normally
invoked as **chain steps** within `project up` (§ Y), not as hand-run verbs; the standalone
`ensure <tool>` subcommand is retained only as a hidden debug surface. A provider reconciler reaches a
**usable** provider, not merely an installed binary — on Linux `ensure incus` also ensures the VM
capability (machine emulator + UEFI firmware) and the bridge egress a fresh VM needs to reach the network.

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
Docker, builds the project container, drives the VM provider, drives the cluster, and does everything
else it reasonably can. There is **no copy-out**: a binary built inside a
Linux container cannot exec on a general host such as Apple silicon, which is why the binary is built
host-native and the Python layer must ensure the host build toolchain first. All other host-management
logic lives in `hostbootstrap-core`; new host logic defaults to the project binary (Haskell), and a
Python addition must be justified by the pre-binary bootstrapping constraint. The shape the Python layer
runs — provision the host, build the pb host-native, hand off by exec — recurs at **every** frame the
binary later crosses (§ U): the Python bootstrapper is the **metal-frame instance** of the fractal
bootstrap, and each chain descent repeats provision → build the pb in the frame → hand off
`pb project up`.

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
- Inside a managed Linux VM (§ U) the same host-native build applies — Lima on Apple Silicon,
  native Incus on Linux. The VM is a fresh linux host: the pipx-installed `hostbootstrap` ensures the
  toolchain, builds the binary host-native, and execs it; the binary then ensures Docker and builds the
  container in the VM. The worked demo's pristine-host bootstrap counts **3 builds** — a metal
  orchestrator build plus, inside the pristine VM, the host-native binary build and the binary-driven
  project-container build — a demo-only illustration, not the standard workflow.

### O. Resource Budget and Cordoning

The host-level `<project>.dhall` declares a per-project resource budget (`cpu`, `memory`, `storage`) —
the **one ceiling** the project may not exceed, used **once**. The declared budget **is the VM wall**: the
VM (cordon #1) is sized to the budget, and the in-VM cluster (cordon #2) is a **slice within that wall**,
strictly smaller in every dimension so it fits inside the VM's spare capacity alongside the VM OS, Docker,
and image builds. The budget is **never** added to itself: there is no budget-sized VM "headroom" that
sizes the VM above the ceiling (that would count the one requirement twice and is forbidden — see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)). The project binary reads the budget
from its active config and projects narrower resource envelopes into child configs (§ X). It is enforced
with defense in depth: a Dhall-time `assert` (`Budget/fitsWithin`) at render, the pure
`verifyBudget`/`fitsBudget` before bring-up, and the applied wall at runtime — a sized Lima VM on Apple
Silicon, a sized Incus VM on Linux (§ U), the applied `docker update` kind-node cap, or `docker run` caps
(one-shot). All VM/node sizing is emitted by **one** canonical quantity parser/argument builder in
`hostbootstrap-core` and applied by the **project binary**; the Python bootstrapper does **not** ensure
Docker or cordon (§ M), so there is no second budget interpreter.
Storage is cordoned where the substrate allows (Colima `--disk` / incus `root,size` / a quota'd hostPath
on Linux), since `docker update` has no storage flag. The budget flows from the local host config into
child config projections, then into both the spinup cordon and the binary-generated configs.

### P. Fixed Command Surface And The Extension Streams

`hostbootstrap-core` exposes a **fixed** command surface plus a project entrypoint
(`runHostBootstrapCLI progName projectSpec`). Every project binary — and the bare `hostbootstrap` binary —
surfaces the **same** tree: the three DSL-driven commands `project init|up|down|destroy`,
`test init|run`, and `service init|schema|run` (§ Y, § Z, § AA), plus the read-only `context`
introspection command and `check-code`. There are **no per-project verbs**: `hostbootstrap-core` is a
**library of composable tools** (step kinds, reconcilers, the self-reference lift, service handlers), not a
CLI topology, so a project never adds a command. A project extends the core only through the
**extension streams** carried by `ProjectSpec`: its **lift chain** (`chain :: RootConfig -> [Step]`, § Y),
the **Dhall vocabulary**, the **schema-gen** `ConfigArtifact` registry, the **test seams** (a non-empty
test suite), and the **service handlers** (the `ServiceType` registry, possibly empty, § AA) — alongside
the project `check-code` action. The entrypoint validates those extension points before parser
construction: duplicate cases/artifacts/service variants are rejected, the test suite must be non-empty,
and `check-code` is supplied by construction rather than silently defaulted. `ProjectSpec` carries **no**
`ProjectCommand` deltas — the surface is closed (see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)). The bare `hostbootstrap` binary
(`hostbootstrap-core`'s own executable) uses the separate `runBareHostBootstrapCLI` entrypoint; it is
built like any project binary, not baked into the base image.

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

### T. Library Hierarchy, Extension Streams, and Run-Models

`hostbootstrap-core` is a **library of composable tools**, not a CLI topology; the command surface is
fixed (§ P) and is **not** an extension point. The reusable surface is a three-level Cabal library
hierarchy: `hostbootstrap-core` (L0) ◄ `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2); `mcts` consumes
L0 directly. Each level adds only its delta to the **parallel extension streams**, one additive merge idiom
each: the **lift chain** (`chain :: RootConfig -> [Step]` — the level below's host-management step kinds
with the project's own step kinds appended, interleaved and interpreted by the core `project` lifecycle,
§ Y); the **Dhall vocabulary** (`let C = ./Core.dhall`, embedded, never redefined); the **schema-gen**
`ConfigArtifact` registry (concatenated across levels through `ProjectSpec`); the **test-harness** `Seams`
(threaded through a non-empty `TestSuite`); and the **service handlers** (the `ServiceType` registry
dispatched by `service run`, possibly empty, § AA). A project integrates in one of two modes: freeze-import
+ the base-image `LABEL`/`ENTRYPOINT` contract (no Cabal dependency), or `source-repository-package` + the
`runHostBootstrapCLI` extension. The system runs one of four **run-models** — `OneShot` (one-shot
`docker run`), `HostNative` (host-native build + host exec), `HostDaemon`/service (a long-running role,
reached via `service run` as a leaf-frame pod entrypoint that the chain's `deploy-chart` step deploys,
§ AA), `Cluster` (kind+Helm) — selected within `project up`'s step interpretation (and, for the service
leaf, by the running pod's service-role config) by `(step × detected-substrate × library-layer ×
generated-topology)`, never declared imperatively.

### U. Host-Provider Axis And The Self-Reference Lift

A project binary crosses an execution-context boundary by invoking its **own** subcommand in the nested
context — the self-reference lift (`HostBootstrap.Lift`). Contexts compose as provider-backed frames,
outermost-first; the empty stack is the local host. The VM layer is provider-specific: Apple Silicon uses
Lima (`limactl shell <instance> -- ...`) for the demo VM, while native Linux uses Incus
(`incus exec <vm> -- ...`). A container is the `docker run --rm` layer whose `ENTRYPOINT` is the binary.
The stack nests — host → VM → container folds to the selected VM provider command followed by
`docker run --rm <image> <subcmd>`. Before a nested call crosses a boundary, the caller creates the
callee's `<project>.dhall` (§ X), so the callee can explicitly reason about its place even though it runs
the same command tree. Each nested call runs the same command tree, so a step runs "locally", and the
reconcilers stay context-agnostic (`HostConfig -> IO ()`) while dispatch is guarded by the local binary
context. The argv fold is pure (unit-tested) and honors § K: only the outermost host dispatch names a
tool the resolver maps to an absolute path; every nested tool is the target's own bare `$PATH` name. The
two-case `HostTarget = Local | InVM` is the tool-level lift, kept alongside; the subcommand-level lift
generalizes it to an n-level frame stack. L0 owns only the generic lift; the *specific* chain (the worked
demo's host → VM → container) is project logic. The chain is interpreted **recursively**: `project up`
runs the current frame's steps, then hands off `pb project up` into the next frame, so each binary owns
its own segment and the deploy is restartable from any frame (§ Y). Each frame transition repeats the same
three beats — provision the frame, build/install the pb in it, hand off `pb project up` — of which the
Python bootstrapper (§ M) is the metal-frame instance. See
[composition_methodology](../documents/architecture/composition_methodology.md).

### V. Layered Warm Store

The base-image warm Cabal store freeze is split by library layer: `core.freeze` (base +
`hostbootstrap-core` closure; imported by `mcts` and `daemon-substrate`) and `daemon.freeze`
(daemon-family deps; imported only by the daemon apps). Both are generated in-image by `cabal freeze` and
**never committed** (`.dockerignore`/`.gitignore` exclude them); each project imports only its layer's
fragment(s), so cache-hit and version-pinning track the hierarchy.

### W. Single Representation And The Harness That Drives The Chain

An operation has exactly **one** representation. A project's deploy is its **lift chain** — a pure
`chain :: RootConfig -> [Step]` value that *is* the project's identity; `project up` is its interpreter and
`--dry-run` renders the same value apply executes (§ Y). There is no second hand-written orchestration path
beside the chain — and the test harness is not one. The standardized test harness
(`HostBootstrap.Harness`) **drives the real `project up`** rather than re-expressing bring-up: per distinct
test configuration it writes a test-specific `<project>.dhall`, runs `project up` over the project's own
chain, runs the case assertions in the frame appropriate to each (reusing the self-reference lift, § U),
and tears the stack down with `project destroy`. The bring-up a test exercises is therefore **the same
chain** production uses — there is no parallel `seamSetup` that stands up a cluster a second way, and no
resource model that can drift between test and deploy. The harness owns only the case matrix, the per-case
assertions, and the test-config parameters; it never owns a second cluster-bring-up path. Re-expressing
deploy bring-up as a parallel chain of lifted ops alongside the chain — including inside a test seam —
would be a redundant representation. Cross-references: § Y (the chain and its recursive interpreter), § Z
(the chain-driven test surface and its safety preconditions), and § U (the self-reference lift the chain
and the in-frame assertions are built from).

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
- the project Dockerfile installs the binary, then runs
  `config init --role image-build-container --output /usr/local/bin/<project>.dhall` before any normal
  command;
- runtime container launches mount or materialize a parent-generated runtime config for the exact
  VM/container frame the container is launched into;
- a Kubernetes workload receives its context from the controller that owns identity and durable placement;
  for durable services, that controller is a `StatefulSet`.

The current context shape is project-extensible and carries enough typed information for the local command
gate: project/binary identity, **explicit context** (context kind), local capabilities, allowed command
classes, parent chain, topology frames, current frame, runtime witnesses, resource envelope, and
child-context creation rules. Each `<project>.dhall` carries one explicit context and **may declare more
than one role** — a single config can be both a project (deployment) authority and a `service` authority,
and each command checks the config declares the capability it needs (so a `.dhall` that is service-capable
but not project-capable runs `service run` and refuses `project up`). The relationship between a context
and the others is expressed in the **pure compositional lifts** — the topology is a pure frame graph with
parent links (§ U), not an implicit permission in the command line; it can represent arbitrary chains such
as host -> VM -> container -> cluster -> service pod, or host -> VM -> Pulumi role -> EKS cluster ->
workload. A process must fail before side effects when its local witnesses do not prove it is in the
declared current frame. Bootstrap/inspection entrypoints are the only binary
entrypoints allowed to run without an existing sibling context: help/version, `project init`, and the
read-only `context` introspection command (which absorbs the former `config schema` / `config show FILE` /
`config path` / static `config render` surfaces). All normal commands fail
fast with exit code 1 when the context file is missing, fails to decode, names a different
project/binary, does not declare the required capabilities, or does not permit the requested command. A
Phase 15 context also fails when required local witnesses cannot be verified. A
daemon/service command must refuse to start unless the context declares a daemon/service role;
host-orchestrator commands must refuse to run inside a cluster-service pod; and a VM-scoped kind/test
workflow must refuse to run directly on the host Docker daemon unless the Dhall declares a local
test-harness frame.

Every context's `<project>.dhall` is **generated by the project binary from passed Dhall parameters** —
some supplied at the frame and some **forwarded from the parent context's `<project>.dhall`** — so a child
config is a parameterized projection of its parent, never a hand-authored copy. The `context-init` chain
step inside `project up` (§ Y) performs that generation before each handoff; a Kubernetes service pod
receives its config the same way, as a **ConfigMap that overrides the image's baked container
`<project>.dhall`** (§ AA). The read-only `context` command (§ Z) treats **every** `<project>.dhall`
uniformly — it introspects the explicit context and renders the global compositional lift sequence
(`topologyFrames` / `parentChain`) with the current frame highlighted, regardless of which roles the config
declares; it performs no mutation. Phase 15 established the shared-substrate contract (the built binary
creates the host-level default, parent surfaces materialize nested configs, normal dispatch gates on the
sibling config); the reopened work (§ Y, § Z, § AA) makes the surface the fixed `project` / `test` /
`service` tree, folds child-config creation into the `context-init` step, supports multi-role configs and
forwarded parameters, and keeps `context` read-only.

### Y. Project Lifecycle Command And The Step Chain

A project's deploy is a pure value — its **lift chain**, `chain :: RootConfig -> [Step]` — interpreted by
the core lifecycle command `project`. The chain shape is **code**: it is the project's identity and the one
representation of its deployment (§ W). The sibling `<project>.dhall` carries **parameters + context +
witness**, never the chain shape; a copy of the binary verifies it is in the frame its `<project>.dhall`
describes, or fails fast (§ X). Optional structural variation (for example, deploy straight to Docker and
skip the VM) is a flag in the **root** `<project>.dhall`, so the chain is a pure function of the root
parameters.

- `project init` — fail-fast unless run as a fresh host-level binary with no sibling `<project>.dhall`;
  write the root config (host-orchestrator, no parent) with optional `--cpu` / `--memory` / `--storage` /
  `--ha-replicas`. Python triggers this idempotently after the host-native build (§ M).
- `project up` — interpret the chain **recursively** from the current frame: run the steps for this frame,
  then for the next nested frame provision it, build/install the pb in it, and hand off `pb project up`
  (the fractal bootstrap, § U). It is **idempotent** (reconcile-to-running); `--dry-run` renders the pure
  chain without acting.
- `project down` — stop services / clusters / VMs without deleting them (incus/Lima **stop**, not
  destroy); recurse in while each frame is still up, then stop on ascent. Best-effort and idempotent so a
  partial stack always tears down.
- `project destroy` — `down`, then delete everything that was spun up. Durable host `.data` is **always
  preserved** (the never-delete-`.data` invariant, § O).

The **Step algebra** is the reuse unit: `hostbootstrap-core` ships the host-management step kinds
(deploy-VM, `ensure-*`, copy-source, build-pb, build-image, `context-init`, deploy-kind, deploy-chart,
expose-port), and a project contributes its own step kinds into the same `[Step]` (the lift-chain stream,
§ T). Host and project steps interleave freely; a project's workload (a registry install, a web-serve, a
role) is expressed as steps in the chain, not as separate top-level verbs.

### Z. Chain-Driven Test Surface And Context Introspection

The test surface **drives the real `project up`** rather than re-expressing bring-up (§ W). It is the one
test engine; it owns the case matrix, the per-case assertions, and the test-config parameters, never a
second cluster-bring-up path.

- `test init` — runs only when a sibling `project` config already exists; writes the per-project
  `test.dhall` (the test DSL — the case matrix plus config overrides such as resources or secrets to pass
  through to the normal binary).
- `test run <suite>|all` — runs one or more suites; `all` is always a suite. It is **root-only** and fails
  fast without a `test.dhall` or from any non-root context. For each **distinct test configuration**
  (cases sharing a config share one stack; a case needing different resources/secrets declares a different
  config) the harness: (a) writes a test-specific `<project>.dhall` (the test-config overrides projected
  into a normal project config), (b) runs `project up` over the project's own chain, (c) runs that config's
  case assertions in the frame appropriate to each, reusing the self-reference lift (§ U) — e.g. a
  Playwright assertion as a container on the kind network in the VM frame, outside the cluster — and
  (d) tears the stack down with `project destroy`.

Two **hard fail-fast safety preconditions** are checked before *any* test runs, so a test never interferes
with production: (1) a sibling `<project>.dhall` already exists → refuse (never overwrite a production
config); (2) a production cluster is running → refuse (never touch production state). If either holds, **no
tests run**. Teardown removes **only** the `<project>.dhall` and the `.test_data` durable directory the
harness *created this run* — never a config or data directory it found (the delete-guard mirrors the
never-delete-`.data` invariant, § O); test durable storage is always `.test_data`, never `.data`.

`context` is a **read-only** command that treats **every** `<project>.dhall` uniformly: it introspects the
explicit context and renders the global compositional sequence of lifts (`topologyFrames` / `parentChain`)
with the current frame highlighted, so an operator can see the whole `metal → VM → container → cluster`
chain and where this binary lands in it — regardless of which roles the config declares. It performs no
mutation; child-config creation is the `context-init` chain step inside `project up` (§ Y), not a `context`
subcommand.

### AA. Service Runtime Command

`service` is the third DSL-driven core command (alongside `project` and `test`). It runs a project's
**long-running roles** — the `HostDaemon`/service run-model (§ T) — and is driven by a **service-configured**
`<project>.dhall`:

- `service init` — writes a service-configured `<project>.dhall` from passed parameters (forwarded from a
  parent where applicable, § X).
- `service schema` — prints the service config schema (reflected from the decoder so it cannot drift, § Q).
- `service run` — runs the selected role. There is **no `service down`**: a service's lifetime is owned by
  its Kubernetes controller (a `StatefulSet`/`Deployment`) and torn down by `project destroy` (§ Y).

`service run` is a **leaf-frame runtime command, never an orchestrator**: it assumes it is already placed
in its frame (typically a k8s pod) and runs the role; it brings up no VM or cluster. It **fails fast**
unless the effective `<project>.dhall` declares a **service role** and a valid **service variant** (the
same gate discipline as `project`/`test`, § X). A binary defines **more than one** service type through a
Dhall **ADT** (`ServiceType = < Web : … | WorkloadOrchestrator : … >`, with arbitrary per-variant
parameters); the project contributes the matching **service handlers** as a registry threaded through
`ProjectSpec` (§ P, § T), and `service run` dispatches on the variant. The registry **may be empty** — the
fixed surface is unchanged and `service run` simply fails fast when no service is configured, so not every
project ships a service.

`project up` and `service` **compose, they do not overlap**: the chain's `deploy-chart` step deploys the
pod whose entrypoint is `service run`, and the pod's config arrives as a **ConfigMap that overrides the
image's baked container `<project>.dhall`** (§ X). `project up` *deploys* the service; `service run` *is*
the service. A project's long-running workload is therefore a service variant reached through this fixed
command, not a per-project verb (the former demo `web serve` / `web bridge` verbs are dissolved — `web
serve` → `service run` (`Web` variant); `web bridge` → the build-image chain step; see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).
