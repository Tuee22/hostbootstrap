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

### A. One Continuous Constructive Narrative

The plan is a **build recipe, not a repair log**. It reads as one continuous narrative that
constructs the Haskell `hostbootstrap-core` library plus thin Python bootstrapper from nothing, and
**phase numbers are the execution order**. Following phases 0..N in order, with only the artifacts of
phases ≤ *n* available at phase *n*, must produce the current architecture.

- **Numerical order is executable order.** A phase declares `Depends on` naming only **strictly
  lower-numbered** phases. There is no separate landing-order graph, and a later phase never gates an
  earlier one.
- **A `Remaining Work` section never cites a later phase.** The `Depends on` field is not the only place
  the forbidden claim can be made: "this closes when phase 15 lands", written in `Remaining Work`, is the
  same claim in prose. A `Remaining Work` section therefore states only what *this* phase owes. Saying who
  owns what is different and stays legal — but it belongs in `## Phase Objective`, or in the sprint's own
  `#### Objective`, because no reading of prose can separate "I am blocked by 16" from "16 owns that", and
  the section a sentence sits in can.
- **The narrative is strictly additive.** No phase removes, retires, replaces, reverses, or supersedes
  a surface an earlier phase introduced. *Extending* an earlier phase's contract is expected;
  *contradicting* it is not. If work would delete or replace something an earlier phase built, that
  earlier phase is wrong.
- **A discovered design error rewrites the phase that introduced it**, in place, so the wrong surface
  is never introduced at all. Validation then resumes from that phase forward. A design error is never
  recorded as a later corrective sprint, a reopening, or a follow-on cleanup.
- **Renumbering is required whenever dependency order changes.** Durable identity comes from a phase's
  **name**, not its number. Documents outside `DEVELOPMENT_PLAN/` therefore cite phases by name and
  link — never by number — which is what keeps renumbering cheap enough to be routine.
- **No historical strata.** There are no `Historical`, `Superseded`, `Retired`, `Corrected`, or
  reproduced-defect sprints, and no phase narrates what the repository used to do. Git holds the
  history; the plan holds the design. Design *justification* that a reader needs in order not to
  reintroduce a known-bad shape belongs in [rationale.md](rationale.md), stated in the present tense.
- **Every phase is independently validatable** by a gate that runs with only phases ≤ *n* built, and
  declares at most one substrate beyond the `linux-cpu` baseline (§ II).
- **Phase 0 is always documentation and governance.** Its deliverables — the metadata standard, this
  plan tree, and the documentation validator — precede every code-writing phase.
- **This doctrine governs future refactors.** An architectural change rewrites the narrative so that
  the new architecture is what the plan builds. It is not appended as a correction to a narrative that
  builds the old one.

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
| `Done` | Implemented, and its own declared gate passes |
| `Active` | Partially built; remaining work is listed explicitly |
| `Planned` | Not started; every phase it depends on is `Done` |

There is deliberately no `Blocked` and no `Superseded`. Under § A a phase depends only on lower-numbered
phases, so an unstarted phase whose predecessors are complete is `Planned` and one whose predecessors are
not is simply not reached yet — nothing waits on a *later* phase, so nothing is blocked. And because the
narrative is strictly additive, no phase is ever superseded by another; a wrong phase is rewritten.

Rules:

- `Done` requires the phase's own declared gate to pass, aligned governed documentation, and no
  remaining work in its scope.
- `Active` requires a non-empty `## Remaining Work` section, spelled exactly that. One heading means a
  reader and a validator find the same thing in every phase.
- **A phase closes on its own gate.** A phase never carries a closure obligation that needs hardware it
  does not declare. Confirmation of a non-baseline host or accelerator dimension is owned by the acceptance
  phase that runs it (§ II), which lists what it confirms; the universal `linux-cpu` gate itself remains
  runnable through every supported host realization.
- Statuses are **derived by checking the repository**, never inherited from an earlier version of the
  plan. When phase boundaries are re-cut, every status is re-verified against the code.
- A phase's status must match its row in the [README](README.md) table, which is the sole cross-phase
  roll-up (§ J).
- Exact test counts and real-run results are dated validation evidence recorded against the gate that
  produced them. They are never promoted to a repository-wide "current count".
- **A frozen digest covers only what its sprint owns.** A sprint may freeze the bytes of a module, a
  stanza, or a set of rows it is responsible for; it may not freeze a whole shared file whose other parts
  belong to other phases. A digest over the complete package description makes any sprint that adds a test
  module break the evidence of every sprint that froze it — a coupling between phases that no dependency
  edge justifies, and that § A's numerical order cannot express. The narrower freeze proves the same
  thing about the same subject.

### D. Declarative Current-State Language

Every objective, deliverable, and acceptance criterion describes what the phase **builds**, in
present-tense declarative language. A phase says "the harness holds the four ownership clauses over its
data root", never "the lock directory is replaced by".

Obsolete names do not appear anywhere in the plan. There is no exemption for a labelled historical
record, because under § A there is no historical stratum to label: a surface the architecture does not
have is a surface no phase introduces. The one permitted mention of a shape the project does *not* use
is in [rationale.md](rationale.md), where naming a rejected alternative is the whole point — and even
there it is written as present-tense design justification ("a bare exclusive-create binds a pathname and
satisfies none of the four clauses"), not as a chronicle.

Dated validation evidence is not narrative and is exempt from this rule only in the narrow sense that it
records a date and a host: it states which gate passed, when, and on what substrate, and it makes no
claim about what the repository previously did.

### E. One Canonical Folder Model

The authoritative plan lives in this exact layout:

```text
DEVELOPMENT_PLAN/
├── development_plan_standards.md
├── README.md
├── 00-overview.md
├── system-components.md
├── rationale.md
├── phase-0-governance-and-documentation-standards.md
├── phase-1-python-pre-binary-floor.md
├── phase-2-haskell-core-scaffolding.md
├── phase-3-host-tools-and-substrate-detection.md
├── phase-4-protected-store.md
├── phase-5-installed-identity-and-authority-kernels.md
├── phase-6-canonical-quantities-and-reconcile-results.md
├── phase-7-dhall-configuration-and-project-model.md
├── phase-8-ensure-reconcilers.md
├── phase-9-lifecycle-modes-and-run-leases.md
├── phase-10-sessions-journal-and-fences.md
├── phase-11-prepared-operations.md
├── phase-12-step-algebra-and-project-plan.md
├── phase-13-authenticated-handoff-and-child-admission.md
├── phase-14-ownership-clauses-and-reservations.md
├── phase-15-host-providers-and-the-lift.md
├── phase-16-cluster-lifecycle-and-cordoning.md
├── phase-17-recursive-lifecycle-command.md
├── phase-18-recovery-and-migration.md
├── phase-19-test-harness-and-run-ownership.md
├── phase-20-test-and-context-commands.md
├── phase-21-composition-and-network-algebra.md
├── phase-22-service-runtime.md
├── phase-23-base-image-and-warm-store.md
├── phase-24-worked-demo.md
├── phase-25-apple-silicon-substrate.md
├── phase-26-nvidia-gpu-substrate.md
├── phase-27-windows-and-wsl2-substrate.md
├── phase-28-host-portability-acceptance.md
└── phase-29-documentation-reconciliation.md
```

The `phase-NN-*.md` set is **contiguous from 0 with no gaps and no duplicates**, and `NN` is the
execution position (§ A). Inserting a phase therefore renumbers every phase after it, and that is
expected rather than avoided; the same change updates this file, `README.md`, `00-overview.md`, and
`system-components.md`. Documents outside this directory are unaffected, because they cite phases by
name and link (§ J).

Obsolete shapes do not belong in a phase narrative. A shape that is absent stays absent through a mechanical
guard in the validator or tests; a still-standing unwanted shape appears only in
[legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md), with the deleting phase named in that
phase's own Remaining Work (§ I).

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

### G. Phase and Sprint Document Requirements

A phase document opens with this header, then groups its sprints under one `## Sprints` parent:

```markdown
# Phase N — Name

**Status**: Done | Active | Planned
**Depends on**: Phase A, Phase B (by name; every one strictly lower-numbered)
**Substrates**: linux-cpu
**Gate**: the exact command that closes this phase

> **Purpose**: one sentence naming what this phase adds to the build.

## Phase Objective

## Sprints

## Remaining Work

## Documentation Requirements
```

`## Remaining Work` is required while the phase is `Active` (§ C) and says "None." once it is not. It
states what this phase owes and nothing else (§ A); a boundary with another phase belongs in
`## Phase Objective`.

Each sprint is nested one level deeper:

```markdown
### Sprint N.M: Name [STATUS]

**Status**: Done | Active | Planned
**Implementation**: `path/to/file` (required for Done, recommended for Active)
**Substrates**: linux-cpu
**Docs to update**: `documents/...`

#### Objective

#### Deliverables

#### Validation

#### Remaining Work
```

Additional sections (`Module Surface`, `Command Surface`, `Reconciler Contract`, `Objective boundary`) are
encouraged when they clarify closure criteria.

Every sprint carries `#### Remaining Work`, including a `Done` one, where it begins with "None." — often
followed by the boundary note saying which phase owns what this sprint does not. A `Done` sprint that
declares work is not done, and one whose only outstanding item is a live confirmation is closed here with
that confirmation listed by the acceptance phase declaring the hardware (§ II).

**Sprint size budget.** A sprint is one working session. It lands **at most one new named
contract/type, or one call-site adoption**, and stays within:

- ≤ 8 deliverable bullets;
- ≤ ~400 lines of production Haskell across ≤ 3 source modules, plus their specs;
- closable by the **host static gate** alone (§ II) — `cabal test all --ghc-options=-Werror` from
  `core/`, `poetry run python -m hostbootstrap.check_code`, and
  `poetry run python -m hostbootstrap.test_all`.

A live-substrate confirmation is never in the same sprint as the change it confirms; it belongs to a
substrate phase (§ II). A sprint whose `#### Remaining Work` has grown into a chronicle has exceeded the
budget and must be split into further sprints, and its dated evidence recorded against the gate rather
than narrated.

Because a phase depends only on lower-numbered phases (§ A), a sprint has no `Blocked by` field: there is
nothing later for it to wait on.

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

### I. Absence Guards, and the Legacy Code Ledger

The plan carries no cleanup ledger of **plan obligations**, because a cleanup obligation is a reversal
(§ A): a surface the architecture does not want is removed by rewriting the phase that introduced it,
after which no phase introduces it and there is nothing to track. No phase records a corrective sprint,
a reopening, or a follow-on cleanup, and no phase narrative names an obsolete shape (§ D).

What remains useful is the **absence guard** — a mechanical assertion that a shape known to be wrong has
not crept back. An absence guard is a test or validator check, never a plan document, and it names the
[rationale.md](rationale.md) entry that explains why the shape is wrong. Examples: no module exposes a
config-owner lock path; no adapter is reachable without a prepared operation; no phase document uses
reversal vocabulary.

A guard is not a substitute for the narrative. If a guard would be needed to stop a phase from
introducing a bad surface, the phase is wrong and is rewritten.

**The legacy code ledger.** A guard asserts that a wrong shape is *gone*. The distinct case is a shape
that is **still standing in the tree** — code the architecture does not want, which a named phase
deletes when it completes. That is repository state, not narrative, and
[legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) is its one home.

The distinction is what keeps this from becoming the ledger the first paragraph forbids:

- a **phase narrative** says what that phase builds, in present tense, and never mentions the shape;
- the **ledger** says what is still present and which phase's completion removes it.

Every row therefore names a **deleting phase**, and a row whose phase does not resolve is a validator
failure — an unowned row is exactly how a ledger rots into a repair log. A row is removed when the
shape is, and an empty ledger is the healthy end state rather than a document to keep populated. The
ledger is not a work queue: it schedules nothing, and the deleting phase's own `Remaining Work` is
where that work is stated.

### J. README and Documents Harmony

The plan and the governed `documents/` suite must agree on current-state implementation status.
The root `README.md` is the finished-shape orientation document. It must not claim a capability is
implemented unless the plan marks the owning phase `Done`.

- `DEVELOPMENT_PLAN/README.md` is the **single cross-phase status source of truth**. Its phase table is
  the only place that summarizes every phase's status, and each cell is short — status plus the current
  sprint. A phase document carries the matching local `**Status**`; `00-overview.md` and
  `system-components.md` link to the table instead of maintaining another roll-up.
- Exact test counts and real-run results are dated validation evidence, never a second “current suite”
  status. They live with the sprint whose gate produced them; orientation and inventory documents do not
  copy a mutable current count.
- **Documents outside `DEVELOPMENT_PLAN/` cite a phase by name and link, never by number.** The link text is
  the phase's name — "the prepared-operations phase" — and the link target carries the number. A bare
  `Phase 11` in prose is forbidden, because numbers are execution positions and change when a phase is
  inserted (§ A, § E) while names do not. The same rule applies to Haskell and Python comments that reference
  the plan.
- Within `DEVELOPMENT_PLAN/`, a phase may cite another by number *and* name, since the co-edit obligation
  in § E keeps them consistent.
- `README.md`, `AGENTS.md`, and `CLAUDE.md` are governed root documents; root docs that are not
  canonical for a topic summarize and link to the canonical `documents/` home.

### II. Universal Baseline, Host Realizations, and Acceptance Phases

`linux-cpu` is the **universal baseline substrate** and the one substrate invariant. It names the
Linux/container environment available on every supported host for portable project code, static gates, and
ordinary CPU work; it does not mean that the outer physical host must itself be Linux, and it is not the only
hardware context the DSL can target. Every supported host realizes that floor through its platform provider:

| Outer host realization | Universal `linux-cpu` realization |
|---|---|
| native Linux | native Linux container/runtime path |
| Apple Silicon | Lima/Colima Linux VM and container path |
| Windows | WSL2 Linux VM and container path |

`hostbootstrap` is a DSL for lifting an arbitrary application into a selected hardware context. The plan and
project configuration describe that context and the typed route into it; the host-native bootstrap detects
and manages the outer host, establishes the required provider, and re-establishes the project binary at each
declared frame. A target may be the universal `linux-cpu` floor or a more specific context such as Apple
Metal, NVIDIA GPU, or Windows-host CUDA. Those contexts are real execution targets, not mere validation
labels, and their additional capabilities never weaken the portable `linux-cpu` contract.

For the baseline route, the host-native bootstrap binary establishes the provider, re-establishes the
project binary inside the Linux environment, and runs the baseline gate there.

The plan therefore distinguishes two gates, and a phase says which one closes it:

- the **host static gate** — `cabal test all --ghc-options=-Werror` from `core/`,
  `poetry run python -m hostbootstrap.check_code`, and `poetry run python -m hostbootstrap.test_all`,
  each run as an ordinary process of the **outer host**. It proves the pure, typed, and lexical
  contracts: type boundaries, compile-fail diagnostics, codecs, source-shape guards, plan projections,
  and the documentation validator. Because § N builds every binary host-native, this gate must pass
  host-native on **every** supported outer host realization — macOS, Linux, and Windows alike (§ JJ);
- the **`linux-cpu` substrate gate** — a gate whose gated process and its POSIX/container effects
  execute inside the realized Linux substrate. It may be launched from any supported host, but a
  native Windows or macOS process is not one of these merely because its assertions are otherwise
  static.

Neither substitutes for the other. A host static gate proves nothing about a provider, a container, or
a POSIX process boundary; a substrate gate on one realization proves nothing about whether the same
sources build and self-test on another outer host.

Running the host static gate natively on Windows or macOS is **not** a substrate declaration. A phase
does not acquire `**Substrates**: windows` by having its static gate pass on a Windows outer host, and
outer-host portability never counts against the one-substrate budget below.

This distinction is normative vocabulary throughout the plan:

- **baseline substrate** means the invariant `linux-cpu` environment every supported host can realize;
- **hardware context** means the concrete target selected by the DSL, including its substrate,
  accelerator, provider, topology, and capabilities;
- **outer host realization** means the physical host and provider used to realize it. It is not the unit a
  host static gate run is evidence about — that is the **gate host** (§ JJ), the OS, architecture, and
  toolchain the gate process itself runs on, which may be metal, a virtual machine, a container, or a WSL2
  distribution. Substrate selection and acceptance phases speak of outer hosts; gate evidence speaks of
  gate hosts;
- **host static gate** and **`linux-cpu` substrate gate** mean exactly the two gates defined above;
- the closed `SubstrateName` detector classifies the outer host realization for provider selection and does
  not redefine the universal baseline;
- provider differences may affect transport and ownership mechanics, while the selected hardware context
  may add real capabilities beyond `linux-cpu`; neither may contradict the baseline contract.

Every baseline phase that builds a contract targets the universal `linux-cpu` substrate, and its gate runs
in one realization of that substrate or is pure-static. A hardware-context acceptance phase additionally
targets the one context it declares.

- A phase declares `**Substrates**:` and may name **at most one** substrate beyond `linux-cpu`.
- Non-baseline hardware contexts and acceptance dimensions — Apple/Metal, NVIDIA acceleration, and
  Windows-host CUDA — are each owned by exactly one **acceptance phase**, placed at the end of the narrative. An
  acceptance phase adds any remaining host/provider- or accelerator-only realization and confirms both the
  universal `linux-cpu` floor and the selected context's additional behavior on real hardware.
- **Acceptance phases are terminal**: nothing depends on them. Lack of Apple, NVIDIA, or Windows hardware
  prevents only that realization's acceptance; it never prevents a supported host from realizing and
  validating the universal `linux-cpu` baseline through its own provider.
- An acceptance phase lists what it confirms, so a baseline phase closing on its static gate does not
  silently drop live coverage.

Three limits are recorded here because they are easy to assume away. `fourmolu` and `hlint` run only inside
the container `check-code`, so the host static gate is not the complete quality gate — the phase that owns
the container gate owns those two. The long demo gate brings up real provider and cluster state under
the project's own identity, so it runs on a disposable host, never a working one. And a host static gate
run is evidence for the one outer host that ran it, so its dated evidence names that host and a passing
run on one outer host is not a claim about another.

## hostbootstrap-Specific Contracts

Sections K–NN are the normative contracts. They define what a phase's closure makes true; they are not
blanket claims that every invariant is already enforced. The [README phase table](README.md) and each
phase's own `**Status**` distinguish what is built from what is still ahead in the narrative. When a
contract below conflicts with current code, the owning phase is `Active` — the contract is never weakened
and the illegal state is never described as supported.

Each contract opens with an `**Owning phase**:` line naming that phase by name and link. The field is
required because inferring an owner from any phase a section happens to cite is not the same claim — § O
mentions ten phases and is owned by one. Where a contract genuinely has two halves with different owners,
the field says so and says which half is whose. A contract is stated once, in its final form: there is no
earlier weaker version of it anywhere in the plan (§ A).

### K. Host-Tool Resolution Doctrine

**Owning phase**: the [host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md)
owns the boundary; the [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md)
owns the enumeration's membership.

External tools use a closed package-owned resolver and are invoked by absolute path. The ordinary resolver is
the closed `HostTool` enumeration in `hostbootstrap-core`; no library or project code calls
`proc "<bare-command-name>"` against ambient `$PATH`, and ordinary invocations read their absolute path from
typed host configuration.

Two things are owned separately here, and conflating them is what makes the boundary look like it waits on
its consumers. That the set is **closed** — that entry is by construction, that resolution is absolute, and
that a failure is a typed refusal — is a property of the boundary, settled where the boundary is built.
**Which** tools are in the set is a description of what the binary drives, and that is settled by the phases
that drive them; the enumeration narrows when the last driver stops driving a name, and the phase holding
that driver ships the membership pin as its own absence guard (§ I). The enum names the external tools the binary drives — provider tools such as
`incus`, cluster tools such as `kind` and `kubectl`, and the compilers and package managers the reconcilers
reach. It does **not** name an interpreter or a locking front end: ownership is the binary's own typed
operation over one platform row (§ EE, § LL), so no clause is held by a resolved `python3`, `flock`, or
`lockf`. A tool the enum names is one the project genuinely delegates to, not one it uses to reimplement
something it already owns. A consumer-specific resolver is admissible only when its
candidate table is fixed in an unexposed component, callers can select neither candidates nor results, every
admitted executable and helper directory is opened without following links and bound to its canonical
owner/mode/device/inode, the complete namespace is fingerprinted and revalidated around effects, and child
`PATH` contains only those admitted helper directories.

The direct-Colima adapter is the consumer-specific realization: its private Apple resolver admits only the
fixed Python/Colima/Docker/Lima candidates (and Brew only while Colima is missing) and returns an opaque
retained toolchain. A Cabal-private, non-nestable, thread-local fixture seam may substitute a fixture
root/home/bootstrap identity and fresh bounded resolver execution for host-static integration tests; every
discovery and revalidation still runs the strict decoder and opaque settlement path, the bracket clears the
override, and no public module exposes it or a trusted-result constructor. Production never turns ambient
`PATH`, `HOME`, cwd, Docker context, or caller output into authority. The in-VM tools a resolved provider
dispatches to remain the VM's own `$PATH` binaries reached through that single absolute host-provider command
(the VM is a separate machine — the doctrine governs host invocation).

This section governs *which* executable an invocation names. Two neighbouring axes are separate closed
boundaries, and resolving a path absolutely says nothing about either. The *shape* of the invocation —
stdio disposition, descriptor inheritance, session, environment, and working directory — is § HH's; a
child that outlives its launcher is where those two come apart most sharply. *How the command is
expressed* — as a value in one closed vocabulary rather than as interpreter text — is § KK's.

### L. Substrate and Ensure-Reconciler Contract

**Owning phase**: [the ensure-reconcilers phase](phase-8-ensure-reconcilers.md)
Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) is owned
by `hostbootstrap-core`.
**The purpose of the `ensure` suite is that an absent dependency with a supported install plan is
installed rather than treated as a manual prerequisite.** Context-free host dependencies are represented
by probe-first `ensure` reconcilers — a host-applicability predicate plus a reconcile action — exposed to
projects as library primitives
(`ensureDocker`, `ensureLima`, `ensureCuda`, `ensureCudaWin`, `ensureWsl2`,
`ensureHomebrew`, `ensureGhc`, `ensureIncus`, and the accelerator build-stack reconciler
`ensureAppleMetal`) and as `ensure-*` step kinds composed into the lift chain. There is no
top-level `ensure` command, and no reconciler is reachable as a verb. The command surface is exactly the
tree § P fixes; the one internal marker § P admits is not a command and cannot reach a reconciler.
The target reconcile action **installs** the
dependency when its total probe reports absence and a plan exists, then re-probes; a satisfied capability
is a verified, typed no-op. Current install-and-reprobe behavior is idempotent only to the strength of
each probe or package-manager no-op path; several probes and raw `IO ()` results do not yet prove
resource identity or retain a typed reconcile outcome. An absent-but-installable dependency is therefore
installed rather than reported as a manual prerequisite. The Python wrapper's host minimums (§ M) are the only intentionally non-installing
**pre-binary** prerequisite gate, not the system's only failure class. A reconciler fails closed on
wrong-host applicability, an irreducible/non-installable precondition, a conflict or safety refusal, or
failed post-install verification. NVIDIA device/driver visibility is part of
substrate detection: without a working `nvidia-smi`, a host is not classified as `linux-gpu` or
`windows-gpu`, so the GPU reconciler rejects that substrate rather than claiming it can install a driver
for hardware it cannot yet identify. Once a GPU substrate is established, its installable toolchain
dependencies are reconciled normally. `ensure incus` is explicitly applicable
on **both** apple-silicon and linux — on Apple it prepares the Colima-backed Incus provider for explicit
Incus workflows, and on Linux it initializes the native daemon that encapsulates a fresh linux host (§ U).
It is not the first or only cross-substrate predicate: current `Ensure.Docker` declares
`appliesTo = const True`, although its absent-daemon install plan is Linux-only and delegates/refuses
elsewhere.
Provider adapters that require validated project/config/plan authority are not config-free reconcilers
and cannot appear in `allReconcilers`. In particular, direct Apple Colima consumes a plan-bound project
profile plus the admitted wall/partition/reservation, installs the tool if absent, observes exact
runtime/CPU/memory/disk state, and never treats `default` as project authority.
The worked demo's default Apple Silicon VM path uses Lima, not an Incus VM. The
kube tools (`kubectl`/`helm`/`kind`) are baked into the L0 base image and the cluster lifecycle that
drives them is L0 (the cluster-lifecycle phase), so they need no separate host reconciler in the in-container path. The worked
accelerator demo's CUDA base also carries `nvkind`; the cluster-lifecycle phase owns that driver as an L0 lifecycle
primitive, and the project selects it only for the explicit Linux GPU direct-container topology. Future
project-specific GPU tools can still be contributed by a consumer or mid-layer (`daemon-substrate`)
through the extension-stream merge (§ T). The accelerator-daemon demo keeps
the same boundary: Apple Silicon and Windows GPU host daemons run host `ensure` for the Swift/Metal or
CUDA build stack, while Linux CPU/GPU daemon pods do **not** run in-container ensure and instead trust the
published hostbootstrap base image to contain `clang++` or `nvcc`. The `ensure` reconcilers are normally
invoked as **chain steps** within `project up` (§ Y), not as hand-run verbs. The target provider
reconciler reaches a **usable** provider, not merely an installed binary, and observes any egress the next
step requires before minting readiness. Current Linux `ensure incus` checks only client presence and no
provider reconciler verifies egress; the host-providers phase owns that gap with the canonical-quantities
phase's observation types.

### M. Python-Thin / Haskell-Core Boundary

**Owning phase**: [the Python-pre-binary-floor phase](phase-1-python-pre-binary-floor.md)
In the ordinary `doctor`/`build`/`run` project path, the Python bootstrapper does only the **minimum to
build the project binary**: discover the single Cabal file and executable stanza, assert the fail-fast
host minimums, ensure the host toolchain prerequisites needed to **build** the binary, then build the
project binary **host-native** and invoke it. Handoff uses POSIX process replacement with `exec` and a
child subprocess whose exit code Python returns on Windows.
Python does not initialize or trigger config creation. The binary owns its
Dhall — a normal command fails fast (exit 1) when no sibling `<project>.dhall` exists, and the config is
created by an explicit `project init` or generated by the test harness through the scope-aware
`psAssemble`. Python itself
does not read or write Dhall. Those fail-fast host minimums are the irreducible, intentionally
non-installing **pre-binary** floor (OS version, passwordless sudo, Xcode CLT + Homebrew as the Apple
toolchain root, and on Windows winget and Windows PowerShell as the toolchain root). After the binary
exists, each dependency with a supported `ensure` install plan is installed when absent and re-probed
(§ L); wrong-host use, non-installable prerequisites, conflicts, safety refusals, invalid authority, and
failed verification still fail closed. The bootstrapper does **not** ensure Docker and does **not** build
the project container — those are not pre-binary necessities; the project binary, once running, ensures
Docker, builds the project container, drives the VM provider (including WSL2 on Windows), drives the cluster, and does everything
else it reasonably can. There is **no copy-out**: a binary built inside a
Linux container cannot exec on a general host such as Apple silicon, which is why the binary is built
host-native and the Python layer must ensure the host build toolchain first. Reusable host-management
primitives and interpretation live in `hostbootstrap-core`; consumer-specific provider/build actions
live in the project binary (Haskell). New host logic defaults to one of those Haskell layers according
to ownership, and a Python addition must be justified by the pre-binary bootstrapping constraint. The
shape the Python layer runs — provision the host, build the pb host-native, then hand off by the
substrate's invocation mechanism — recurs at **every** frame the
binary later crosses (§ U): the Python bootstrapper is the **metal-frame instance** of the fractal
bootstrap, and each chain descent repeats provision → build the pb in the frame → hand off
`pb project up`.

The explicit pipx `update` surface and repository-maintainer `base`/check/test command set are separate
distribution operations. An operator may ask Python to update the installed application or build/publish
a base image, but those commands do not enter the project lifecycle and do not move Dhall, provider,
project-image, cluster, service, test-run, or teardown ownership out of Haskell.

The pre-binary bootstrap is an early phase dependency, not a later convenience: on a fresh host it is the
way the repository obtains the Haskell toolchain needed to validate `hostbootstrap-core`. Therefore the
toolchain bootstrap is tracked with the host-tools-and-substrate-detection phase, while later phases consume the
result. Later phases must not introduce a prerequisite that an earlier Haskell validation gate needs.

The Python layer also owns its own explicit pipx self-update path, because that command replaces the
pipx-installed bootstrapper before or outside any project binary. This is distribution lifecycle, not
host-management logic: it is not an `ensure` reconciler and it must not contain Docker, Dhall, VM,
cluster, resource, or cordon behavior. With no versioned Python release channel, the canonical update
primitive is a forced pipx reinstall from the direct VCS requirement for the default branch. Self-update
is operator-invoked only; `doctor`, `build`, `run`, and `base` must not auto-update, auto-check GitHub
freshness, or fail merely because the wrapper is not at the latest commit.

### N. Host-Native Binary Build

**Owning phase**: [the Python-pre-binary-floor phase](phase-1-python-pre-binary-floor.md)
Every project's binary is built **host-native** on every substrate — it is **not** built inside a Linux
container and copied out, because a binary built in a Linux container cannot exec on a general host (e.g.
Apple silicon). The universal pre-binary host dependency is therefore the **build toolchain**, not Docker.

- The Python bootstrapper ensures the host Haskell build toolchain and Cabal package index (Homebrew →
  `ghcup` → GHC/Cabal on Apple; the equivalent on Linux; a pinned, integrity-verified `ghcup.exe`
  retrieved through Windows PowerShell → GHC/Cabal on Windows) —
  the prerequisites to build the binary — then builds `./.build/<binary>`
  host-native and invokes it (POSIX `exec`; Windows child subprocess); it does not initialize or trigger
  config creation (the binary owns its Dhall, § M). A `./.build/<binary>` is always present on the host
  after the build.
- The project **container** is a separate artifact the **project binary** builds (via Docker, `FROM` the
  base image) once it is running — the workload image and the mandatory code-check quality gate. The
  Python layer neither ensures Docker nor builds the container (§ M).
- On Windows, CUDA is a **build-only host capability** — the **headless host build** (composition
  pattern #7): NVIDIA device/driver visibility establishes the `windows-gpu` substrate, then `ensure
  cudawin` readies the CUDA Toolkit, MSVC VCTools, and LLVM clang; nvcc artifacts are produced on the bare
  Windows host and staged into the cluster, and no workload runs in a build VM. On
  native Windows GHC `System.Info.os` is `mingw32`, so the core's POSIX-only `unix` dependency is
  conditionalized at its three call sites to build the binary host-native.
- Inside a managed Linux VM (§ U) the same host-native build applies — Lima on Apple Silicon,
  native Incus on Linux. The VM is a fresh linux host: the pipx-installed `hostbootstrap` ensures the
  toolchain, builds the binary host-native, and hands off by POSIX `exec`; the binary then ensures Docker and builds the
  container in the VM. The worked demo's pristine-host bootstrap counts **3 builds** — a metal
  orchestrator build plus, inside the pristine VM, the host-native binary build and the binary-driven
  project-container build — a demo-only illustration, not the standard workflow.

### O. Resource Budget and Cordoning

**Owning phase**: [the step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md)
The target has one opaque validated per-project budget (`cpu`, `memory`, `storage`) and no independently
editable copy. Admission rejects a declaration that the selected provider cannot represent exactly, so
the byte-valued `EffectiveBudget` equals the user-visible `ValidatedBudget`; no builder may silently
round a hard ceiling upward. The canonical indices are:

```text
ValidatedBudget scope planId budgetId
ProviderBudgetCapability scope planId provider capabilityId
ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId
EffectiveBudget scope planId budgetId provider capabilityId wallSpecId
PlannedWorkloadSet scope planId workloadSetId
VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId
BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId
ResourceSlice
  scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId
ProviderWallReservation
  scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence
ProviderWallSettlementPermit
  scope planId providerResourceId budgetId provider capabilityId wallSpecId workloadSetId partitionId
  reservationId fence operationKey callDigest attempt journalVersion
ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence
WslGlobalWallLease scope planId wallSpecId wallEpoch fence
```

Provider selection first yields only a pure `ProviderBudgetCapability`; it grants no ownership or
mutation authority. Exact admission consumes that capability with the validated declaration and jointly
mints a `ProviderWallSpec ... wallSpecId` plus an equal, exactly representable
`EffectiveBudget ... wallSpecId`. `fitsBudget` consumes the same-index workload set and yields only the
matching fit proof. Partition construction consumes those pure values and mints exact plan/frame resource
slices before any provider-wall acquisition or reconciliation effect.

Only after the proved `BudgetPartition` exists may a journaled wall-acquisition operation reserve the same
`wallSpecId`. The only public reservation producer jointly consumes the exact `ProjectPlan`, its matching
provider `PlannedResource`, wall, partition, and durable `PreparedGate`; it checks the gate's plan digest and
operation key and derives the non-empty session plus positive fence, attempt, and journal version from that
gate. Its exact prepared adapter consumes the wall spec, partition projection, and
`ProviderWallReservation`; it may create/apply or observe the initial provider wall. A package-private owning
adapter can then mint `ProviderWallSettlementPermit` only by joining that exact prepared call and its nominal
`PreparedOperation`/`PreparedPreconditions` pair with a successful result from the closed backend. Public
settlement consumes that permit, not a caller-supplied observation, and returns a live
`ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence` only after the authorized
applied/unchanged observation. The token that authorizes the initial call is the journaled reservation, not
the post-effect authority it will mint; possessing a prepared operation without its backend result cannot
manufacture the later authority early.

Raw provider and cluster observations are deliberately plan-independent backend facts. A public provider
caller cannot submit one to settlement: only the package-private owning-backend bridge may enclose a
successful observation in the matching settlement permit. Cluster settlement likewise accepts only its
closed backend result. A same-shaped raw observation from another probe is never plan evidence by itself.

For WSL, the exact owning adapter consumes the journal-derived
`ProviderWallReservation ... reservationId fence` and retains its platform-exclusive pre-call lock/CAS across
the shared-wall call. Only the adapter's backend-produced settlement permit can jointly return the
epoch-indexed `WslGlobalWallLease` inseparably with the live `ProviderWallAuthority`; the generic reservation
is journal lineage, not an OS-lock handle, and the post-observation lease is never a precondition for its own
minting. An unknown reservation/acquire/apply outcome yields only same-spec recovery state until exact
reprobe settles it. Every later reconcile or dependent
budget-relevant mutation requires both a projection carrying the same `wallSpecId` and that live
authority and revalidates its `wallEpoch`/`fence`. Thus the effective value or pure wall spec alone is
never write authority. The partition proves that every positive
slice plus provider overhead is at most that same wall and that each provider/node minimum is met. A
zero, oversized, or floor-rounded “strictly smaller” cluster slice is unrepresentable. The budget is
never added to itself. Separately, the metal preflight requires
`host RAM ≥ budget + 4 GiB host reserve`.

The canonical-quantities phase provides the pure admission foundation, while provider adapters and
complete workload projection remain owned by their dependent sprints:

- demo `ProjectConfig.resources` is the sole editable budget. `BinaryContext` contains placement and
  command-gating data but no resource-envelope copy; child projection preserves the already-refined
  `Resources`;
- `Quantity`, `Resources`, `HaReplicas`, `Port`, and `TimeoutSeconds` hide their constructors and expose
  total smart constructors. They have no `Num`/`IsString` bypass, and CLI assembly returns a data error
  before lifecycle effects when refinement fails;
- `parseQuantity` uses exact integer decimal arithmetic. Lima/Colima/Incus/WSL builders and
  `ProviderWallSpec` admission reject a quantity that is not exactly representable in whole GiB rather
  than rounding a hard ceiling upward;
- `ValidatedBudget`, the closed typed `ProviderKey` relation, jointly indexed `ProviderWallSpec` /
  `EffectiveBudget`, non-empty `PlannedWorkloadSet`, `VerifiedWorkloadFit`, constructive
  `BudgetPartition`/`ResourceSlice`, journal-before-call `ProviderWallReservation`, backend-produced
  `ProviderWallSettlementPermit`, and `ProviderWallAuthority` are opaque. Successful WSL settlement returns
  its `WslGlobalWallLease` inseparably with the live authority;
- the current demo interpreter receives a descriptive cluster slice rather than a `BudgetPartition` proof.
  The complete plan-derived workload/slice projection is the worked-demo phase's work;
- `verifyBudget` is wired as the cluster-capacity preflight. `fitsBudget` is only a helper/test/static
  API calculation; lifecycle does not derive or check the exact non-empty concurrent workload set;
- new Lima/Incus/WSL resources receive initial sizing, but existing VM/VHDX sizing is not uniformly
  compared or reconciled. The direct-Colima consumer is one exact `ProjectPlan`, matching provider
  resource/topology, matching budget/capability/wall/workload-fit/partition, and `PreparedGate`-derived
  reservation plus provider-start package. It rejects total storage at or below the fixed 20-GiB root disk;
  the canonical wall is `--root-disk 20 --disk (total-20)`, with both quantities observed and bound. One
  128-bit plan/lifecycle namespace key owns the isolated `COLIMA_HOME`, reusable global lock, isolated
  `DOCKER_CONFIG`, and a socket-safe local profile. The private fixed resolver and bounded process-group
  runner feed a descriptor-held Python `fcntl.flock` transaction whose durable
  `reserved`/`home-staged`/`home-ready`/`context-staged`/`prepared`/`managed` states bind the exact invocation,
  namespaces, root/data wall, machine/context identity, and complete artifact manifest. A profile present
  from `prepared` without a managed stage is outcome-unknown `Conflict`, never adoption. Only the hidden
  successful backend bridge may jointly settle the provider start and wall. Live Docker reuses the isolated
  context under the retained identity, and independently journaled `--force --data` cleanup enters
  `releasing` before mutation and conditionally releases the exact context, artifacts, namespaces, and origin.
  Missing clauses are `Unsupported`; mismatches are `Conflict`. Production recursive and demo call-site
  adoption remain open outside the completed Phase 16 boundary. Direct Linux GPU
  outer build/container effects are uncapped; only the later nvkind nodes receive CPU/memory caps. Bare Linux
  has no storage quota or image-GC wall;
- WSL2 has no per-distro CPU/memory cap. Its global `%UserProfile%\.wslconfig` affects every distro. The
  production route now holds the four § EE clauses behind one host-wide lock: it writes a durable origin
  record before mutation that distinguishes exact present bytes from absence, binds the managed target
  to its object identity and wall ownership, and re-observes under the same lock before conditional
  restore so a foreign replacement is preserved as a conflict. An existing running distro/VHDX still
  need not adopt a changed declaration;
- the normal WSL2 `project down` route now releases the wall: teardown restores `.wslconfig` first and
  then runs `wsl --shutdown`, while the managed body derives finite six-hour VM and distribution idle
  timeouts from one constant rather than pinning them to `-1`. The
  [Windows-and-WSL2-substrate phase](phase-27-windows-and-wsl2-substrate.md)'s native-Windows gate on
  2026-08-01 observed the durable record removed, the exact absent origin restored, the distro stopped,
  and the WSL utility VM/memory balloon gone after `project down`. Lima and Incus continue to release
  their walls on stop.

The target defense has three closed rings: promotion mints the sole provider-exact `ValidatedBudget`;
plan preparation runs `verifyBudget` plus `fitsBudget` over the exact non-empty workload/effect set and
constructs the proved `BudgetPartition` before its first dependent mutation; and runtime reconciliation
first journal-acquires/revalidates the same `wallSpecId` and then either applies the matching
`EffectiveBudget` everywhere or returns typed `Unsupported`/`Conflict`. Existing
walls return typed unchanged/migrated/refused results. Lima and Incus own per-VM walls. WSL2 instead owns
one provider-effective shared utility-VM wall behind an exclusive, crash-recoverable global-state
lease/CAS; each distro may own its VHDX slice, but incompatible concurrent wall declarations refuse
rather than overwrite `%UserProfile%\.wslconfig`. The WSL wall mutation permit consumes/revalidates the
same `wallSpecId`/`wallEpoch`/`fence` as the `ProviderWallAuthority` and `WslGlobalWallLease`; a
same-shaped value from another plan or owner cannot apply or restore it.
The [canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md)
owns exposed `HostBootstrap.Cluster.Cordon.Foundation`: opaque canonical-unit `ResourceBudget`, capacity
reads, parsing/refusal, verification, exact-budget sizing renderers, and storage policy. That phase also
owns the separate readiness and reconcile foundations. The
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
owns the `HostBootstrap.Cluster.Cordon` facade that reexports the foundation and adapts
`Config.Vocab.Resources`/`ResourceEnvelope`, including the descriptive pure `fitsBudget` helper. The
[step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) owns generic exact Budget
admission plus the workload/fit/partition/slice proof families from one `ProjectPlan`, its matching
provider/cluster `PlannedResource`s, and its `DerivedTopology`. The
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns the
exact cluster and direct-Colima consumer boundaries, including consumption of the lower typed bare-Linux
unsupported-storage decision. Those source boundaries are implemented; Production recursive and concrete
demo adoption remain downstream. The
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)
supplies the portable host-wall ownership protocol, while the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) supplies the
provider realizations. The [worked-demo phase](phase-24-worked-demo.md) owns the concrete demo workload,
overhead, partition, and slice projection, and the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
owns the scope-indexed configuration input. The
[step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) owns the single finalized
plan authority. A Dhall-native
`Budget/fitsWithin` assertion is not attached to generated config because that config contains text
quantities and no resolved pod set.

Project budget interpretation remains Haskell-owned; Python does not size project VMs or clusters. On
Linux, the maintainer-only `hostbootstrap base build` separately measures host CPU/RAM and caps the
warm-store build container. On macOS and Windows the current command supplies no explicit Docker
CPU/memory caps and retains the Dockerfile's `-j1`; it must not be described as host-sized there. That
build-phase limit is not an interpreter of `<project>.dhall`; see
[base_image.md](../documents/engineering/base_image.md#host-sized-warm-store-build-budget).

### P. Fixed Command Surface And The Extension Streams

**Owning phase**: [the Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md)
`hostbootstrap-core` exposes a **fixed** command surface plus a project entrypoint
(`runHostBootstrapCLI progName projectSpec`). Every project binary — and the bare `hostbootstrap` binary —
surfaces the **same** tree: the three DSL-driven commands `project init|up|down|destroy`,
`test init|run`, and `service init|schema|run` (§ Y, § Z, § AA), plus the read-only `context`
introspection command and `check-code`. There are **no per-project verbs**: `hostbootstrap-core` is a
**library of composable tools** (step kinds, reconcilers, the self-reference lift, service handlers), not a
CLI topology, so a project never adds a command.

**One internal marker is not a command.** A binary that crosses into a frame must be able to recognize
that *it is* the process on the far side, and no verb can express that: a verb is something an operator
types, and this is something only the lift fold produces. The marker is therefore classified out of argv
before the parser runs, and it is bounded by what it cannot carry — no coordinates, no path, no authority,
no caller-selected action, and no route to a `ProjectSpec` extension stream. It is absent from `--help`,
it names nothing an operator could usefully type, and it refuses unless its standard input and output
decode as the protocol channel. It carries a transaction the caller already holds and returns that
transaction's outcome; it opens no second surface. Exactly one such marker exists, and a second would be
a per-project verb wearing a different hat.

A project extends the core only through the
**extension streams** finalized into opaque `ProjectSpec`: additive step fragments resolved to one
validated **lift plan** (`StepPlan`, § Y),
the **Dhall vocabulary**, the **schema-gen** `ConfigArtifact` registry, the **test seams** (a non-empty
test suite), and the **service runtime seam**: a possibly empty typed `ServiceRegistry`. Each definition
inseparably binds identity, structural field projection, reflected role codec, and handler; there is no
independent string selector. Registry finalization jointly binds the full `ProjectCodec`, role-wire
`RoleCodec`s, and canonical `specDigest`. A parent/local admission projects only a role-specific
descriptive wire; verification mints the opaque
`ValidatedServiceRequest specDigest configId secretDigest fields service`. The sole selection gate consumes that request, exact
leaf placement, inseparable revision/instance activation/projection package, and the finalized typed registry to
produce an existential
`SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
fields`. The package contains a matching
`ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
service effects` proof and handler
program for the same `service` and authorized `effects`; the handler receives only the bundle's
`RoleParams specDigest configId secretDigest fields service`, never the full config. The Dhall
`ServiceType` ADT lives in the project's `cfg`; it is not the handler registry. These
streams sit alongside the project `check-code` action. Static finalization validates those extension
points before parser construction: duplicate cases/artifacts/inputs/service identities and conflicting
single assignments are rejected; the test suite and step contribution must be non-empty; each resolved
plan has unique typed identities, exact contiguous frame order, and explicit reverse policy;
the declared project name must equal the invoked executable identity, and `check-code` is supplied by
construction rather than silently defaulted. `ProjectSpec` carries **no**
`ProjectCommand` deltas — the surface is closed. The bare `hostbootstrap` binary
(`hostbootstrap-core`'s own executable) uses the separate `runBareHostBootstrapCLI` entrypoint; it is
built like any project binary, not baked into the base image.

### Q. Configuration via Dhall

**Owning phase**: [the Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
Configuration is typed Dhall in distinct roles:

- the **local runtime config** `<project>.dhall`, generated by the built project binary, read from next to
  the executable before normal command dispatch, and edited by the user for host-level settings;
- the **generated child config** `<project>.dhall`, materialized by a parent binary at VM, container,
  daemon, and service boundaries. Current descriptive context/capability declarations are narrowed, but
  the demo payload remains the full `ProjectConfig` and inherits the full resource envelope; the target
  uses role-specific parameter types, exact plan/frame resource slices, and separately verified opaque
  authority;
- the **rich project/deploy** Dhall and one project-defined typed `<project>.test.dhall`. The latter maps validated
  `CaseId`/`VariantId` selections and overrides to generated run `cfg` variants through the
  project-owned projection (the Dhall-configuration-and-project-model phase); it is not one file per case. Selected top-level scalar/resource
  fields are checked at decode; complete applied-budget validation and the pod-set bring-up check are
  the canonical-quantities-and-reconcile-results phase targets, not current claims. No generated `fitsWithin` assertion is claimed. Both are
  generated by the project binary from a reusable Dhall vocabulary. The ungated
  `context render` surface renders static registry examples; runtime deploy and child projections are
  emitted by commands that have already validated the active local config.

The current project binary exposes two distinct schema surfaces and one default writer.
`context schema` prints the in-scope static `ConfigArtifact` registry; `service schema` currently prints
the validated-codec full project-local `cfg` shape; and `project init` writes a default full project
config. The opaque lower-layer witness admits that schema only after the normalized `ToDhall`
`declared` and `FromDhall` `expected` expressions are judgmentally equal; semantic round trips remain a
separate test obligation.

The command tree remains fixed while trust domains stay separate. Static authoring uses
`ProjectSpec cfg tcfg`, with no lifecycle scope or specification phantom. Scope finalization computes one
canonical `specDigest` and currently yields `FinalizedProjectSpec scope specDigest cfg`, retaining the
matching `ProjectCodec`, finalized service registry, and identity-parametric plan builder. Service field
identity remains on the finalized service/runtime vocabulary rather than becoming a fourth
`FinalizedProjectSpec` parameter. `ProjectCodec scope specDigest cfg` validates the full root/Harness
config. Because the scope-indexed secret vocabularies differ, the full schema is an
explicitly named `Production`/`Harness` `ConfigArtifact` family in the
`context schema`/`context render` registry, never one scope-erased union. A jointly finalized project-owned
`RoleCodec scope specDigest fields` derives the closed `RuntimeRoleWire fields service` family from the hidden
consumer-indexed field schema and typed service registry. `service schema` prints that role-wire schema
registry/union as explicitly named `Production` and `Harness` scope families, because their secret
vocabularies can differ; it never conflates them as one schema. Harness role schemas contain typed
secret handles, not inline `TestPlaintext`; private run-scoped bundle bytes are a separate digest-bound
channel. `service init` writes one selected
Production role wire, while the harness assembler/projection writes Harness role wires internally. No
schema output contains secret values or promotes Harness to Production. An explicitly empty service
registry has an explicit empty result for both families and no runnable role.

The lower schema layer mints an opaque `CodecWitness a` only after normalized encoder/decoder expressions
compare equal. The project boundary wraps those proofs with installed identity and scope; full-config
decoding/plan construction consumes `ProjectCodec`, while runtime-role rendering and verification
consume the inseparable `RoleCodec` derived from the same finalized field schema. Every
committed hand-written `Core.dhall` type must either be generated from the codec or have an explicit
judgmental-equality test. Round-trip/property tests remain required for semantic encoding behavior.
Python derives the project name from the Cabal file and has no Dhall-facing configuration role: it
builds the host-native binary and invokes it using the platform-specific handoff above; the binary owns
config creation (§ M). Python never reads or writes Dhall itself.

`specDigest` remains on `ValidatedConfig`, `ProjectPlan`, plan drafts/bindings/frames, service
requests/parameters/selection/programs, and build authority. An activation manifest additionally binds
the measured `binaryDigest`, exact `configDigest`, and separate `secretDigest`. This document sometimes
uses shorter type names in explanatory prose; those are readability abbreviations only, never permission
to erase these indices. Same-shaped values from different finalizations, binaries, config bytes, or
secret bundles cannot cross-pair.

Full and role wires share one jointly derived, opaque
`FrameworkEnvelopeCodec scope specDigest fields`, a closed wire-kind discriminator, and a closed
descriptive Production/Harness scope-kind discriminator. It validates only the framework identity/context/topology fields needed before routing
and yields `LocalContextView scope specDigest wireKind frame`; it cannot expose service parameters or mint command
authority. Config-free `context inspect`/`context show` start from the installed project's scope-erased
`FinalizedSchemaFamily`, select the one named Production/Harness envelope codec identified by that tag,
require it to validate the same tag, and return a display-only scope witness. Missing/unknown,
disagreeing, or structurally ambiguous scope evidence yields an explicit display error rather than a
guessed witness. Authority-bearing dispatch gets scope only from its independently verified
root/handoff/activation package and then requires the descriptive tag to agree. The view applies to
either a full project wire or a
cluster-service/daemon role wire. Existing-frame routing performs the same first-stage discrimination:
project lifecycle and ordinary `check-code` require `FullProjectWire` before invoking `ProjectCodec`,
while `service run` requires `RuntimeRoleWire` before invoking `RoleCodec`. Thus a valid role wire receives
a structured wrong-command/authority refusal instead of being mislabeled malformed full config, and no
route can choose the wrong second-stage decoder.

### R. Quality Gate Contract

**Owning phase**: [the base-image-and-warm-store phase](phase-23-base-image-and-warm-store.md)
Static quality is a first-class requirement. The Haskell formatter is `ormolu`/`fourmolu` and
`hlint` runs against supported source roots, both installed in the base image from current compatible
upstream releases selected by the rolling build. Every image build, base
or derived, gates on the project's canonical `check-code` — for a derived image, a single in-Dockerfile
`RUN <project> check-code` stage whose body is project-defined. The standardized test harness's
`<project> test` report card is the project-level validation gate. The mechanical documentation
validator (`HostBootstrap.DocValidator`) runs through the code-check. The plan
distinguishes mechanically enforced gates from editor-only guidance, and § II from § JJ: the container
`check-code` owns the formatter and linter, while the host static gate owns the behavioural and
source-shape suites on every supported outer host.

### S. Imported Practices and Explicit Non-Adoption

**Owning phase**: [the governance-and-documentation-standards phase](phase-0-governance-and-documentation-standards.md)
`hostbootstrap` borrows the governance shape (metadata blocks, phase plan structure, completion
tracking, declarative current-state language) from the consumer projects. It does not adopt any
consumer's product features, runtime surfaces, daemon-role model, or hardware-correctness
validation cadence; those remain consumer concerns. Non-adopted external doctrine must not be
treated as a current blocker or completion criterion. The standardized test harness and the four named
execution shapes are `hostbootstrap`-owned doctrine, but the shapes are expressed by the consumed
lifecycle plan rather than a parallel selector or Dhall literal (§ T).

### T. Library Hierarchy, Extension Streams, and Execution Shapes

**Owning phase**: [the Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md)
`hostbootstrap-core` is a **library of composable tools**, not a CLI topology; the command surface is
fixed (§ P) and is **not** an extension point. The reusable surface is a three-level Cabal library
hierarchy: `hostbootstrap-core` (L0) ◄ `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2); `mcts` consumes
L0 directly. Each level adds only its delta to the **parallel extension streams**, one additive merge idiom
each: additive **step fragments** retained by the identity-parametric static
`ProjectSpec cfg tcfg`; the **Dhall vocabulary** (`let C = ./Core.dhall`, embedded, never redefined); the **schema-gen**
`ConfigArtifact` registry (concatenated across levels through `ProjectSpec`); the **test-harness** `Seams`
(threaded through a non-empty `TestSuite`); and the **service runtime seam** (an additive, possibly empty
typed registry jointly finalized with the config/role codecs; the service-runtime phase adds the
config/frame-indexed `SelectedService` execution package, § AA). A project integrates through a Cabal dependency
(`source-repository-package` with a full immutable commit `tag` for a remote consumer, or a local
package in this repository) plus the `runHostBootstrapCLI` extension. A moving branch or omitted remote
tag is not a governed input. Scope finalization currently yields
`FinalizedProjectSpec scope specDigest cfg`; its concrete root and `ValidatedConfig` project a non-empty
draft sequence, and `withProjectPlan` admits one opaque
`ProjectPlan scope specDigest planId configId cfg`. The plan's forward order, topology, stable snapshot,
and frame-indexed current-subtree reverse work are implemented pure projections, and its stable/local
digest join is implemented as pure `PlanDigestBinding` verification. The exact reverse projection consumes
the plan and its `CurrentFrame` and is the only input to `openTeardownForest`; it does not run the reverse
callbacks it retains. Reconciliation's exact, total descriptor producer consumes one admitted
`ProjectPlan` and its matching `PlannedStep`, and obtains plan/configuration/node/frame/operation data only
through the public plan projections. Production `Command` retains or reconstructs one exact plan and uses
public Chain for forward execution and the exact plan/current-frame projection for reverse work. Harness
likewise retains one exact Harness-scoped plan through generated-config ownership and supplies its common
current-frame forward and reverse interpreters to the engine. No Production or Harness plan-only
command-authority, descriptor, forward-interpreter, or teardown-projection compatibility API exists.
`StepPlan` is an authoring/validation kernel and migration source, not a second lifecycle authority. A freeze file constrains dependency solving; it is not an integration
API. Published base images expose no freeze-driven `LABEL`/`ENTRYPOINT` integration mode. Four names classify execution **shapes** — `OneShot` (one-shot
`docker run`), `HostNative` (host-native build + host invocation), `HostDaemon`/service (a long-running role,
reached via `service run` as a leaf-frame service or daemon entrypoint, either controller-managed in a pod
or lifecycle-managed on the host, § AA), and `Cluster` (kind+Helm). These are consequences of the typed
steps in the one project lifecycle plan (and, for a service leaf, its local service-role config), not a
second selector representation and not a `Core.dhall` field. Source and vocabulary guards require that
single representation.

### U. Host-Provider Axis And The Self-Reference Lift

**Owning phase**: [the ensure-reconcilers phase](phase-8-ensure-reconcilers.md)
A project binary crosses an execution-context boundary by invoking its **own** subcommand in the nested
context — the self-reference lift. Its dependency layers are constructive and one-way:

- the [Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
  owns public pure `HostBootstrap.Lift.Context`: `IncusVM`, `LimaVM`, and `Wsl2VM` target records;
  `ConfigDelivery`, `ContainerLift`, `LiftLayer`, and outermost-first `LiftContext`; their constructors;
  same-root `canonicalHostMount`; and the exact pure `execVMArgs`, `shellVMArgs`, and `wslExecArgs` inner
  transport renderers;
- the [ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns generic `HostBootstrap.Lift`, which
  reexports that context vocabulary, resolves only the outer host tool, folds raw/self commands through the
  stack, streams config over `stdin`, and performs the provider-neutral effect dispatch. It imports no
  Incus/Lima/WSL2 realization, `Substrate.Provider`, Registry, or cluster module. `Ensure.Wsl2` owns its own
  prerequisite diagnostics and imports no later WSL2 provider module; any compatibility reexport from
  `HostBootstrap.Wsl2` delegates to those lower definitions;
- the [host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) owns the Incus,
  Lima, WSL2, and direct-host lifecycle realizations. Each provider module consumes and reexports its lower
  target record/inner renderer and adds only lifecycle-specific probes and builders;
- the [composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md) additively owns
  `reachLeaf`, the four blob leaf smart constructors, and Registry's `liftSubcommandWithAuth`. Registry imports
  lower Lift and its generic quoting helper; Lift never imports Registry.

Contexts compose as provider-backed frames, outermost-first; the empty stack is the local host. The VM layer
is provider-specific: Apple Silicon uses Lima (`limactl shell <instance> -- ...`) for the demo VM, native
Linux uses Incus (`incus exec <vm> -- ...`), and Windows uses WSL2 (`wsl -d <distro> -- ...`) provisioning a
fresh Ubuntu-24.04 distro. A **derived project container** is the `docker run --rm` layer whose project
Dockerfile installs the binary as its `ENTRYPOINT`; the base image itself exposes no freeze-driven
`ENTRYPOINT` integration mode (§ T).
The stack nests — host → VM → container folds to the selected VM provider command followed by
`docker run --rm <image> <subcmd>`. Before a nested call crosses a boundary, current code obtains a
context-adjusted child config through a separate projection seam and **streams it in-place over the
lift's `stdin` channel** (§ X) — the callee writes it to its own sibling path before dispatch — so the
callee can explicitly reason about its place even though it runs the same command tree. That payload
still has the demo's full project record and parent resource envelope. Current delivery uses `stdin`,
with no parent-side intermediate config file or bind-mount (the Kubernetes service pod's ConfigMap
override is the exception, § AA), but the child sibling is persisted and inspectable in the child frame.
The target plan owns both projection and delivery and carries only a role-specific payload. Each
nested call runs the same command tree, so a step runs "locally." Current reconcilers are
context-agnostic `HostConfig -> IO ()` callbacks; the target retains independence from raw
`BinaryContext` but replaces that result-free signature with a plan-minted scoped transition descriptor,
resource/dependency inputs sealed into an exact `OperationPreconditionSet`, a prepare-time fresh
`PreparedOperation`/`PreparedPreconditions` pair, and structured `ReconcileResult` (§ CC/§ EE). A
retained readiness capability is never a backend-adapter input. The argv fold
is pure (unit-tested) and honors § K: only the outermost host dispatch names a
tool the resolver maps to an absolute path; every nested tool is the target's own bare `$PATH` name.
`SubstrateProvider` plus the n-level `LiftContext` frame stack and generic Lift fold is the one
provider/dispatch abstraction.
No public `HostTarget = Local | InVM` or `runInTarget` path exists; source/API guards prevent a parallel
dispatch representation. L0 supplies the reusable
context, fold, and provider primitives; the *specific* chain (the worked demo's host → VM → container) is
project logic. The **target** chain is interpreted recursively: each `project up` runs its current-frame
segment and authenticates `pb project up` in the next frame. Current Production executes only the exact
current-frame Chain and refuses at a nested process boundary. The authenticated-handoff phase supplies the
child-plan authority substrate. The recursive-lifecycle-command phase supplies the root-owned durable
coordinator, exact per-frame catalog and journals, authenticated rooted grant/observation protocol, and
storeless frame executor while retaining ownership of Production process descent (§ Y). A nested process
reconstructs and interprets only its exact projected frame; it receives no protected store, lifecycle cursor,
or durable-record operation. Current recovery after a
partial failure is best-effort; only the target durable journal, ownership receipts, and revision-bound
recovery make convergence restartable. Each frame transition repeats the same three beats — provision
the frame, build/install the pb in it, hand off `pb project up` — of which the Python bootstrapper (§ M)
is the metal-frame instance. See
[composition_methodology](../documents/architecture/composition_methodology.md).

### V. Opportunistic Warm Store

**Owning phase**: [the base-image-and-warm-store phase](phase-23-base-image-and-warm-store.md)
The base image pre-builds a broad Cabal dependency set as a best-effort performance cache. The store is
not a public version, freeze, or offline-build contract: consumers use their ordinary host-compatible
`cabal.project` unchanged inside a derived container, do not import `/opt/basecontainer/...` project or
freeze fragments, and may download or compile dependencies when no matching store artifact exists.
Warm-store manifests may group dependencies for maintainability, but those groups do not define
consumer layers or solver inputs. Cache reuse is opportunistic and must never be an acceptance
requirement.

### W. Single Representation And The Harness That Drives The Chain

**Owning phase**: [the step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md)
An operation has exactly **one** representation. Sprints 12.7–12.26 provide an opaque
`ProjectPlan scope specDigest planId configId cfg` constructed inside a rank-2 continuation from a
lifecycle profile, `ValidatedConfig scope specDigest configId (cfg scope)`, and a non-empty validated
`PlanDraft scope specDigest (cfg scope)` sequence, plus its pure forward, topology, stable-snapshot, and
current-frame projections, pure `PlanDigestBinding` verification, ordered snapshot persistence/binding,
existing-Production admission, recovered profile, safe config-specification refinement, and fixed-identity
reconstruction, followed by exact broker-indexed plan-bound journal admission, Sprint 12.22's canonical
same-broker cursor record, Sprint 12.23's frame-local admission/recovery/transition boundary, the
plan-owned resource and dependency-edge projections, the exact current-frame command-reservation
foundation, and the plan-owned frame-indexed reverse projection. The reverse projection retains
the forward plan's exact stable `StepIdentity` and `OperationKey`, selects core actions by that identity,
omits `PreserveOnReverse`, and orders the current frame plus its descendants deepest-frame-first and in
reverse forward order within each frame. `openTeardownForest` consumes that projection alone. Here
`cfg :: Type -> Type` is a scope-indexed config family;
`configId` binds the exact decoded/authenticated bytes and generative `planId` prevents two Production
plans from sharing journals, handles, or receipts. The topology root alone opens the plan-bound acquisition
journal, retains the protected store and bound root snapshot, and derives the durable cursor rows for every
cataloged frame. `ValidatedLifecycleContext` is root-coordinator-resident evidence: it may describe the root
or a nested frame while lending its retained `ProtectedStore` only to root-process joins. It is never a
child-process input or wire value. A `RootedPlanCatalog` recursively
projects the exact child configs and plans before child effects and binds every requester path to the root
run, root snapshot, target plan/config digests, topology prefix, ordered node set, dependency set, and
operation set. Production dispatch retains that one exact root `ProjectPlan` through dry rendering, ordered
snapshot persistence and binding, root lifecycle admission, and the fixed recursive interpreter;
current-frame reverse projection remains part of the same representation. A storeless frame executor may
reconstruct the cataloged target plan, but it cannot open or relabel the root acquisition journal, mint a
child-plan cursor from it, or choose a durable operation set.
Existing bound invocations reconstruct only the plan identity named by their verified
snapshot; fresh admission is reserved for an absent Production mode or the exact unbound retry state.
`HostBootstrap.Step`, the public plan facade, and the hidden plan kernel depend only on the pure
`HostBootstrap.Lift.Context`; the current-frame Chain may depend on the lower full generic Lift. No
topology projection or command argument mints child admission.
The [step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) owns this exact-plan
and Production current-frame foundation. Authenticated recursive child entry and traversal belong to the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md). The
[test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns the Harness command
consumer and assertion engine.
The Production `LifecyclePlan` forward/reverse bridges and the public plan-only command-authority APIs are
absent. Independently supplied plan, frame-context, and teardown interpretations violate this doctrine;
the recursive-lifecycle-command phase owns proof-complete recursive authorization and forward/reverse
traversal rather than another plan representation.
There is no second hand-written orchestration path
beside the chain — and the test harness is not one. `HostBootstrap.Harness` retains the exact
Harness-scoped `ProjectPlan` through the generated-config bracket and invokes the common current-frame
forward/reverse interpreter directly. `TestSuite` owns only the safety probe, assertion-environment
opener, case matrix, per-case assertion, and post-reverse absence assertion; it neither self-invokes
top-level lifecycle verbs nor builds a second cluster-bring-up path. The lifecycle constructor lives in a
Cabal-private internal component, so downstream projects cannot forge or replace the retained
interpreters. The authenticated self-invocation protocol in § EE is reserved for recursive child-frame
transitions, not this top-level Harness lifecycle. Re-expressing
deploy bring-up as a parallel chain of lifted ops alongside the chain — including inside a test seam —
would be a redundant representation. Cross-references: § Y (the chain and its recursive interpreter), § Z
(the chain-driven test surface and its safety preconditions), and § U (the self-reference lift the chain
and the in-frame assertions are built from).

### X. Binary Context Configuration And Command Gating

**Owning phase**: [the Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
`sourceRoot` is descriptive configuration, never host-path authority. Root-config admission resolves it
exactly once against the stable project-home anchor owned by the selected root config (never the
caller's current working directory), verifies that it denotes the intended project tree, and
canonicalizes it before any plan is opened. That effectful bracket yields an opaque
`CanonicalProjectRoot scope rootId`; callers cannot construct one from `Text`/`FilePath`,
`getCurrentDirectory`, the executable's sibling `.build` directory, or a later re-read of config.
`withProjectPlan` consumes that authority and derives every project-relative resource, including the
Production `.data` or Harness `.test_data/<runId>` root, under the same `rootId`.

One durable resource therefore has one identity and may have several **typed projections**, not one
portable pathname string. Direct-host Docker mounts consume only a verified canonical host path derived
from `CanonicalProjectRoot`. Provider-backed lanes may additionally reconcile a provider-local guest
alias, but that alias is a `GuestPath provider frame` projection and never replaces, authenticates, or
reconstructs the host root. Container, kind-node, pod, and guest paths remain distinct types until the
adapter that owns the boundary renders them. A pure frame planner consumes these projections from the
plan; it does not perform IO, reinterpret `"."`, concatenate an untrusted source root, or choose a
host/guest path by convention.

Every project binary must know where it is in the global composition chain through a sibling runtime
config file:

```text
<project>.dhall
```

Python currently discovers the Cabal-file stem and sole executable stanza separately, builds the
host-native executable, and invokes it using the platform-specific handoff in § M; it does not initialize
or trigger config creation (the binary owns its Dhall, § M). The
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
supplies one executable-bound `InstalledProjectIdentity`, and the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
carries that identity through configuration and plan construction. The built
binary owns `project init` / schema / help surfaces for creating the first host-level sibling config.
After that, each nested project binary receives or creates its own local config before it runs:

- a VM bootstrap **streams the VM-local context in-place**: the parent renders the narrowed VM projection
  and pipes it over the lift's `stdin` channel into the VM, where the descending binary writes its own
  sibling `<project>.dhall` before it runs;
- the project Dockerfile installs the binary, then runs
  `project init --role image-build-container --output /usr/local/bin/<project>.dhall` before any normal
  command; in the target that baked config is descriptive and build-time `check-code` additionally
  consumes ephemeral
  `BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`
  from the build
  coordinator. The authority binds inputs known before the image exists; the resulting image digest is
  recorded afterward;
- runtime container launches receive the parent-rendered runtime projection the **same in-place way** —
  streamed over `stdin` into the single `docker run` and written to the sibling path before dispatch — for
  the exact VM/container frame the container is launched into, with **no host-side intermediate config
  file and no config bind-mount**;
- a Kubernetes workload receives its context from the controller that owns identity and durable placement;
  for durable services, that controller is a `StatefulSet`; expected restarts authenticate through
  platform workload/binary identity plus a broker-signed manifest, verified into one inseparable
  `VerifiedRuntimeRoleActivation`, not a
  permanently live `project up` broker or the ConfigMap alone.

The current context shape is project-extensible and carries project/binary identity, **explicit
context** (primary context kind), local capabilities, allowed command classes, parent chain, topology
frames, current frame, runtime witnesses, resource envelope, and child-context creation rules. A
`<project>.dhall` may declare additional roles, but `addRole` cannot widen a leaf primary into an
orchestration placement. `service run` additionally requires a primary `ClusterService`/`Daemon` leaf,
while `project up|down|destroy` consult the closed `placementAllowsCommand` relation derived from the
validated topology rather than trusting the declared command-class list. The
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
owns that descriptive placement relation. The
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
supplies the independent lower root and reservation vocabulary. Sprint 12.14 supplies the pure plan/context
admission, and Sprint 12.21 supplies the broker-indexed plan-bound acquisition journal. Sprints 12.22–12.26
supply the journal's canonical cursor record, same-broker frame-local admission/transitions, plan-owned
resource projections, exact current-frame `project up` command-authority composition, the exact pure
current-subtree reverse projection, exact Chain execution, and Production live-consumer adoption. The
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) alone composes that substrate
with proof-complete operator/descent authorization and recursive traversal. The
[service-runtime phase](phase-22-service-runtime.md) owns service-role authority.

The implemented pure `withCurrentFrame` boundary consumes
`ProjectPlan scope specDigest planId configId cfg` plus untrusted descriptive context and jointly generates
`CurrentFrame scope planId frame`, `ProjectFrame scope specDigest planId configId frame`, and
`ValidatedContext scope planId frame` under one fresh frame index. `teardownPlan` consumes that exact plan
and `CurrentFrame` to produce `TeardownPlan scope planId frame verb`, and `openTeardownForest` consumes the
projection without accepting another plan or frame. The resulting forest and every current successor and
authority package retain that nominal frame. Sprint 17.4 implements the closed
`LocalWork`/`DescentWork` sum and removes the general cursor surface, Sprint 17.5 carries the command gate's
`ProjectVerb`, and Sprint 17.6
separates frame-bound subtree settlement from root-only project-wide `DestroySettled`. Production
`down`/`destroy` now reconstruct or freshly admit
one exact plan and drive this projection
from its matching current-frame evidence; the projection still carries no command, journal, cursor, lease,
or mutation authority, so proof-complete authorization remains Phase 17 work. The implemented
`LifecycleCursor scope planId frame brokerGeneration verb phase` can be opened only from the matching
`AcquisitionJournal`, exact `ProjectFrame`, immutable root verb, and authoritative phase. Its six roles are
nominal. The acquisition phase is only the absent-row seed; after the per-frame row's compare-and-swap,
that row is authoritative. `withCurrentLifecycleCursor` discovers the closed durable phase under a rank-2
continuation, and only `Prepare -> Execute -> Teardown` successor eliminators exist. Each open or successor
rereads the exact canonical source acquisition key, record version, and bytes. Cursor CAS is at-most-once;
callbacks run outside the protected entry and are at-least-once, so retry, contention reads, or callback
exceptions may redeliver one durable phase without authorizing a second transition. Those cursors are
root-coordinator values and never process payloads. The root command entry consumes matching
`RootInvocationAuthority scope brokerGeneration verb` and `ProjectVerb verb` together with the verified and
bound root snapshot, binding, lease, root plan, acquisition journal, topology-root cursor, and opaque
root-coordinator `ValidatedLifecycleContext`. Its root-only durable bridge checks the lease's complete protected
origin — mode, project, store, record key/version, run, both stable digests, and broker epoch — and
revalidates the live mode, lease, snapshot, acquisition source, and current row before reserving the
invocation.

Recursive work stays under that one root admission. A root-owned `RootedFrameSession` joins the acquisition
to one exact `RootedPlanCatalog` frame and its target execution digest, opens or resumes that frame's
operation journal, and issues only bounded rooted grants. It does not relabel root-plan authority as a child
`CommandAuthority`. The storeless `FrameExecutor` receives the exact target config/plan/frame/node,
dependency and operation coordinates through authenticated grants, rechecks them against its independently
reconstructed projected plan, runs only the local probes and backend effect selected by that grant, and
returns an observation. Only the root settles the durable row and advances the authoritative cursor. The safe
`HostBootstrap.Authority` facade remains producer-free; callers receive neither the root reservation members
nor any independently composable journal/cursor package. Service dispatch instead
requires platform/manifest verification to jointly mint the inseparable
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. The manifest signs the immutable
rollout revision and controller/template identity before a workload exists; platform verification pairs
it with the concrete pod UID plus restart count or protected OS invocation nonce. Callers cannot
cross-pair its `RuntimeActivationAuthority`, signed `VerifiedRuntimeRolePlanProjection`, or private-channel
locator. The scope-correct project-owned `RoleCodec` verifies the actual mounted role-wire bytes, while
the activation-bound secret-channel verifier separately produces the exact `VerifiedSecretBundle`;
together they yield a fresh `VerifiedConfigWire`/`ValidatedServiceRequest`. The projection
contains only the non-secret leaf slice plus a proof binding its `rolePlanDigest` and exact
`configDigest` to the parent `planDigest`; a narrowed child never pretends to recompute the full
lifecycle-plan digest. Before Prereq or acquisition, `verifyRolePlanDraft` validates the non-empty draft
and signed role-plan digest without durable mutation. `withRoleLifecycleAdmission` then atomically
reserves the instance's one-use durable lifecycle admission/journal with fresh
`planId`/`invocationId`; if its independently complete predecessor manifest is non-empty it returns only
typed recovery-required state. The activation-bound `admissionKey` moves only Reserved→Consumed; lost
reservation acknowledgment yields `RoleLifecycleAdmissionUnknown` and the same opener/resume API
rehydrates stored identities rather than allocating again. `withRuntimeRolePlan` linearly CAS-consumes
the exact Reserved admission and verified draft and is fixed to that admission's `planId`; duplicate
tokens have one winner and it cannot reserve or mint a second cursor. Commit-before-cursor-delivery
yields `RolePlanOpenUnknown`; `resumeRuntimeRolePlanOpen` reconstructs only that same consumed
plan/invocation and cursor. It constructs only
`RolePlan scope specDigest planId configId secretDigest frame revision instanceId` plus
`RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId` and
`VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects`
from that projection, the verified request, and a project-owned role draft. It never rebuilds a lifecycle
`ProjectPlan` or root authority. After the composition-and-network-algebra phase yields the exact Serve
cursor, identity-indexed ready managed handles, and the inseparable retained receipt/lease package,
`selectAndRunService` consumes that foundation with the plan/binding/placement, validated request,
activation package, frame/context, and finalized runtime spec. It rechecks the exact workload-instance
identity and always returns the Drain transition on selection rejection, run outcome, or catchable
shutdown. It is internal to the sole public, core-owned masked run-to-Exit operation, so project callbacks
never receive live cursors/receipts and cannot bypass Drain by throwing. Runtime Harness verification
reads only the activation-bound private channel and mints no `HarnessConfigAuthority`; it does not replay
a consumed edge handoff. Thus context
does not mint root authority, an `up` grant
cannot authorize `down`/`destroy`, a stale phase or rollout revision/process instance cannot replay a verb, and another
Production plan cannot substitute its context. Each opaque authority also has a one-use invocation
identity; the effectful authorization gate atomically reserves that invocation at the live cursor/epoch,
a protected session-open compare-and-swap prevents reuse, and every effect requires the exact
resource/generation/operation/session/fence/attempt/journal-indexed prepared-operation value returned
after the matching journal transition and the matching plan-minted descriptor, operation binding, or
teardown step. A terminal observation returns `OperationAdvance` on both success and typed failure; its
eliminator yields the result only with the sole successor Open-project state/revision-permit pair.
Ordinary Haskell values alone are not linear.

The relationship between contexts is expressed in the **pure compositional lifts** — the topology is a
pure frame graph with parent links (§ U), not an implicit permission in the command line; it can
represent arbitrary chains such as host -> VM -> container -> cluster -> service pod, or host -> VM ->
Pulumi role -> EKS cluster -> workload. A process must fail before side effects when its local witnesses
do not prove it is in the declared current frame.

The exact current config-precondition matrix is:

- config-free writers: `project init`, `service init`, and `test init`;
- static/config-free routes: help, `service schema`, and `context path|schema|render`;
- file readers: `context inspect` reads the sibling config, while `context show [FILE]` reads its
  selected or default file;
- the harness route: `test run` reads the test config, refuses an existing sibling project config, and
  generates its own project config;
- existing-frame routes: `project up|down|destroy`, `service run`, and `check-code`.

Existing-frame commands fail
fast with exit code 1 when the context file is missing, fails to decode, names a different
project/binary, does not declare the required capabilities, or does not permit the requested command. An
existing-frame command also fails when the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)'s
required local witnesses cannot all be verified. A
daemon/service command must refuse to start unless the context declares a daemon/service role;
host-orchestrator commands must refuse to run inside a cluster-service pod; and a VM-scoped kind/test
workflow must refuse to run directly on the host Docker daemon unless the Dhall declares a local
test-harness frame.

A recursive verb therefore has **two entries, and they are two types rather than one command class asked
to mean both**. An *operator-initiated* teardown validates at the topology root and nowhere else: the
current frame is the chain's root, whose orchestration placement is the host orchestrator. A
*descent-initiated* teardown runs in a nested frame and is admitted only by consuming the verified
handoff its parent minted for that exact edge (§ EE), never by naming a command class the call site
chose as a source constant. The discriminator is the authenticated wire on the private channel, so it is
not reachable from `argv`, an environment variable, or a flag, and an operator cannot invoke the nested
form directly. `project up` is uniform across orchestration frames and needs no such split; the teardown
verbs do, because their operator entry is root-only while their descent is not.

Every context's `<project>.dhall` is **generated by the project binary from passed Dhall parameters** —
some supplied at the frame and some **forwarded from the parent context's `<project>.dhall`** — so a child
config is generated rather than hand-authored. Current helpers narrow the descriptive context to the
child frame but retain the full demo `ProjectConfig`, parent resource envelope, and host/build/deploy
fields. The target makes the security invariant structural: the parent renders only a descriptive
`RuntimeRoleWire fields service` containing required framework-validation fields plus fields visible to
that exact child consumer, together with validated frame/resource/witness proof. The wire cannot contain
the parent's plan-only fields. The child verifies those exact bytes through the matching `RoleCodec`,
mints a fresh child-local `configId`, and only then obtains opaque role parameters; neither the parent's
`configId` nor a `ValidatedServiceRequest` is serialized.

Current projection and delivery are split from the named `context-init` row, whose action body only
announces a frame anchor. The VM projection/streaming occurs inside the composite bootstrap action; the
container projection is carried by the descent that same `context-init` row declares, so the row and the
payload are one plan value even though the projection function is still computed outside the plan's
delivery operation; and a Kubernetes service receives a ConfigMap that overrides the image's baked
container config. VM/container projections
travel on the lift's `stdin` only — never `argv` or an environment variable — and the descending binary
writes its own executable-sibling `<project>.dhall`; there is no host-side intermediate config file or
config bind-mount. Production command adoption now retains the opaque `ProjectPlan` through its local
interpreter. The hidden authenticated frame entry binds signed delivery to the cataloged target
plan/config/frame and exact rooted session, without receiving the root store, acquisition journal, or
lifecycle cursor. Root-issued grants join projection, preparation, and delivery to one plan node, so an
announcing row cannot disagree with the bytes the child receives or let the child select another operation.
A child config is written in place at the frame that announces it; there is no build-then-copy or mount
surface, because a copy and a mount are two representations of one delivery and can disagree.
The read-only `context` command (§ Z) treats **every** `<project>.dhall`
uniformly — it introspects the explicit context and renders the global compositional lift sequence
(`topologyFrames` / `parentChain`) with the current frame highlighted, regardless of which roles the config
declares; it performs no mutation. The
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
owns the sibling-config representation and validated child projection, the
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md)
owns admitted child delivery, and the
[`test`-and-`context`-command-semantics phase](phase-20-test-and-context-commands.md) owns read-only
introspection. Child-config delivery streams the projection in place over the lift's `stdin` channel;
there is no build-then-copy or config-mount path.

### Y. Project Lifecycle Command And The Step Chain

**Owning phase**: [the step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md)
A project's lifecycle is a pure, **opaque** `ProjectPlan scope specDigest planId configId cfg`, where
`cfg :: Type -> Type`. Sprints 12.7–12.29 implement scope finalization, fresh non-empty plan admission, the
plan's retained root/config/nodes, pure `PlannedStep` forward order, `DerivedTopology`, public stable
snapshot bytes, pure plan-local current-frame evidence, `PlanDigestBinding` verification, bound snapshot
persistence/existing admission, the recovered Production profile, safe restart input refinement,
fixed-identity recovered plan reconstruction, plan-owned resource/edge projections, the same-broker
acquisition journal and cursor, exact local `project up` authority, the frame-indexed current-subtree
reverse projection plus its projection-only forest opener, total descriptor production from the exact
plan and one matching projected node, exact current-frame Chain interpretation, and the Production
current-frame foundation. Authenticated recursive child entry and traversal are not part of those sprints;
the [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns them. Sprint
12.30 extends that foundation with generic plan-indexed Budget admission; it is not a Harness call-site
adoption sprint.
A fresh plan is constructed only inside a fresh `planId` continuation from `LifecycleProfile scope`,
`CanonicalProjectRoot scope rootId`, `ValidatedConfig scope specDigest configId (cfg scope)`, and a
non-empty `PlanDraft scope specDigest (cfg scope)` sequence. A Production plan therefore cannot contain a Harness
config even if both configs use only shared fields, and two Production plans cannot exchange local
evidence. Reconciliation's exact descriptor route consumes the indexed plan directly and retains its
stable plan/configuration/node/frame/operation projections. Production dispatch first attempts exact
existing-bound reconstruction and otherwise admits one lawful fresh/unbound-retry plan. `--dry-run`
renders that plan; effectful `up` persists/binds it, admits the root-refined lifecycle context, and enters the
Cabal-private root-Up `LifecycleEntry` producer/fixed interpreter. That producer alone derives the acquisition
journal/current cursor and calls generic `authorizeRootProject` before reaching public Chain. `down` and
`destroy` derive their
current-frame reverse work from the same exact plan representation. No Production compatibility command
authority, forward interpreter, descriptor, or teardown-plan producer remains. The
[test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns the corresponding
consumer for Harness: it retains the exact Harness-scoped plan across generated-config ownership,
interprets root Up through the same hidden fixed entry and retains the separate teardown route, and exposes no project-lifecycle
callback through `TestSuite`.

Stable snapshot format version 3 binds that exact canonical root into the canonical bytes and
content-derived digest as a bounded, length-framed stream of big-endian 32-bit `Char` code points. The
structural parser exactly decodes the root, rejects empty, partial, NUL, oversized, and out-of-range
payloads, and accepts only an absolute root or the one shared non-absolute compatibility sentinel. The
current `Reconcile.LifecyclePlan` encoder uses that sentinel because its compatibility constructor receives
no `CanonicalProjectRoot`; an admitted `ProjectPlan` always uses its absolute canonical root.

The bound-snapshot/recovery path preserves a single local identity. Existing-snapshot admission generates
the sole local `planId`; `BoundInvocationRecovery`, the recovered Production profile, and plan reconstruction
all retain that same identity and never quantify or mint another. Restart finalization creates an independent
candidate specification brand, so the sole hidden config-refinement token is issued only after exact
recovered-profile/finalized-codec specification agreement and independently rechecks the validated config's
retained specification. The public bridge preserves that config's exact local identity, digest, and value,
regenerates drafts from the finalized builder, and the fixed-plan reconstruction still requires exact
root-bound canonical bytes/digest and origin agreement. The plan-owned reverse projection has the exact
pure shape:

```haskell
teardownPlan
  :: ProjectPlan scope specDigest planId configId cfg
  -> CurrentFrame scope planId frame
  -> ProjectVerb verb
  -> TeardownPlan scope planId frame verb
```

`teardownPlan ... ProjectDown` and `teardownPlan ... ProjectDestroy` therefore have distinct result types,
and the projection accepts neither an acquisition journal nor a caller-supplied frame name. A total
`teardownPlan ... ProjectUp` retains that canonical verb/digest/frame but projects no reverse work;
`openTeardownForest` returns `TeardownProjectUpHasNoReverse` before its empty-plan check. The pure plan and
frame evidence themselves expose no cursor or command authority.

The implemented `openTeardownForest` is the sole initial-forest producer and consumes the already
frame-indexed `TeardownPlan` projection alone — not another `ProjectPlan` or duplicate `CurrentFrame`.
The returned `TeardownForest scope planId frame verb` and every progress, authorization branch, closed work,
successor, completion, and `SubtreeSettled scope planId frame verb` retain the projection's existing nominal
`frame` index. Project-wide `DestroySettled scope planId` is deliberately unframed and can be promoted only
from the unique topology-root destroy subtree plus the exact `ProjectPlan`/`CurrentFrame`. Sprint 17.4 implements one hidden
`TeardownWork` sum whose total eliminator yields either opaque local execution or an existentially indexed
exact parent/child descent. Sprint 17.5 removes the parallel teardown-verb universe and carries the canonical
`ProjectVerb` term through command admission, projection, recursive argv, and core cluster action selection.
Sprint 17.6 then mints
frame-bound `SubtreeSettled` and permits project-wide `DestroySettled` only from the unique topology root.
The private current eliminator exposes either a destroy-only plan-derived pre-descent reachability step or
the plan-derived settled-child proof with closed ordinary work. Callers cannot wrap either branch. After `down`, the
pre-descent step can
make only the exact stopped provider teardown-reachable before retained children are visited; its
successor forest exposes those children, and only their later settlement exposes the ordinary provider
stop/delete step. Each local or pre-descent attempt returns the successor forest even on typed failure;
descent success instead requires the exact child `SubtreeSettled` proof and bulk-imports its ordered terminal
observations. Only exact completed forests mint `SubtreeSettled`, and only its unique-root Destroy refinement
can enter the `DestroySettled` verifier. Callers cannot independently supply or update
chain, topology, teardown, lifecycle scope, or plan identity. Phase 12 owns the local/current-frame reverse
and Production foundation, Phase 19 owns Harness command consumption, and Phase 17 alone
owns proof-complete recursive authorization and complete forward/reverse traversal.

The plan shape is **code**: it is the project's identity (§ W). The sibling `<project>.dhall` carries
**parameters + context + witness**, never plan shape; a copy of the binary verifies it is in the frame its
`<project>.dhall` describes, or fails fast (§ X). Optional structural variation (for example, deploy
straight to Docker and skip the VM) is a typed field in the **root** `<project>.dhall`, so plan
construction is a pure function of validated root parameters.

- `project init` — a config-free initializer. With no role, output, or overwrite flags it writes the
  default root host-orchestrator config. The current shared parser also accepts `--role`, repeated
  `--also-role`, `--output`, `--force`, `--if-missing`, and resource/deploy overrides. Every added role
  passes through the
  [Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)'s
  closed placement relation and validating `addRole` constructor; an incompatible primary/additional role
  pair is refused during assembly. The current parser maps `--force` to replacement, `--if-missing` to
  keeping an existing file, and gives `--force` precedence if both are supplied. The
  [installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
  contributes no init-request or role-selection constructor. Python builds
  and invokes the host-native binary using the platform-specific handoff in § M; it does not initialize
  or trigger config creation. A normal
  existing-frame command fails fast (exit 1) when no sibling `<project>.dhall` exists (§ M).
- `project up` — the **target** interprets the chain recursively from the current frame: run the steps for this frame,
  then for the next nested frame provision it, build/install the pb in it, and hand off `pb project up`
  (the fractal bootstrap, § U). The current public Chain interprets the exact current-frame segment and
  identifies its declared descent boundary. The
  [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns the root coordinator,
  authenticated frame-executor entry, and cross-frame process continuation. Reconciliation
  uses the managed `Changed Created|Repaired|Adopted` / `Unchanged` result algebra, while foreign
  observations return a non-authorizing `Unmanaged` handle (§ EE), through the
  [canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md).
  The
  [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns its
  cluster consumers, and the
  [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns recursive command
  consumption.
  `--dry-run` renders the pure chain without acting.
- `project down` — the **target** is child-first recursive stop across every acquired frame. VM frames use the
  provider **stop** operation (incus/Lima **stop**, WSL2 `--terminate`; never destroy or unregister), so
  the guest and its disk survive. At the kind-cluster frame, `down` deletes the kind cluster, because kind
  has no reliable stop/restart contract; its removal set is **empty**, so no filesystem path is removed.
  Cluster-local persistence (for example a PVC on kind's default `local-path` provisioner) lives **inside
  the kind node container** and does not survive that delete. Best-effort and idempotent means every
  independent cleanup is attempted and any failures are aggregated and reported; it never means silently
  swallowing cleanup failure. Current code dispatches current/root teardown hooks rather than a typed
  recursive acquisition unwind; the recursive-lifecycle-command phase owns that gap.
- `project destroy` — the **target** is recursive `down`, then deletion of everything this run acquired,
  **including the provisioned frame
  and its disk** (`incus delete --force`, `limactl delete --force`, `wsl --unregister`, which removes the
  vhdx). The host-root `.data` is **inside** the single plan with an explicit `Preserve` policy and a
  verified receipt, but neither reverse projection places it in a destructive removal set. The demo now
  creates that host project-root, carries it through the provider share/alias and nested mounts, and
  retains it across frame teardown. The mechanism has dated provider evidence, but the owning phase remains
  Active until a dedicated write → destroy → up → read-back run proves durability end to end. The canonical
  home is [durable_state](../documents/architecture/durable_state.md). Current child-first recursive
  destroy/partial-failure unwind remains the recursive-lifecycle-command phase work.

The reverse projection is **frame-indexed**. Pure `withCurrentFrame` admission derives
`CurrentFrame scope planId frame` jointly with `ProjectFrame` and `ValidatedContext` from the exact
`ProjectPlan` and descriptive binary context; it grants no authority. `teardownPlan` consumes that exact
plan-plus-frame package and produces `TeardownPlan scope planId frame verb`. Its frame index remains nominal
through the forest, closed work, successor, completion, and frame-bound `SubtreeSettled` proof, while the
project-wide `DestroySettled` exists only after unique-root promotion.

Recursive reverse authority stays at the root coordinator. The coordinator selects an immediate descent only
from the exact rooted plan catalog, opens and settles the matching root-owned frame session, and sends a
storeless child only signed prepared work. The child receives no `ProtectedStore`, acquisition journal,
`LifecycleCursor`, or `CommandAuthority`; it returns bounded observations that cannot settle a subtree by
themselves. Only the root's exact catalog/session/observation join yields `SubtreeSettled`, and only the
complete unique-root forest can yield `DestroySettled`. A memoized/raw descent result, caller frame text, or
independently reconstructed child cursor therefore cannot authorize or settle reverse work.

The recursive-lifecycle phase closes on the core host-static `-Werror` gate with real local child processes,
duplex pipes, root-owned protected journals/cursors, storeless frame executors, and authenticated
forward/reverse entry. Live Production
`project up`/`down`/`destroy` and the worked-demo Harness `10/10` confirmation belong to Sprint 24.30 of the
[worked-demo phase](phase-24-worked-demo.md), not to the Phase 17 gate.

The `Preserve` rule applies to both ordinary project verbs in every scope. Harness terminal cleanup is a
separate, plan-derived projection. A narrow `HarnessCloseRoot`, derived from either the live harness root
or the exact abandoned-run recovery authority, combines the project-wide Harness mode lease, bound
snapshot, `BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration`, exact versioned
`ProjectOperationState ... OpenProject`, and same-version `ProjectClosureEvidence`.
`authorizeHarnessClose` consumes the same exact Harness `ProjectClosureEvidence`, rejects its
true-pre-effect branch, verifies every ordinary operation session Closed, and only then atomically changes
Open to a fresh `ClosingProject` epoch while creating its close journal; persisted Closing therefore proves
ordinary destroy had already settled, and a concurrent prepare and close cannot
both win, and a retained proof from before destroy→up cannot close the new journal version. The sole
`verifySubtreeSettled` producer checks the complete frame-bound plan projection against the exact ordered
terminal observations, retaining released, foreign-retained, and refused distinctions while rejecting any
failure or unresolved node. `verifyDestroySettled` then checks the exact plan digest, current frame, full-root
terminal sequence, and unique topology root before minting unframed project-wide proof. The independently
complete Closed session set and bound lease are joined later by `destroySettledClosure`. The sole
`verifyNoProjectResourcesAcquired` producer checks the exact bound snapshot/revision/state tuple has no
resource operation/prepare/fence/receipt/effect record and that every registered session is Closed and
empty. Only their closed conversions mint `ProjectClosureEvidence`; unresolved partial ownership
produces none.

The close projection releases the exact owned generated config and `.test_data/<runId>` generations
through the same durable intent/unknown/reprobe/fence protocol, specialized to the Closing epoch. Every
terminal close observation returns `HarnessCloseAdvance` on success or typed failure; its eliminator
yields the only successor close journal. A persisted Closing run resumes only its exact close
authority/journal; it cannot remint Open, general Harness, or `ProjectUp` authority. After all close
operations and sessions settle, one protected finalizer atomically records `ClosedProject`, closes the
bound lease, and releases the exact Harness mode epoch last. Production mode release after settled
destroy instead requires a closed `ProductionClosureAuthorization` made only from exact
`ProjectDestroy` authority plus `DestroySettled`. Its other constructor accepts any exact Production verb
only with `VerifiedNoProjectResourcesAcquired`, so a true pre-effect `up` refusal can close but partial
`up`/`down` teardown cannot be relabeled as settled. The finalizer records Closed, closes its invocation
lease, and clears its mode in one protected compare-and-swap, with no persisted mode-cleared Closing
intermediate. Session opening advances and compare-and-swaps that same Open project-journal version, so
it and Production finalization have exactly one winner.
Before another run is allocated, `recoverAbandonedHarnessRuns` enumerates both unbound and bound
incomplete leases at one protected-store version. Separate rank-2 fold callbacks receive every exact
existential `VerifiedIncompleteRunLease`; the sweep rechecks terminal closure after each callback, so a
caller cannot manufacture/skip a run or return no-op success. An unbound lease closes only with
`VerifiedUnboundLeaseHasNoEffects`; a bound lease reopens its exact snapshot and
`BoundInvocationRecovery`, then selects Open revision recovery or persisted close recovery before any
journal is exposed. Only a protected empty-set compare-and-swap yields
`ClosedAbandonedHarnessRuns`, which `withHarnessRoot` consumes atomically with fresh allocation. This
preserves durable data for destroy→up assertions within a variant without leaking it after terminal
harness close.

A normal root-frame `project up` failure runs the same receipt-driven delete teardown before it reports
failure. Outcome classification is exhaustive and consistent: compatible but unowned state is
`ForeignResult`; an incompatible/occupied identity or contradictory ownership claim is `Conflict`; a
policy decision declining an otherwise authorized owned/absent transition is `SafetyRefusal`; a backend
that cannot provide the required strong semantics is `Unsupported`; and an attempted operation failure
is `Failure` with recovery disposition. Only a refusal proven to precede every acquisition has an empty
rollback set. A late policy refusal after journaled preparatory effects unwinds those exact owned effects;
it must not skip cleanup merely because its report label says refusal.

The **Step algebra** is the reuse unit: `hostbootstrap-core` ships the host-management step kinds
(deploy-VM, `ensure-*`, copy-source, build-pb, build-image, `context-init`, deploy-kind, deploy-chart,
expose-port), and a project contributes its own step kinds into the same `[Step]` (the lift-chain stream,
§ T). Host and project steps interleave freely; a project's workload (a registry install, a web-serve, a
role) is expressed as steps in the chain, not as separate top-level verbs.

### Z. Chain-Driven Test Surface And Context Introspection

**Owning phase**: [the test-and-context-commands phase](phase-20-test-and-context-commands.md)
The test surface consumes the project's real lifecycle rather than re-expressing bring-up (§ W). It is
the one test engine. The command retains one exact Harness-scoped `ProjectPlan` through generated-config
ownership and calls the shared current-frame forward/reverse interpreter directly. `TestSuite` owns only
the safety probe, assertion-environment opener, case matrix, per-case assertion, and post-reverse absence
assertion. Selection, reporting, exclusive execution, durable recovery, and receipt-driven cleanup remain
engine concerns, never a second cluster-bring-up path.

The [step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) supplies the plan,
current-frame, Chain, reverse-projection, and Production-command foundation. The
[test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns the Harness command
consumer and the assertion engine described here; Harness call-site adoption is not Phase 12 work.

- `test init` — writes a per-project `<project>.test.dhall` containing `testResources` plus declarative
  `testVariants`, without requiring a pre-existing sibling `<project>.dhall`. Compiled Haskell owns case
  bodies; the decoded variant names/messages are validated into opaque typed identities and projected
  with the compiled case registry into the total matrix before mutation. Later additive config may carry
  scoped overrides such as secrets. Its target request has no overwrite flag and uses
  `RefuseExisting`.
- `test run <case-id>|all` — runs one registered typed case or every registered case. The **target**
  semantics are root-only, fail fast without `<project>.test.dhall`, and reject a non-root context before side
  effects; the test-and-context-commands phase owns that still-open parser/gating contract. For each **distinct test configuration**
  (cases sharing a config share one stack; a case needing different resources/secrets declares a different
  config) the harness: (a) writes a test-specific `<project>.dhall` (the test-config overrides projected
  into a normal project config) while retaining its exact Harness plan, (b) invokes that plan's common
  forward interpreter directly, (c) runs that config's
  case assertions in the frame appropriate to each — e.g. a
  Playwright assertion as a container on the VM host network in the VM frame, outside the cluster — and
  (d) invokes the common reverse interpreter directly. Authenticated self-reference remains only inside
  recursive child-frame transitions.

The harness checks two **hard fail-fast safety preconditions** before *any* test runs, so a test never interferes
with production: (1) a sibling `<project>.dhall` already exists → refuse (never overwrite a production
config); (2) a production cluster is running → refuse (never touch production state). The sole
precondition verifier derives its total probe from installed project identity; callers cannot inject a
successful probe. `withHarnessRoot` reruns it while atomically acquiring the project-wide Harness mode
lease. Production openers contend on the same mode record, so neither profile can slip between precheck
and ownership; `ProjectDown` retains Production mode, and Harness mode is released only after terminal
close. If either precondition holds, **no tests run**. Later classification follows § Y/§ EE: compatible unowned state is `ForeignResult`,
incompatible identity is `Conflict`, policy refusal is `SafetyRefusal`, and missing strong backend
semantics is `Unsupported`. State the run did not create is never torn down, while any journaled
preparatory resources it did acquire are rolled back by receipt; a late refusal cannot silently skip
that owned rollback. Generated config and
`.test_data` require all four Locked-Origin Identity Ownership clauses in § EE, not a
check-then-create sidecar, path-name heuristic, bare exclusive create, or compare-then-unlink. A
backend that cannot take the kernel lock, record the origin, or report a stable object identity
reports `Unsupported` and mints no receipt. The harness carries a receipt
through bring-up, assertions, and teardown and may remove only that exact generation. An incompatible
pre-existing path or contradictory ownership claim is a structured conflict and no test runs; a
compatible unowned object remains `ForeignResult`. Changed config bytes are quarantined
without releasing ownership; foreign state is never torn down. Test durable storage is always
`.test_data/<runId>`, never `.data`. A teardown failure makes the variant fail rather than producing a
green report with leaked state. Ordinary project teardown preserves that root; after the variant's
settled destroy, the harness-only terminal close projection conditionally releases its owned generation
and closes the lease.

Current Harness does **not** invoke a top-level or recursive lifecycle command in another process. For each
variant it retains one exact Harness plan and drives the Cabal-private fixed root-Up `LifecycleEntry` plus
the exact current-frame reverse boundary around assertion-only code. The entry alone derives the execute
journal/cursor/authority and supplies them to the lower common Chain. Its independently authorized root still owns
`UnboundRunLease (Harness projectId runId) brokerGeneration` and binds that lease to the exact verified plan
snapshot before prepared work.

For a plan-declared recursive child transition, the authenticated-handoff phase supplies the generic
authority substrate without serializing root authority. The ordinary signed `HandoffBinding` owns the
immediate edge: exact project, specification, payload kind, scope, protected-store identity, stable root
snapshot revision, broker generation, parent/child frames, one complete-payload digest, verb, closed phase,
and token commitment. The additive root-signed `RootedPayloadBinding` exact-binds those legacy edge bytes and
separately frames complete-payload and child-config digest claims. Possession of that signed data or of a
neutral `RecoveryChildPackage` admits no recovery field. `withVerifiedRecoveryChildPackage` rerenders and
cryptographically reverifies the supplied rooted value against the exact `VerifiedHandoff` and installed key,
decodes the package only from the authenticated payload, and recomputes the complete-package and extracted
child-config digests before exposing either field. `RootedPlanCatalog` owns catalog identity, and its rooted
requests own requester path and ordering coordinates; neither is a field of the ordinary binding. These values
name root-owned durable lineage but convey neither a store locator nor durable-record authority. Grant
verification yields transport-only
`VerifiedHandoff (Harness projectId runId) brokerGeneration`; exact-byte config verification separately yields
`VerifiedConfigWire` and `ValidatedConfig`. `Config.Schema.withVerifiedConfigHandoff` checks the signed
wire/config/specification/verb/phase coordinates and alone yields the fully indexed
`VerifiedConfigHandoff`; `ProjectPlan.Construct.withChildProjectPlan` then yields the exact child plan,
digest binding, and opaque `ChildPlanAuthority`. The recursive-lifecycle-command phase consumes those values
through a root-owned plan catalog and frame session, authenticated forward/reverse executor entries, a
caller-free canonical completion wire, sealed completion/process prerequisites, private process ownership,
and the shared recursive call sites. The executor receives exact grants and returns observations; the root
alone owns frame journals, cursor transitions, and receipt settlement.

Each one-use command/handoff invocation opens one durable versioned session only with
`CurrentBrokerSessionAdmission`. Clean activation mints that admission after proving no older broker
session remains Open; abandoned-run activation instead uses the exact old-permit fence set and a
verified manifest pairing the independent complete session set with its independently complete
operation set. Registering an initial intent consumes the exact closed origin—sole no-prior-generation
evidence or a released-reacquisition `FreshGeneration`—and atomically adds the operation/generation to
that exact session while advancing the session/project-journal versions; no orphan intent can be
omitted and the caller cannot choose a generation. An intent may validly have no initial fence but cannot
prepare. Recovery idempotently completes the stable initial-fence protocol and threads the sole
successor session/state/permit before exposing current-fence authority. Its protected
exact-set interpreter CAS-rebinds each existing stable session record—including a zero-operation Open
session—and totally classifies unknown, the five pre-call continuable phases, already-observed retryable,
successful, and terminal operation records. Only the continuable phases receive current-fence prepare
authority; only reservation/effect/adoption absence, same-identity ordinary/adopted teardown,
repair-original, and managed-phase-from receive verified current-fence same-key retry authority; a crash
after recording one of those observations remains recoverable. It verifies/rebinds the complete
resource-record set, settles/closes every member, and threads the sole successor state/permit pair.
Missing/duplicate members, wrong membership, missing/replaced resource evidence, or unresolved internal
recovery cannot yield admission or open a new command session.
Session open and close also advance that shared project-journal version and return the sole successor
state/permit pair; opening rechecks permit-open/not-frozen state in the same protected transition used by
migration freeze and terminal close.
Before every child reservation/mutation/delete, the root
verifies a prepare request naming the exact authority epoch,
verb/phase/frame, session, journal/resource/generation/operation version, current authoritative fence,
precondition-set identity, and call digest. The plan is the sole producer of the exact closed zero/one/
many dependency snapshot and jointly indexed `OperationPreconditionSet`/verified backend call. It
internally traverses the descriptor's complete edge set and runs the plan-owned probes; callers cannot
supply retained readiness or omit an edge, and its private no-dependency branch prevents fabricated
requirements. One protected
compare-and-swap consumes that set, reruns every target/dependency probe and observation version,
obtains conditional backend versions, and revalidates the active project mode, bound lease, active
plan revision/no migration freeze, Open-project state, command/session/fence, readiness generation, and
record phase, then records the exact operation-specific unknown state **before** returning the
resource/generation/operation/precondition-set/call-digest/session/fence/attempt/journal-indexed
`PreparedOperation` and matching fresh `PreparedPreconditions` required by the adapter together with the
fresh-versioned successor Open-session, Open-project state, and
revision-permit authority. Every adapter terminal observation returns `OperationAdvance` on success or
typed failure; its eliminator yields the result only with the sole next state/permit pair. An adapter
accepts neither retained `Ready`/prerequisite data nor either half of the prepared pair. Initial fence
creation and `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved` rotation persist and resume one
stable proposed epoch while returning the sole successor state/permit pair; a delayed old permit is
rejected or deduplicated. Terminal acknowledgment first
verifies every registered outcome settled and then compare-and-swaps the exact Open-session version
Closed, so a retained proof or concurrent prepare cannot win. Loss before prepare refuses, while loss
after a prepared backend call leaves an explicit unknown state for total reprobe. Generative handles,
`JournalEntry`, and receipts are never serialized. The token is never in Dhall, `argv`, an environment
variable, or durable config; teardown gets a fresh token, and a harness broker cannot sign Production
authority. Before allocating a new run, the root must recover/teardown any protected incomplete old
harness lease under that exact old run scope.

This contract is built by the authenticated-handoff-and-child-admission phase over the sessions/journal/
fences and prepared-operations phases beneath it, and consumed by the recursive-lifecycle-command,
recovery, and test-harness phases above it.

`context` is a **read-only** command that treats **every** `<project>.dhall` uniformly: it introspects the
explicit context and renders the global compositional sequence of lifts (`topologyFrames` / `parentChain`)
with the current frame highlighted, so an operator can see the whole `metal → VM → container → cluster`
chain and where this binary lands in it — regardless of which roles the config declares. It performs no
mutation. Child-config creation is internal `project up` work, currently split from the announcing
`context-init` row and targeted for one plan-owned projection/delivery operation (§ Y); it is not a
`context` subcommand.

### AA. Service Runtime Command

**Owning phase**: [the service-runtime phase](phase-22-service-runtime.md)
`service` is the third DSL-driven core command (alongside `project` and `test`). It runs a project's
**long-running roles** — the `HostDaemon`/service run-model (§ T) — and is driven by a **service-configured**
`<project>.dhall`:

- `service init` — writes one descriptive Production role wire from a selected service in the finalized
  registry, one legal `ClusterService` or `Daemon` placement, and role fields assembled/projected through
  that same spec. Callers cannot choose the hidden field row or arbitrary roles. Its target
  writer-specific request has no overwrite flag and uses `RefuseExisting`. It does not sign or install
  runtime authority: an authorized controller/OS-service launcher must atomically pair those bytes with
  the broker-signed manifest and measured identity before `service run`.
- `service schema` — currently prints the full validated-codec `cfg` shape. The target prints the
  finalized project-owned role-wire schema registry/union derived by `RoleCodec`, with separately named
  `Production` and `Harness` scope families; round-trip/anti-drift tests prove every runnable role wire
  agrees with the decoder for its exact scope (§ Q).
- `service run` — loads the effective config and runs its selected role. There is no positional variant
  argument. There is **no `service down`**: lifetime is owned by the enclosing Kubernetes controller or
  host project lifecycle and torn down by `project down` / `project destroy` (§ Y).

`service run` is a **leaf-frame runtime command, never an orchestrator**. Core checks the primary kind is
`ClusterService` or `Daemon`, canonically verifies one sibling snapshot, and structurally selects exactly
one definition from the jointly finalized typed registry. The selected request and action share that
snapshot; demo handlers do not reload config. The finalized project specification hides each
project-declared role field type and jointly derives its full `ProjectCodec` and
`RoleCodec scope specDigest fields`; callers cannot pair codecs or choose `fields`. A validated config can
project a `RuntimeRoleWire fields service`, but not a request or handler parameters. At the runtime
boundary, the signed manifest fixes an immutable rollout `revision`, while platform verification pairs it
with a measured `instanceId` (pod UID plus restart count or protected OS invocation nonce) and yields one
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. Runtime role-wire/ConfigMap bytes
contain Production pointers or Harness secret handles, never inline fixture bytes; the exact run-scoped
private bundle is internally read and verified through the activation-bound channel, not accepted from a
caller or gated by `HarnessConfigAuthority`. `withVerifiedRuntimeRoleWire` consumes the matching
activation package, finalized runtime spec, verified secret bundle, and actual mounted bytes. Its private
eliminator yields the local
`VerifiedConfigWire` plus an existential opaque
`ValidatedServiceRequest specDigest configId secretDigest fields service` under one fresh child-local `configId`. That request
is an inseparable bundle of the typed request and
`RoleParams specDigest configId secretDigest fields service`; neither member has a public independent constructor or projection,
and neither crosses the process boundary. `fields` is built through a closed consumer-indexed schema algebra:
`ProjectField (VisibleTo consumers) name a`, where the closed consumer tags include framework
validation, a typed plan frame, Harness assembly, and `Service service`. Context/identity/request
metadata can therefore be visible to framework validation without entering a handler, and build/deploy
inputs can be limited to their plan frame rather than mislabeled as service or host data. Core owns the
consumer/filter algebra but not the project field names or value types.
`RuntimeRoleWire fields service` contains the union of the mandatory
`FrameworkValidation` projection and fields tagged `Service service`; plan/build/deploy-only fields cross
neither boundary. `RoleParams specDigest configId secretDigest fields service` is the narrower second filter: it can be
constructed only from fields tagged `Service service` under that exact config identity, so
framework-only metadata remains available to validation without entering the handler, and parameters
from another validation cannot type-check. the composition-and-network-algebra phase's role engine first atomically reserves one durable
lifecycle admission for the exact instance, then constructs the matching role plan/binding/placement.
The signed placement's `permittedEffects` ceiling conservatively derives the acquisition plan and closed
lease disposition before Acquire: a ceiling that permits any exclusive/mutating effect requires the live
fenced lease, while only a ceiling that prohibits all such effects can yield the no-lease proof. The
engine then acquires managed listener/connection/worker handles and probes those exact identities. Partial
acquisition or readiness failure yields only Drain plus every owned/unknown receipt; success yields
`ReadyServiceHandles` and the unique Serve cursor. Serve has no handler-visible open/bind/spawn escape
hatch. A restartable worker's ready identity is a stable supervisor handle; only a core-owned,
journal-prepared supervisor transition may replace a child, and it must reprobe that child before another
request. The sole effectful `selectAndRunService` operation then jointly consumes those values, the whole
local request bundle, inseparable activation/projection package, and finalized runtime spec. Registry
lookup reveals the exact handler effect row. A private
`EffectAuthorization scope specDigest planId frame revision instanceId service effects` is constructible only when
the opaque `VerifiedServicePlacement ... permittedEffects` permits that row; `DurableStore` additionally
requires `DurablePlacementAuthority scope specDigest planId frame revision instanceId service`, derived from
verified durable placement rather than decoded context. The gate atomically reserves a one-use
`ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
ServePhase service effects` and transfers it
directly into one existential package:

```text
SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase fields
  = exists service effects.
      ServiceSelection
        scope specDigest planId configId secretDigest frame revision instanceId ServePhase service effects
    + ValidatedServiceRequest specDigest configId secretDigest fields service
    + (RoleParams specDigest configId secretDigest fields service
         -> ServiceProgram
              scope specDigest planId configId secretDigest frame revision instanceId
              ServePhase service effects ())
```

Those three members cannot be separated or substituted by callers. The package is internal to the
core-owned masked run-to-Exit operation; no arbitrary `IO a` callback receives it, a phase cursor, or live
receipts. Private phase eliminators cannot escape those values to consumer code.
`ServiceSelection ... effects` is an opaque proof that the exact effect row is authorized by the
placement/effect witness and consumed service command authority, so activation authority alone, a
non-Serve cursor, a non-durable placement demanding `DurableStore`, or a program demanding a different
or additional effect cannot be packaged. No generic service `CommandAuthority`, pure
`finalizeSelectedService`, or separable effect proof is public. The service command authority is
single-use; an already consumed invocation cannot construct or run another service package. The handler
receives only `RoleParams specDigest configId secretDigest fields service`, not
`ValidatedConfig ... cfg`. `ServiceProgram` is a closed,
capability-indexed program type with no public `IO`, `MonadIO`, arbitrary filesystem, or config-read
escape hatch; core interprets only the finalized service's authorized network/durable-store/process
effects. Therefore the public handler API cannot reopen the sibling path or pair a Web payload with an
accelerator handler.

An effect row is family permission, never mutation or retry authority. Every mutating
durable-store/process/backend constructor first creates an opaque
`SealedServiceEffectCall ... effect ... targetId operationKey callDigest` containing the exact target and
arguments. The backend adapter accepts no separate raw request. Private protected prepare consumes only
that sealed call, the exact prior `ServiceEffectReady` session, and the whole retained resource/lease
package. Success yields
`PreparedServiceEffect ... targetId operationKey callDigest fence attempt journalVersion` carrying the
sealed call and package; a different target or arguments cannot reuse it.

Prepare itself is constructive on failure: known rejection yields a
`ServiceEffectPrepareFailed effect targetId operationKey callDigest fence attempt` session, and uncertain
journal commit yields
`ServiceEffectPrepareUnknown effect targetId operationKey callDigest fence attempt`. The private
eliminator returns either failure state only with the sole successor journal session and whole retained
package directly into the core-owned Serve→Drain/recovery path. Neither state is accepted by normal
prepare, and no `Either` can drop its cleanup authority before a `PreparedServiceEffect` exists.

The backend consumes only that prepared value and returns
`ServiceEffectAdvance ... targetId operationKey callDigest ... fromJournalVersion nextJournalVersion
nextEffectState`. Its private eliminator exposes `ServiceEffectOutcome nextEffectState` only with the sole
fresh journal session under the unchanged effect row/phase and reconstituted retained package—never a
bare lease detached from receipts. Unknown indexes that successor as
`ServiceEffectUnknown effect targetId operationKey callDigest fence attempt`, which has no ordinary
prepare/retry constructor until same-key/fence reprobe yields an observed resolution or
`VerifiedSameKeyRetry ... configId secretDigest ... service effects phase effect invocationId sessionId
targetId operationKey callDigest fence previousAttempt nextAttempt unknownJournalVersion
retryJournalVersion`; observed success/failure yields `ServiceEffectReady`. Private
`resumeVerifiedSameKeyRetry` jointly consumes that exact parameterized Unknown session, the full-lineage
proof, and retained package and feeds its successor Ready session plus reconstructed sealed call only
back into the same core interpreter. There is no public/caller-selected Unknown→Ready conversion. Another
target, call digest, config, secret bundle, effect row, phase, invocation, session, or journal version
cannot cross-pair. This includes crash-after-call-before-ack. Read/listen and
supervised use of already acquired
handles are the only unprepared operations. Adding an open/bind/spawn or raw `IO` escape hatch is not a
valid effect contribution. The retained resource package inseparably carries every receipt/unknown and a
closed lease disposition: either proof that the signed placement ceiling prohibits every
exclusive/mutating effect or the matching live `ServiceGenerationLease ... fence`. The activation and
verified placement derive this requirement before Acquire; callers cannot choose the no-lease branch.
Serve accepts only a finalized registry row proved within that same ceiling, so a mutating program cannot
appear on the no-lease branch. Only the live-lease branch can mint
`PreparedServiceEffect`; neither receipts nor lease can be projected away before Drain.

Selection rejection, completion, typed failure, catchable shutdown, and caught interruption all produce
one opaque `RoleAdvance ... ServePhase DrainPhase ServiceDispatchResult`; no `Either` or callback may
drop receipts. Its sole eliminator yields the result only with the unique Drain cursor and retained
receipt/lease package, still inside the core-owned runner. Drain attempts every independent
release/reprobe despite individual failures and yields
`RoleAdvance ... DrainPhase ExitPhase DrainResult`; only its eliminator exposes the aggregate result with
the Exit cursor. Uncatchable process death uses durable admission/receipt/lease/journal recovery rather
than an impossible in-process guarantee. Rolling revisions/instances may overlap for non-exclusive
service work; cross-instance replay fails, and exclusive/mutating work retains a
`ServiceGenerationLease` through Drain. The admission opener independently enumerates a complete
`VerifiedOldRoleInstanceManifest` for one stable placement; every member retains its full old
plan/spec/binary/config/secret/role-plan/effect-ceiling and local
plan/config/revision/instance/invocation/journal/resource lineage. Recovery folds that exact set and
rejects omitted, duplicate, extra, or substituted records before yielding
one `SettledRoleLifecycleRecovery` whose contained `RecoveredRoleInstanceSet` and
`RoleRecoveryClearance` both retain the full new
plan/spec/binary/config/secret/service/role-plan/effect lineage. Recovery Unknown carries the same
lineage and can only enter `resumeRoleLifecycleRecoveryUnknown`, which re-probes the stable key into
another exhaustive advance. Every member requires authoritative `VerifiedRoleInstanceNonLive`, which
the final CAS revalidates. Non-exclusive live overlap remains legal and outside recovery; only
authoritatively non-live incomplete/unclean members are settled. A live exclusive predecessor yields
Busy/Conflict or liveness Unknown without recovery authority, and an exclusive successor waits for all
non-live predecessors. The no-exclusive branch requires
`VerifiedNoServiceLeaseTransfer` for the complete set. Otherwise transfer publishes no successor lease
until the typed `ServiceLeaseTransferBarrier ... predecessorFenceSet newFence transferVersion` proves
an atomic backend fence has excluded every old mutation, or retained nontransferable locks held across
each call until all prepared/in-flight old attempts settled or became authoritatively fenced. A backend
with neither primitive is `Unsupported`. Only `resumeRoleLifecycleAdmission` may consume the single
settled package, atomically close the old invocations, and reserve the new
admission. Lost acknowledgment resumes the same key. After that barrier, later old prepares fail; Drain
releases the lease only after dependent cleanup settles.

Core need not impose a universal service field: the project-owned field schema and `RoleCodec` define
how a full validated config projects each role wire and how a verified local wire yields its typed
request/consumer tags. Construction-time/property tests validate that semantic mapping. The generative
eliminator binds the hidden row, local wire, request, and role parameters together; callers never choose
`fields` independently. Core cannot infer that a misleading project tag is semantically accurate, so
the generic guarantee is relative to the project's declared schema; the demo's field classification has
compile-fail/projection tests. The guarantee is not that core can inspect an arbitrary function and
prove it “non-constant”; the arbitrary function no longer exists. Missing-config diagnostics name the
exact owning parent/controller projection, or `service init` together with the required authorized
manifest installer; they never imply that a descriptive file alone authorizes `service run` and never
recommend root `project init`. The registry may be explicitly
empty; then no `SelectedService` exists and the fixed command fails before a handler.

`project up` and `service` **compose, they do not overlap**: the chain's `deploy-chart` step deploys the
pod whose entrypoint is `service run`, and the pod's config arrives as a **ConfigMap that overrides the
image's baked container `<project>.dhall`** (§ X). The project may render that ConfigMap dynamically from
the validated parent-derived role-wire projection and fingerprint the exact narrowed mounted bytes on
the pod template so a config change rolls the workload; a hand-maintained chart copy is not a second
config authority. The child verifies that wire and creates the request locally.
`project up` *deploys* the service; `service run` *is*
the service. A project's long-running workload is therefore a service variant reached through this fixed
command, and a project defines no long-running verb of its own: a web server is `service run` on its `Web`
variant, and an image-bridging step is a node of the build chain.

### BB. Generic Project Model and No Core Defaults

**Owning phase**: [the Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
`hostbootstrap-core` is a **library of pure shapes plus the lift algebra and the harness**; it owns **no
default config values and no fixed config type**. The reusable substrate is the compositional lift
(`BinaryContext`, `childContext`, the `Step`/frame graph, `ProviderKind`) and the test engine — **not** the
config record. This contract is owned by the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md), which
introduces the generic `ProjectSpec` directly; core defines no concrete config type at any point.

The generic, scope-indexed `cfg`/`tcfg` substrate and typed test-matrix foundation are implemented:
`TestCfg` projects opaque validated `CaseId`/`VariantId` registries and pure drafts, while the single
restricted `psAssemble` constructs either `cfg (Production projectId)` or
`cfg (Harness projectId runId)` from a closed scope-specific request. Production and Harness install
separate mapped `ProjectCodec`s; Production has no plaintext-secret wire branch, and Harness plaintext
requires the exact generative run authority. Generated-config cleanup is still byte-conditional, and
the demo still resolves its live cluster with Production/`.data`. The
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md)
owns cross-process child admission, the
[test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns Harness lifecycle
isolation, and the
[`test`-and-`context`-command-semantics phase](phase-20-test-and-context-commands.md) owns the command entry.
Until those phase gates close, the typed configuration foundation is not downstream handoff or isolation
evidence.

In target type spellings below, `Production` is shorthand only for the project-indexed
`Production projectId`, and `Harness runId` for `Harness projectId runId`. The full index is required at
API boundaries: installed project identity must be generative before plan or run identity.

- **No core defaults.** `defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` and the
  `initAction` flag defaults are removed. `psAssemble` is the single project-owned default-bearing
  function for Production init and per-variant Harness assembly. `psTestInit` remains a separate
  test-config constructor because it builds `tcfg`, not project `cfg`; demo Web/Accelerator parameters
  are explicit assembled fields and service projection invents no fallback values.
- **Explicit, fail-fast configs.** Every `<project>.dhall` and `<project>.test.dhall` field is mandatory; a missing
  field fails the strict Dhall decode **before any side effect** (no `//`-merge, no `fromMaybe` in decode).
- **Generic over the config type and scope.** The extension contract is
  `ProjectSpec cfg tcfg`, parameterized over a project's config family
  `cfg :: Type -> Type` (its `<project>.dhall`) and test-config type `tcfg` (its
  `<project>.test.dhall`). `ProjectCfg cfg` exposes only read-only `cfgContext` and installs
  identity-generative Production and authority-closed Harness `ProjectCodec`s; the raw `cfgWithContext`
  updater is removed. `ProjectSpec` cannot select `projectId`: `runHostBootstrapCLI` admits the actual
  executable identity once, and only its rank-2 continuation instantiates the codec, scope-polymorphic
  `ServiceRegistry cfg`, assembler, plan, commands, and Harness runs. Every plan fragment receives
  `CanonicalProjectRoot scope rootId` beside `cfg scope`; independently scoped pairs are unrepresentable.
  Canonical render/hash/strict re-decode through the scope-correct
  `ProjectCodec`/`ValidatedConfig` transition mints root-local config identity. No command-specific
  string selector exists: finalized project validation projects a role-specific wire; matching
  `RoleCodec` verification jointly mints
  the opaque `ValidatedServiceRequest specDigest configId secretDigest fields service`. Dispatch consumes it with exact
  placement, current service command authority, and the finalized typed registry into
  `SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  fields`. Core owns the
  consumer-indexed field/filter and
  closed-program boundary but none of the project field names/value types; the handler receives only
  `RoleParams specDigest configId secretDigest fields service`, never the full `cfg` or arbitrary `IO`. The selected package's
  effect-indexed proof must match the handler program, so an unauthorized effect row cannot be
  represented.
  `ProjectConfig` / `Resources` / `DeployConfig` become the demo's concrete instance, not core types.
- **The resource budget is a provider concern (refines § O).** Budget/provider-cordoning is a field of a
  project's `cfg` carried by a provider lift, **not** a universal config field. A secrets-strict,
  RKE2/EKS-sized consumer carries no provider budget at all. For a project that does declare one, § O's
  sole admitted `EffectiveBudget` is the provider-effective wall: a per-VM wall on Lima/Incus, or an
  exclusively owned shared utility-VM wall plus a per-distro VHDX slice on WSL2. An incompatible
  concurrent WSL declaration is `Conflict`; it cannot overwrite the global wall.
- **DRY, scope-aware assembly.** A single project-owned
  `psAssemble :: AssemblyRequest scope tcfg -> ConfigAssembly scope (cfg scope)` is the only
  default-bearing function. `ConfigAssembly` permits only declared config/secret reads and exposes no
  general `IO`, `MonadIO`, or lifecycle/backend mutation; assembly therefore cannot hide an effect
  before the plan snapshot/journal/permit exists.
  `AssemblyRequest` is the sole closed scope-input GADT: its Production constructor carries only
  independently verified project-config values, while its Harness constructor carries the exact
  `HarnessAuthority projectId runId` and one opaque validated `VariantDraft` that already contains its
  stable variant identity and typed override payload.
  Identity and variant occur once, so two inputs cannot disagree. It has no generic role/class list,
  output path, overwrite flag, or service/test writer policy; those belong to the command-specific
  writers.
  `project init` and per-variant harness assembly are projections of that same assembler. A pure
  `psTestMatrix :: tcfg -> Either TestConfigError (TestMatrix VariantDraft)` validates stable reporting
  IDs/references before effects; for each distinct variant draft the engine opens a **fresh** generative
  harness `runId`/lease, then calls `psAssemble (HarnessAssembly authority draft)`. The exact
  `HarnessAuthority`, scope-correct `ProjectCodec`, and assembled value then enter
  `withAssembledHarnessConfig`, whose canonical render/hash/strict re-decode jointly yields the
  root-local verified wire identity and `ValidatedConfig` required by the first `withProjectPlan`.
  No function converts
  `cfg (Production projectId)` to `cfg (Harness projectId runId)`, and duplicating a second defaults
  builder is not compliant.
  `psTestInit :: InitArgs -> tcfg` builds a complete, valid `<project>.test.dhall` from the shared init
  argument record; current `test init` supplies `defaultInitArgs`. Replacement is not encoded in that
  config value: the command separately obtains the opaque codec-bound `TestConfigWrite`, whose installer
  refuses an existing sibling unless the parser supplied the explicit replacement policy.
- **`<project>.test.dhall` is a thin override and the harness generates the run's config (closes the § Z drift).**
  `test run` reads `<project>.test.dhall`, refuses if a `<project>.dhall` exists or a production cluster is running,
  builds typed config variants through the scope-aware restricted assembler (which can use declared
  readers for inputs such as `test-secrets.dhall`), writes each variant's `<project>.dhall`, retains that
  variant's exact Harness-scoped `ProjectPlan`, and calls the common forward/reverse interpreter directly
  around assertion-only `TestSuite` code. It never creates a top-level subprocess lifecycle. The
  projection returns an
  opaque total `TestMatrix`: non-empty unique case/variant registries, exactly one non-empty variant row
  for every registered Haskell case, known unique references, and no orphan variant. Sharing a variant
  and assigning multiple variants are explicit relations. `VariantId` is stable reporting identity, not
  ownership identity: each distinct config variant receives a fresh harness `runId`, cluster/data root,
  and exact plan/config lease. Cases sharing that variant share its one stack. No later variant begins
  until the prior run's lease is closed or reported as requiring operator recovery. Cleanup deletes only a generated config
  whose verified ownership record and bytes still match, and deletes only a self-created harness data
  root; changed/foreign state is retained and reported. `test init` does **not** require a pre-existing
  `<project>.dhall`.
- **Generic secrets shape.** Core offers `SecretRef scope`, which projects embed in
  `cfg scope`; raw `Text` cannot occupy a secret-ref field and core never resolves secrets. The reflected
  Production wire schema has only `Vault | TransitKey | Prompt`, while `TestPlaintext` requires opaque
  `HarnessConfigAuthority projectId runId` and can
  produce only `SecretRef (Harness projectId runId)`. Generative authority is never serialized: the harness Dhall
  schema decodes through an untrusted Harness wire. At the root, exact authority plus canonical
  render/hash/strict re-decode through the scope-correct opaque `ProjectCodec` jointly mint generic
  `VerifiedConfigWire` and `ValidatedConfig`; the restricted assembler may read a declared
  project-specific `test-secrets.dhall` input. At a later recursive child boundary, grant verification
  yields transport-only `VerifiedHandoff (Harness projectId runId) brokerGeneration`; exact-byte decoding
  yields `VerifiedConfigWire (Harness projectId runId) childConfigDigest childConfigId`, child-local
  `HarnessConfigAuthority projectId runId`, and
  `ValidatedConfig (Harness projectId runId) specDigest childConfigId
  (ProjectConfig (Harness projectId runId))` in the same rank-2
  continuation. `Config.Schema.withVerifiedConfigHandoff` first checks the signed payload kind,
  wire/config/specification digests, verb, and closed phase and yields the fully indexed
  `VerifiedConfigHandoff`. That proof, the same wire/config, and non-empty plan draft enter
  `ProjectPlan.Construct.withChildProjectPlan`; only that rank-2 gate yields a fresh child `ProjectPlan`,
  `PlanDigestBinding`, and exact `ChildPlanAuthority` for the Cabal-private authenticated child-entry
  boundary. That boundary validates the complete signed binding/token and exact cataloged
  plan/config/frame/node coordinates, then admits only a storeless frame executor for the root-selected
  Up/Execute grant. It derives no child `ProtectedStore`, acquisition journal, lifecycle cursor, or command
  authority; those durable values remain with the root coordinator.
  Raw wire cannot be promoted merely because a caller
  has run authority, and the child
  does not need the root's non-serializable authority before verification. A pointer-only harness config
  is still Harness-indexed.
  Production decoders and commands have no plaintext constructor, harness-wire promotion, or unscoped
  record update. the Dhall-configuration-and-project-model phase implements the root-local construction/codec boundary; the child handoff and
  plan transitions remain owned by their downstream lifecycle phases.
- **A project field that flows to the workload is a field of the project's OWN `cfg`.** A value the
  workload reads and renders (the demo's `message` the web service reads/renders) is a field of the demo's
  own `cfg`, never a core-owned field and never a generic extra slot — core owns no project-specific field.
- **A suite may declare more than one test config.** The demo's two clusters are two config variants; the
  target Harness interpreter brings each retained plan up, runs assertions, and reverses it in turn, with
  the in-frame assertion parameterized by the config it set (`EXPECTED_MESSAGE`).

The canonical design home is
[generic_project_model](../documents/architecture/generic_project_model.md); the secrets seam is
[secrets.md](../documents/engineering/secrets.md). § P (fixed command surface), § W (single
representation / Harness consumes the exact plan), § X (binary context), § Y (the lifecycle command), and § Z (the
chain-driven test surface) are unchanged in shape — this section makes the **types** they thread generic
and removes core-owned defaults.

### CC. Readiness-Gated Lifecycle Steps and Legible Failure

**Owning phase**: [the canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md)
Every lifecycle step that **mutates a frame** — provisions it, stages into it, installs into it, or
reconciles its state — runs only behind a proof that the dependency it needs is ready. That proof is a
**sealed, lifecycle-plan- and resource-instance-bound
`Ready scope planId id resource dependency` witness**
(`HostBootstrap.Readiness`): the constructor is absent from every exposed library module, including any
nominal `Internal` module. A hidden `Probe resource dependency` fixes the evidence kind it can mint, so
the caller cannot choose a result phantom, and only its validated polling transition can return
`Ready scope planId id resource dependency`. The generative `planId` prevents values from distinct Production
plans from mixing. Tests exercise that transition through injected probes; they do not receive a public
constructor.

A mutating transition first takes an opaque descriptor binding
`scope`/`planId`, target identity/type, dependency identity/type, and predecessor/successor phases. Only validated
`ProjectPlan scope specDigest planId configId cfg` construction—using
`ValidatedConfig scope specDigest configId (cfg scope)`—can mint that descriptor after proving the topology
relation. Its internal dependency-snapshot traversal looks up the exact managed resources and runs the
plan-owned probes for the complete ordered zero/one/many edge set, then jointly seals those fresh
observations and the verified backend call into `OperationPreconditionSet`. Callers cannot provide a
retained witness or select/omit a member. The private zero-dependency branch is available only for operations whose
descriptor declares none. Thus
"act before the dependency is ready", choose an unrelated
dependency, or mix production and harness values is a **type error**, not a convention. The witness is
generative and bound to the exact resource identity observed; readiness for one VM, daemon, mount,
registry, or generation cannot authorize another resource with the same phantom tag. As
`Ready DockerDaemon` already gates the in-VM project-image build and `Ready RegistryServing` already gates
the image push, so must the durable-share mount gate the alias step (§ DD).

The canonical-quantities-and-reconcile-results phase foundation now removes `HostBootstrap.Readiness.Internal`, keeps every readiness constructor
private, validates `Micros` and `PollPolicy`, and fixes each `BackendProbeKey` to a closed planned-resource
family. A plan-indexed probe can be constructed only with the matching `PlannedResource` and positive
generation, phase, and observation versions; tests drive the real polling transition rather than minting
test witnesses. `ObservedReady` remains only as explicitly non-authorizing compatibility evidence for
call paths that have not yet adopted the plan-owned operation-preparation algebra. The downstream
provider/interpreter phases named in § O own that migration; they must not treat compatibility evidence
as mutation authority.

The opaque witness retains the observed backend generation, resource phase, and journal version, but it
is only a precondition-set input. Immediately before preparing an operation, the interpreter consumes that
set, atomically revalidates those facts, reruns every plan-owned dependency/target probe, and obtains any
conditional backend versions. Only success jointly returns the exact
`PreparedOperation`/`PreparedPreconditions` pair the adapter accepts; no retained witness, handle, edge,
or raw prerequisite bundle is an adapter argument. Replacement is `Conflict`; same-identity loss of
readiness is `Failure ... ReprobeBeforeRetry`; lack of a conditional backend primitive is
`Unsupported`. A post-prepare conditional mismatch enters the typed unknown/recovery graph rather than
assuming readiness. Retaining an old Haskell value cannot bypass those gates, and the type does not claim
an external service stays ready forever.

A probe is **retrying and total**: every observation outcome is represented as typed data. Its result
distinguishes ready, transiently not ready, unavailable/not-applicable, ownership conflict, and
deterministic failure; an exception, Boolean, or bare exit code is never used as the state model. Transient
conditions are retried within an opaque `PollPolicy`; smart constructors require positive attempts and a
non-negative bounded delay, compute total duration with overflow-safe arithmetic, and reject zero,
negative-equivalent, overflowed, or over-limit policies before polling. Deterministic failures and
conflicts stop immediately with structured details. A one-shot in-guest step that runs a compound `set -eu` script with
no witness and no retry is a **defect**: it races the readiness it assumes and hides the reason it failed.

Guest probes stay **trivial** so they survive the host→guest command path unchanged. On Windows the
`wsl -d <distro> -- bash -lc <script>` invocation crosses PowerShell's native-argument quoting, so a probe
is a single simple command (`docker info >/dev/null 2>&1`, `test -d <path>`, `readlink <path>`) — never a
multi-statement script with nested `"$(… "…")"` quoting. Retry and branching live in Haskell (the
`awaitReady` loop plus a pure classifier over the probe output), not in an inline shell loop.

**Failure is legible.** A bring-up failure never collapses to a message-less `ExitFailure 1`. Lifecycle
failures are a structured exception (`LifecycleFailure`, the peer of the `SafetyRefusal` round-trip, § Z)
that carries the cause across the subprocess and harness boundary, and a runner that captures a child's
output **streams it, then dies with it** rather than folding it into a stderr the harness unwinds. The test
report card renders the carried message (`displayException`), so a failed variant states *why*. The
canonical homes are [readiness](../documents/architecture/readiness.md) and
[harness_workflow](../documents/architecture/harness_workflow.md).

### DD. The Durable-Share Primitive

**Owning phase**: [the host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md)
A host directory reaches a guest through **one** per-substrate share primitive on `SubstrateProvider` /
`HostPathShare`, modeled as pure data and interpreted generically (the lifecycle peer of the launch/cordon
effect lists, § U). It has three parts, and the substrates differ only in which parts they need:

- a **host-side reconcile** (`ShareReconcile`, the optional field shaped like the cordon-reconcile of § O) —
  Incus attaches a disk device post-create; Lima declares the mount at instance create; WSL2 needs none
  (drvfs already exposes the drive and the path rewrite already exists);
- a **guest-side alias reconcile** — where a provider guest is present, its stable Docker-visible path is
  a symlink to the share, modeled as a pure `AliasState`
  (`AliasAbsent | AliasLinkedCorrectly | AliasLinkedElsewhere | AliasOccupied`) with a total classifier
  and a create/remove planner. The same classifier serves every provider guest. Direct Linux has no
  guest boundary and supplies the canonical host projection directly, so it must not create or consume
  this alias;
- a **mount-readiness** probe (§ CC) — the guest share is proven present and writable before the alias is
  scheduled, and the alias transition revalidates the same share identity immediately before mutation.
  The capability prevents logical out-of-order use; it does not pretend an external actor cannot unmount
  the share between unrelated system calls.

The target makes every step of the share readiness-/identity-gated (§ CC) and legible. The current VM
call graph still threads the non-authorizing `ObservedReady` compatibility value; it can no longer forge
plan-indexed `Ready` authority, but the provider adapter has not yet migrated to the prepared-operation
pair. Canonical direct-host root admission and its same-root host bind are implemented; the remaining
provider boundary projections stay open. The primitive is what makes a durable root host-backed rather than frame-local; until a real
destroy→up→read run validates it end to end, no governed document describes host-durable `.data` as
validated (§ C, § J). The canonical home is
[durable_state](../documents/architecture/durable_state.md).

### EE. Opaque Capabilities and Phase-Indexed Lifecycle State

**Owning phase**: [the installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
Capabilities are authority, not descriptive labels. `Capability`, readiness witnesses, ownership
witnesses, adoption authority, and lifecycle-state tokens expose no constructors or record updates from a
public or `Internal` library module. They are minted only by validated transitions, narrowed when crossing
a frame, and consumed by the operation they authorize. Tests use injected interpreters and typed fixture
builders; exporting a constructor “for tests” defeats the boundary.

Ordinary Haskell values are not linear, so “consumed” is also an interpreter invariant: each transition
checks the current generation/lease and journals the successor state or one-time nonce consumption.
Hidden constructors and indices prevent construction and wrong-resource/scope mixing; the journal
rejects stale replay by cooperating interpreters. It does **not** by itself exclude an external actor in
the check/effect window.

Closing that window is a **protocol** requirement, not a platform-primitive requirement. Before mutating
a named VM, cluster, generated config, data root, port, host daemon, global provider setting, or durable
alias, a backend satisfies all four clauses of **Locked-Origin Identity Ownership**:

1. **Exclusive entry.** A kernel-held lock the OS releases on process death is acquired before any
   mutation and retained across the whole observe/mutate/settle bracket.
2. **Durable origin record before the first write.** The exact original bytes *or* an explicit
   absence marker are recorded durably, keyed by a generative nonce, before the first mutating call.
3. **Identity binding, never pathname.** Every operation after the first binds to the object's stable
   kernel identity — the `(volumeOrDevice, fileIndexOrInode)` pair — not to the name it was reached by.
4. **Conditional release.** Restore and delete re-observe that identity and act only on an exact match;
   any other observation is a structured `Conflict` and the object is left untouched.

The guarantee this buys, stated exactly: it **excludes** crash/retry and concurrent cooperating runs, and
it **detects** rather than silently overwrites foreign mutation. It does **not** exclude a hostile
same-privilege process. No substrate supplies that exclusion, so no plan may claim it. A backend that
cannot satisfy all four clauses — an unsupported filesystem, an unavailable lock, an identity the
platform will not report — reports `Unsupported` and mints no receipt. A pathname compare, content hash,
or immediate re-probe substitutes for none of the four. No plan may claim compile-time exactly-once
effects from phantom types alone.

**One implementation, not one per object.** The clauses are a single transaction — observe, record the
origin, mutate, bind the identity, release conditionally — and it is written once, in Haskell, over one
closed platform seam. What differs between a POSIX host, a Windows host, and a frame reached through a
provider command is the *primitive* each supplies, which is a row of the frame table (§ LL); it is never a
second implementation of a clause, and it is never an interpreter program (§ KK). The clause order is a
property of the types rather than of review: a mutation consumes the recorded origin, and a release
consumes the bound identity, so performing either out of order has no term.

The direct-Colima realization applies these clauses to one 128-bit plan/lifecycle namespace authority and its
socket-safe local profile. A reusable profile-global lock is synchronization-only: the ownership row opens
its exact no-follow object and holds the kernel lock on the retained descriptor for the whole bracket; no
external `flock`/`lockf` frontend participates. Before any named namespace exists, a self-bound nonce origin records
absence and the exact acquisition invocation. Descriptor-relative, parent-fsynced transitions then bind the
isolated Colima home, isolated Docker config, fixed root/data wall, stable machine and context, every required
Lima/Colima artifact identity, and a complete directory-chain digest. The sole `prepared` pre-call state does
not authorize adoption after an outcome-unknown start; only a matching durable `managed` stage can recover
authority. Live Docker reacquires the identical lock/record/namespaces and revalidates that complete binding.
Cleanup carries a distinct journal invocation, durably enters `releasing` before the
`colima delete --force --data` invocation, and conditionally proves profile/data/context absence before
removing only manifest-listed namespace objects and retaining a released tombstone for replay. Missing
primitives or unprovable identities are
`Unsupported`; foreign profiles, copied records, replacements, partial foreign stages, and invocation drift
are `Conflict` and remain untouched. This boundary is owned by the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md), which
adopts the ownership seam for it; Production recursive and demo consumption remain downstream.

The canonical statement of this contract, with its per-substrate realization, is
[ownership_invariant](../documents/architecture/ownership_invariant.md).

The lifecycle interpreter carries lifecycle scope, resource identity, ownership, and phase indices in
its state type: `ResourceHandle scope planId id resource ownership phase`. `Unclassified`, `Managed`,
and `Unmanaged` are distinct ownership states; provisioned, ready, staged, built, running, stopped, and
destroyed are distinct phases (the exact names may vary). A transition accepts only the predecessor
scope/plan/resource/ownership/phase it can legally follow and returns the successor state plus
capabilities retaining that same scope and plan.
Recursive descent and teardown use these values rather than reconstructing authority from a
`BinaryContext`, a file path, a process check, or a Boolean. A context may describe requested placement,
but only a validated local transition can mint authority to mutate it.

Every mutating reconciler returns `Either ReconcileError ReconcileResult`. A `ManagedResult` carries a
`ResourceHandle scope planId id resource Managed phase`, the matching
`OwnershipReceipt scope planId id resource`, and an indexed outcome whose non-authorizing view is
`Changed (Created | Repaired | Adopted)` or `Unchanged`. Operation-specific hidden evidence fixes legal
from/to/outcome combinations: adoption consumes matching authority, and `Unchanged` requires verified
prior committed ownership at the same phase. A `ForeignResult` carries only a
`ResourceHandle scope planId id resource Unmanaged phase` and a foreign observation. The latter type
cannot be passed to mutation, stop, or destroy. The only `Unmanaged` → `Managed` transition requires
an opaque `VerifiedForeignOrigin scope planId id resource generation observationVersion` that jointly
binds that handle/observation plus matching
`AdoptionAuthority scope planId id resource generation observationVersion operationKey`, and reports
`Changed Adopted`; ordinary reconciliation cannot
silently adopt. Idempotence never degrades a resource validated as ours into an unmanaged observation.
`ReconcileError` distinguishes `Conflict`, `SafetyRefusal`, `Unsupported`, and `Failure`. A conflict
carries structured expected/observed identity and an
operator-safe remedy; a safety refusal records why an otherwise legal transition was declined; a failure
records the attempted operation, cause, and `RecoveryDisposition`. Observation is total (§ CC), so absence, not-ready,
unsupported, foreign ownership, and probe failure cannot collapse into one branch. A conflict or safety
refusal never triggers cleanup of the refused resource.

Before a run mutates a named VM, cluster, generated config, data root, port, host daemon, or global
provider setting, it must hold all four clauses above for that backend. A backend that cannot supply
them returns `Unsupported`; a pathname compare or content hash substitutes for none of them. The
resulting ownership receipt records the
exact plan/resource identity and generation and is required by recursive teardown. Cleanup is therefore a typed
ownership operation: compatible unowned state remains `ForeignResult`, incompatible identity is
`Conflict`, a policy refusal remains `SafetyRefusal`, and an unsatisfiable clause is `Unsupported`.
Owned partial state is unwound in reverse lifecycle order and all cleanup failures are aggregated.

Because an external effect and the ownership record cannot share one atomic transaction, durable state
is an untrusted, generative-identity-free `PersistedJournalRecord`. Protected-store verification yields
`VerifiedJournalRecord scope planDigest frameKey resourceKey generation operation operationKey
recordVersion phase`;
matching plan-digest, frame/resource-identity, and operation bindings yield the local private
`JournalEntry scope planId frame id generation resource operation operationKey recordVersion phase`.
Its legal graph is:
`IntentRecorded → ReservationOutcomeUnknown`; reservation unknown branches to `ReservationAbsent`
(same-generation reservation retry), `Reserved`, `ObservedManaged` (reserve-is-create), or terminal
`ObservedForeign`; `Reserved → EffectOutcomeUnknown`; effect unknown branches to `EffectAbsent`
(same-generation effect retry), `ObservedManaged`, or terminal `ObservedForeign`; and **only**
`ObservedManaged → Committed`. Cleanup is `Committed → TeardownOutcomeUnknown → Released`, with an
observed same identity returning explicitly to `Committed` for retry and replacement becoming terminal
foreign state. A released ephemeral generation can start a later acquisition only from verified absence
plus an opaque
`FreshGeneration scope planDigest planId frame frameKey resourceKey id resource oldOperation
oldOperationKey oldGeneration newAcquireOperationKey newGeneration`; it binds the exact local
identity/operation evidence and old ordinary/adoption release to a distinct new `AcquireOperation` key.
The token is only eligibility: its sole consumer creates a
released-reacquisition origin, and `registerOperationIntent` revalidates/consumes the exact protected
release/absence version while atomically writing the new generation and session membership. First
acquisition instead requires the sole protected no-prior-generation proof. An unknown or foreign
generation has no rollover edge. Stable scope/plan
digest/frame/resource/generation/operation key—not `planId`, resource
`id`, or handles—are persisted before a mutating backend call; each unknown state is durable before its
external operation. Hidden, phase-/operation-indexed constructors expose no absent/foreign-to-commit edge,
wrong-operation substitution, or unproved new-generation retry.

Adoption is a separate journal transaction:
`AdoptionIntentRecorded → AdoptionOutcomeUnknown`; total reprobe then records
`AdoptionObservedManaged`, `AdoptionObservedAbsent`, or terminal `AdoptionObservedForeign`/refusal.
Only `AdoptionObservedManaged → AdoptionCommitted` can mint adopted ownership. Authoritative absence
permits an explicit retry under the **same** adoption operation key only after `OldPermitsFenced` proves
that a delayed transfer cannot land; without that proof it is `Unsupported`/operator resolution, not a
new attempt. Foreign observation and policy refusal are terminal. Cleanup is
`AdoptionCommitted → AdoptionTeardownOutcomeUnknown → AdoptionReleased`, and there is no adoption edge
from an ordinary `ObservedForeign` acquisition entry.
Both ordinary and adoption release records can authorize a later exact-resource `FreshGeneration`
rollover after verified absence; either must pass through the sole released-reacquisition origin and
atomic intent/session registration to begin the ordinary acquisition graph under its distinct new
acquisition key, while explicit re-adoption would instead require new adoption authority and intent.
Neither unknown phase can roll over.
Receipt rebinding requires raw persisted receipt verification, exact plan/frame/resource/operation
bindings, and a `ReceiptCommitProof` admitting only the matching ordinary `Committed` acquisition or
matching `AdoptionCommitted` transfer. A phase transition, teardown entry, same generation under another
resource/operation, or foreign observation cannot mint a receipt. Operational failures carry their
recovery disposition and never erase journal state.

Repairs and non-release phase changes are separately journaled effects. A repair uses
`RepairIntentRecorded → RepairEffectOutcomeUnknown` before its backend call, then total reprobe observes
exactly one of `RepairObservedOriginal`, `RepairObservedTarget`, `RepairObservedAbsent`,
`RepairObservedUnexpected`, or `RepairObservedForeign`. The original-phase branch may retry only the
same operation key after old-permit fencing; **only**
`RepairObservedTarget → RepairCommitted` commits. Absent, unexpected third phase, and foreign
replacement are terminal/operator-resolution branches and have no commit edge.

Boot, stop, and destroy-reachability use an operation indexed by exact `resource/from/to` and the
analogous total graph:
`PhaseIntentRecorded → PhaseEffectOutcomeUnknown → PhaseObservedFrom | PhaseObservedTo |
PhaseObservedAbsent | PhaseObservedUnexpected | PhaseObservedForeign`. The from-phase branch may retry
only the same operation key after old-permit fencing; **only**
`PhaseObservedTo → PhaseCommitted` commits. Absent, unexpected third phase, and foreign replacement are
terminal/operator-resolution branches. Both effect families preserve the existing receipt, and neither
can enter acquisition/adoption commit, teardown release, or `FreshGeneration`. Kill recovery reprobes
instead of blindly replaying those effects.

Execution profile is also indexed typed authority. Fresh construction uses
`LifecycleProfile (Production projectId)` or `LifecycleProfile (Harness projectId runId)`. Configful
abandoned Production `ProjectUp` uses the distinct
`RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration`;
constructors are opaque to consumers. The
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)'s
non-config authority layer verifies executable-bound installed identity and exact-store
`VerifiedOsPrincipal`, then combines them with the fresh epoch and exact verb before minting
`RootInvocationAuthority (Production projectId) brokerGeneration verb`; it does not mint a profile. The
[lifecycle-modes-and-run-leases phase](phase-9-lifecycle-modes-and-run-leases.md)'s rank-2 Production and
Harness mode transaction creates the fresh broker generation and exclusive `UnboundRunLease`; the
Harness opener generates the run
identity and yields only the matching existential
`HarnessRootAuthority projectId runId brokerGeneration`. The public root brackets are composite: they
invoke the lower authority kernel inside the protected mode/lease transaction without exposing an
intermediate state. Only the
[lifecycle-modes-and-run-leases phase](phase-9-lifecycle-modes-and-run-leases.md)'s fresh profile openers
can combine the exact root scope/authority,
active mode, and still-unbound lease into the matching `LifecycleProfile`. The opaque profile retains the
opening lease's exact installed-project name, protected-store identity, and broker epoch; fresh
`ProjectPlan` admission carries those values privately so the effectful snapshot leaf can reject a
cross-store pairing even when project text and numeric epochs coincide. Phase 12.7–12.20
provide plan admission, stable snapshot bytes, pure `PlanDigestBinding` verification, the indexed bound
snapshot plus ordered fresh persistence/binding, read-only admission of an existing Production snapshot,
pure refinement of its exact indexed Open package into the recovered Production profile, safe restart
config/specification refinement, and fixed-identity recovered plan reconstruction.

The implemented `withPersistedPlanSnapshot` first uses one protected entry to revalidate the unbound lease,
store and flush the private indexed snapshot, and read it back under its exact bytes/digest. After that
entry closes, it compare-and-swaps the separate lease record through the existing fresh-only
`bindRunLease`. Snapshot durability and lease binding are ordered durable transitions, **not** one atomic
multi-record transaction. A crash between them leaves a classified persisted-snapshot/unbound-lease stage
that recovery may resume or refuse; only full completion yields the matching bound snapshot, binding, and
lease evidence.

Existing-snapshot admission through the implemented `withBoundPlanSnapshot` starts from only the protected
store and installed Production identity. In one protected-record-read-only entry it requires the existing
authority binding, exact currently allocated broker generation, Production mode and bound-lease epoch,
canonical snapshot bytes and content-derived digest, and durable invocation disposition. A terminal
acknowledgment is routed after that entry closes to a close-key-only callback and generates no plan
identity; only a verified Open invocation generates the sole local `planId`. The fully indexed
`BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration`, recovered Production
profile, and plan reconstruction retain that identity; neither the recovery-profile opener nor
reconstruction quantifies or mints a second `planId`. The implemented pure recovered-profile refinement
requires the exact Production `ProjectUp` root, active mode, existing-bound lease, verified/bound snapshot
and binding, and that recovery value. It revalidates the retained project, store, Production run, stable
identities and bytes, broker epoch, and binding origin, then yields only the correspondingly indexed
recovered profile. It opens no protected-store entry or one-use slot and cannot inhabit Harness or teardown
scope. On restart, an independently repeated finalization retains the same stable specification text under
a distinct local phantom. The implemented hidden recovery token is issued only after exact profile/finalized
codec digest agreement and independently checks the abstract validated config's retained specification. The
public input bridge preserves the config's `configId`, canonical digest, and value while regenerating drafts
from the finalized builder. Fixed-plan reconstruction then requires exact root-bound canonical bytes/digest,
origin, verified/bound snapshot, and binding agreement before yielding the existing-admission `planId`; it
opens no journal, cursor, migration, fence, or effect authority. Production dispatch consumes that one
identity through dry rendering or snapshot persistence and the hidden root-Up `LifecycleEntry`; the entry
alone derives journal/cursor/authorization and supplies the lower Chain interpreter. Reverse verbs derive
current-frame work from that exact plan without minting teardown command authority.
Phase 12 owns the implemented exact local current-frame `project up` authority substrate; the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) alone composes it with
operator/descent evidence and recursive traversal. Both profiles contend on one project-wide
`ProjectModeLease projectId mode brokerGeneration` record. Production retains its mode across `down`;
Harness acquisition rechecks its derived
preconditions in the same compare-and-swap, and Harness mode is released only after terminal close.
`bindRunLease` is the fresh-only effectful protected compare-and-swap: it verifies the exact retained
unbound record and protected snapshot, then produces
`BoundRunLease scope specDigest planDigest brokerGeneration` before any `PreparedOperation`. An
already-bound record returns `LeaseConflict` and yields no authority. Fresh binding provenance alone can
yield `NormalActiveRecovery`; `withBoundPlanSnapshot` instead yields existing-binding provenance and the
fully indexed `BoundInvocationRecovery` only for its Open callback, so it cannot masquerade as a fresh
binding. Its separate terminal callback receives only the exact persisted `up`/`down` close key. Harness
abandoned-run classification retains its weaker durable observation package-privately: its eliminator
distinguishes exact persisted Closing from Open before the Open branch selects
normal/incomplete/completed revision recovery. No plan-bound acquisition journal is admitted before those
branches are classified. Callers cannot choose the run or broker phantom first, and every
effect-authorizing gate requires the root
authority and lease to carry the same broker generation. Each fresh scope-specific profile opener consumes the
matching lower root authority inside the composite bracket, breaking any
command-authority/lifecycle-validation cycle. The implemented Sprint 12.21 lifecycle boundary opens
`AcquisitionJournal scope planId brokerGeneration` from the exact root, bound lease, bound
snapshot/binding, and plan. It compares the retained evidence first, then rereads the live mode, exact
lease record version/state/bytes, and protected snapshot in one entry in the lease's store before opening
or resuming the dedicated `acquisition.<project>.<run>.<brokerEpoch>` record. The callback runs after that
entry closes. Stable scope, local `planId`, digests, root verb, lease version, and retained source-seed phase stay out
of the key. The strict payload collision-checks the immutable stable binding; `planId` is never
serialized, and the recognized phase is decoded from the row as the initial cursor seed. Fresh state is
`Prepare`, while exact pre-handoff resume preserves the acquisition record version and phase. After
handoff the acquisition row is immutable exact source; only each frame's cursor-row phase is current/mutable.

That plan-bound record is distinct from the Phase-10 `project.<planDigest>` Open/Closing transaction and
from the per-operation attempt/ownership journal. The lower `openProjectJournal`, operation-session, and
prepare APIs are non-authorizing primitives: entering them directly cannot mint plan-bound command authority
or establish the acquisition ordering required by the command route. The no-prepared-work-before-acquisition
guarantee therefore applies at the plan-bound command boundary. Sprint 12.22 supplies the canonical bounded cursor row and its exact
source binding; implemented Sprint 12.23 opens
`LifecycleCursor scope planId frame brokerGeneration verb phase` only from that journal and the matching
`ProjectFrame`. The journal row is the initial seed only until a frame's cursor row exists; thereafter the
strict canonical per-frame row is authoritative. Existential current-phase recovery avoids phase guessing,
and exact resume is no-write. At-most-once compare-and-swap transition reservation is deliberately distinct
from at-least-once callback delivery after unlock. The root-only reservation boundary checks the bound
lease's full retained origin, then revalidates live mode/lease/snapshot, source journal, and exact current row
with the one-use reservation. Its result remains inside the fixed root interpreter; pure frame evidence and
the descriptive lifecycle context authorize nothing and contain no store. `withProjectPlan` consumes the
profile/config/draft, and
`containerPlan` is only a projection of that exact
`ProjectPlan scope specDigest planId configId cfg`; there are no
independent name/path/profile arguments that can disagree. Harness retains its exact Harness-scoped plan
through generated-config ownership and invokes the same fixed root-Up entry interpreter, leaving
`TestSuite` assertion-only. The lifecycle value's raw constructor is confined to a Cabal-private internal
component, and the public facade exposes only the opaque value and its engine eliminators.
Harness config assembly before binding is restricted to `ConfigAssembly`; normal failure closes the
unbound lease only after protected proof that no token, prepared attempt, same-run plan-bound acquisition
record, resource-operation journal, or effect exists, while a crash leaves an explicit unbound incomplete
lease for the recovery sweep.

In-process authority is non-serializable. For recursive child-frame transitions, the independently
authorized root retains the protected `AuthorityBroker`, bound lease, signing key, protected store, root
snapshot, and all durable cursors. Self-invocation uses a private duplex session—never Dhall, `argv`,
environment, durable config, a mounted authority directory, or a general protected-store service. No
recursive API exposes `ProtectedStore`, a raw read/list/compare-and-swap RPC, or a shared authority mount. The
ordinary signed `HandoffBinding` owns only its immediate edge: exact project, specification, payload kind,
scope, protected-store identity, stable root snapshot revision, broker generation, parent/child frames, one
complete-payload digest, verb, closed phase, and token commitment. The additive root-signed
`RootedPayloadBinding` exact-binds those canonical legacy bytes and separately frames its complete-payload and
child-config digest claims. Config signing and verification require the two claims to cover the same exact
bytes. Possession of that signed data or of a neutral `RecoveryChildPackage` admits no recovery field.
`withVerifiedRecoveryChildPackage` alone rerenders and cryptographically reverifies the supplied rooted value
against the exact `VerifiedHandoff` and installed key, decodes the package only from the authenticated payload,
and recomputes the complete-package and extracted child-config digests before exposing either field. Catalog
identity belongs to `RootedPlanCatalog`, while requester path belongs to its rooted request; neither is
smuggled into `HandoffBinding`. Verification yields
only transport-level `VerifiedHandoff scope brokerGeneration`; it chooses no plan, frame, config, verb, or
phase phantom. Exact-byte verification through the scope-correct `ProjectCodec` separately yields
`VerifiedConfigWire scope childConfigDigest childConfigId` and matching `ValidatedConfig` under a fresh local
`childConfigId`.

`Config.Schema.withVerifiedConfigHandoff` is the sole refinement that checks the signed payload kind,
wire/config digest, specification digest, closed `ProjectVerb`, and `Prepare | Execute | Teardown` phase and
then yields fully indexed
`VerifiedConfigHandoff scope planDigest brokerGeneration parentFrame childFrame configId verb phase` inside
a rank-2 continuation. `ProjectPlan.Construct.withChildProjectPlan` consumes that proof, the same wire/config,
and non-empty drafts; verifies the stable plan revision plus signed project/catalog/broker origin; and jointly
yields a fresh local `ProjectPlan`, `PlanDigestBinding`, and opaque fully indexed `ChildPlanAuthority`.
The root constructs a durable `RootedPlanCatalog` from its exact plan and bound package before any child
effect. Each catalog row fixes the requester path, projected config/plan digests, frame and topology prefix,
ordered nodes and dependencies, and exact operation set. A root-owned `RootedFrameSession` selects those
coordinates and drives the per-frame journal/cursor. The Cabal-private child entry combines the verified
handoff, reconstructed target plan, and matching nested context into a storeless `FrameExecutor`; it receives
one bounded grant at a time and returns only the corresponding observation or completion. It cannot choose a
snapshot, record key, operation set, cursor phase, or projected dependency. Phase 13 owns the signed
child-plan authority substrate, and Phase 17 owns the catalog, rooted session/protocol, executor, fixed
runner, and recursive Production adoption.

Root-signed responses authenticate the durable coordinator. A frame session is first opened at the root with
no predecessor. The four-field `OpenFrame` contains only its fixed domain/version/discriminator and 32-byte
client nonce; the sealed external relay envelope is its sole requester ancestry. Attachment resolves that
root-nearest-to-leaf path against the authenticated scope, runtime, catalog, and already-opened session before
mutation. Failure before attachment uses Protocol's existing outer `Refused`; the rooted `Refused` is
post-open only. The exact nine-field signed `Opened` response binds the digest of the complete request and
discloses the admitted canonical path plus root-selected opaque session/stage tokens and next nonzero ordinal;
the digest of that complete canonical signed response becomes the first predecessor. Every post-open response
has exactly eleven fields: response domain/version/discriminator, exact request digest, echoed path/session,
root-selected successor stage/ordinal, echoed request nonce, one variant-specific body, and signature. The
request families are exactly `OpenFrame -> Opened`, `NextNode -> Prepared | Descend | Refused`, `SettleNode |
DescendResult -> Settled | Refused`, `CloseFrame -> FrameComplete | Refused`, and `ReceiptConfirm ->
ReceiptRecorded | Refused`. `Prepared` nests exact node/dependencies/operation-gate/projected-gates packages;
`FrameComplete` carries one canonical lifecycle report; `ReceiptRecorded` repeats the matching
`FrameComplete` predecessor digest; `Refused` carries a bounded non-empty UTF-8 reason.

The complete rooted response and its one body are bounded to 7 MiB and 6 MiB respectively. Path has one to 256
non-empty UTF-8 components of at most 4,096 encoded bytes; session/stage and refusal detail are bounded to
4,096 encoded bytes; request digest and receipt digest are 64 lowercase hexadecimal bytes, request nonce is 32
bytes, ordinal is nonzero Word64BE, and signature is exactly 64 bytes. The neutral hidden owner provides seven
checked unsigned builders, strict decode/render, structural exact-request pairing, one signature-attaching
decoder, and a total fold but no cryptography or authority. The Handoff facade signs only
`frame("hostbootstrap/rooted-lifecycle-response/v1") <> frame(installed-key-digest) <>
frame(exact-canonical-request) <> frame(exact-canonical-unsigned-response)` through the live root broker and
the existing specialized hidden admission. Installed-key verification structurally pairs first, verifies that
exact transcript next, validates a `FrameComplete` report last, and only then enters the fixed CPS fold. The
opaque response remains descriptive signed data; Phase 17 alone assigns typed body meaning, successor law,
durable settlement, terminality, and replay. Phase 13's relay adoption is transport-only: it preserves the
singleton inner request/response bytes, enforces the external path-component grammar, structurally pairs one
outstanding request with one response, and treats both outer and signed rooted refusals as uninterpreted. Its
root endpoint validates structure but remains unavailable and returns the existing outer `Refused`; it
constructs no recursive child and makes no successful rooted process-exchange claim. Phase 17 installs the
root endpoint, invokes the already-installed fixed signer, retains the admitted session path, and owns all
semantic and durable decisions. Its
replay identity includes root lineage, catalog, envelope path, and nonce, never nonce or request bytes alone;
every post-open request must echo the exact path and tokens and is admitted only when its inner path also
equals the external envelope and session-retained path. This is a cooperating private-interpreter boundary,
not attestation of a physical process: it excludes public construction, cross-edge confusion, malformed
traffic, and stale replay, but makes no claim against a malicious same-privilege launcher or intermediate
process.

Each one-use command/handoff invocation atomically opens one versioned operation session only after the
current broker has admission, advances the shared project-journal version, and returns its sole successor
state/permit pair. Session close does the same. Clean activation proves no older-generation session
remains Open.
Abandoned-run recovery instead consumes the exact old-permit fence set in a protected exact-set fold,
verifies a manifest pairing the independent complete session and operation sets, CAS-rebinds each
existing stable session record to the fresh broker/local identity, and internally handles every unknown,
pre-call continuable, whitelisted already-observed retryable, successful, or terminal operation before
requiring that exact session's Closed proof plus sole successor state/permit pair. A zero-operation Open
session remains a required member. Initial intent creation consumes the exact first/reacquisition origin
and session membership is atomic with that generation write. A persisted initial intent with no fence is an explicit recovery
state; the classifier idempotently completes the stable initial-fence protocol before continuable work
receives an `OperationFence`. It also verifies/rebinds the complete
resource-record set; only the matching bound snapshot and that opaque set can yield a recovered frame
and a closed owned-or-released evidence sum for the forest's exact authorization point. The owned branch
alone yields a managed handle/receipt; the released branch alone yields the verified tombstone and can
mint `FreshGeneration` only after protected absence plus a distinct acquisition key. That eligibility
token cannot call or register by itself; its sole consumer supplies the exact origin to the atomic
registration compare-and-swap. Only both complete
session/operation sets yield
`CurrentBrokerSessionAdmission`; missing/duplicate records, wrong membership, missing/replaced resource
evidence, or unresolved recovery cannot manufacture it or create a second logical session. Before each
frame-executor effect, the root runs one protected prepare compare-and-swap that revalidates exact
project-mode and broker epochs, bound lease, active revision/no migration freeze, authority
epoch/verb/phase/frame, Open-project and Open-session versions, current authoritative fence, readiness
generation, journal phase, operation key, exact plan-owned closed precondition-set identity, and call
digest. It reruns every root-authoritative probe and conditional version; stale, replaced, or not-ready
evidence yields no grant. It durably records the operation-specific Unknown state, advances the session
version, and only then returns a root-signed exact prepared grant naming the resulting gate coordinates and
the catalog-selected target node/dependencies. The storeless executor independently reconstructs that target
node and exact-matches every coordinate. Only an allowlisted hidden consumer may then reify the
`PreparedGate`, and only from that authenticated proof of the same root compare-and-swap; receipt of bytes or
knowledge of the coordinates is not another gate origin. The executor runs the plan-owned local probes and
prepared backend adapter and returns its exact observation. The root alone validates that observation,
settles the frame journal, and yields the successor Open-session, Open-project operation state, and matching
revision-permit authority at one fresh journal version. The
consumed journal version cannot authorize a later prepare, settlement proof, or project close. The
prepared pair retains the exact resource identity/kind, generation, operation/key, precondition-set/
call digest, session/fence/attempt, and prepared journal version; each named adapter also requires the
matching descriptor, operation binding, or operation-indexed teardown step and accepts no separately
retained readiness/prerequisite value. Every terminal observation returns
`OperationAdvance` on success or typed failure, and its eliminator exposes the result only with the sole
fresh successor state/permit pair. Initial fences and crash-time fence rotations have durable
intent/unknown/observed states and resume the same stable proposed epoch; delayed old permits are
rejected or deduplicated. Terminal acknowledgment verifies every registered outcome settled and
compare-and-swaps that exact session version Closed, so a concurrent prepare or retained settled proof
cannot win. Executors never read or reprobe raw journal/receipt records; the root rehydrates durable evidence
and binds it to the cataloged target identity before issuing another grant. Ordinary acquisition,
ordinary teardown, adoption transfer/adopted release, repair, and managed phase transition enter their
distinct unknown states before their respective backend calls.

Successful ordinary Production `up`/`down` then has one further typed boundary. The core recursive
interpreter alone mints `ProductionInvocationCompleted` after independently deriving the complete
session/operation sets, proving every session Closed, every operation terminal, and no prepared operation or
prepared call outstanding, and revoking current-broker admission at that exact journal version.
`closeCompletedProductionInvocation` revalidates that proof plus the Production mode epoch, bound lease,
snapshot/binding, active revision, complete resource-record set, and Open-project state in one protected
compare-and-swap. Its success consumes only the `BoundRunLease`, broker admission, and revision-permit authority;
it returns `ProductionInvocationClosed` with the same
`ProjectModeLease ... ProductionMode`, bound snapshot/binding, active revision/journal,
`RehydratedResourceSet`, and successor `OpenProject` state. It does not release mode or resources and
cannot mint `ClosedProject`. Unknown acknowledgment exposes only
`ProductionInvocationCloseUnknown`. Bound recovery classifies the persisted terminal acknowledgment
before revision recovery and can only observe the same close already committed or idempotently resume
that stable close key; it cannot reopen a session. `ProjectDestroy` and verified true-pre-effect refusal
remain the only `releaseProductionMode` paths.

The root broker remains live through one recursive invocation. A later Production `down`/`destroy`
re-runs the independent root gate, verifies the protected versioned non-secret plan/teardown snapshot,
lease/journal/receipts and backend identities, and opens a new broker generation. It does not infer old
teardown from edited/missing config or a changed binary; unknown snapshot versions refuse without
effects. Compatible revision carry first uses the sole `withProjectUpMigrationProfile` producer to
revalidate the exact `ProjectUp` migration root, active mode, old-bound lease/snapshot/binding, and
`NormalActiveRecovery` without a new plan. The pre-freeze `withProspectiveMigrationPlan` bracket
consumes that indexed profile and same old-bound package with the scope-correct new config and non-empty
drafts and jointly creates one fresh candidate plan plus its pure non-authorizing
`ProspectivePlanSnapshot`/binding. Only `withPlanMigration` can consume that exact candidate. It
persists/fsyncs and authoritatively reads back the candidate under a fresh stable migration key before
it may freeze the old revision; failed/unknown persistence leaves admission unchanged, and a
pre-freeze crash leaves only a non-authorizing unreferenced record. After persistence, the opener
derives the complete exact old `VerifiedResourceRecordSet` internally, atomically records that same
stable key while freezing operation preparation and revoking session admission, then drains or
authoritatively fences every old prepared operation before staging. Session opening and freeze contend on the same
project-journal/revision version; the freeze cannot settle until every independently enumerated
session, including zero-operation sessions, is Closed. Per-resource migration authority is
indexed by unchanged frame/resource/generation/ownership-operation/key/policy, settled
owned-or-released disposition, and complete `recordSetDigest`. A plan-owned exact-set fold stages each
complete `VerifiedResourceRecordBundle`; owned members carry their receipt, released members carry only
their tombstone, and missing/duplicate/extra/unknown/disposition-mismatched members refuse.
Live migration uses `bindLiveMigrationPlanSnapshot` over the already-built candidate plus the exact
stable-keyed persisted proof; it never reconstructs a plan after freeze. Abandoned Production
`ProjectUp` must first load the exact persisted prospective `VerifiedPlanSnapshot` named by the
incomplete recovery record and then use the exact bound-recovery profile plus
`withRecoveredMigrationPlanSnapshot`. It may reconstruct only when the provided config/drafts render
that loaded snapshot. These gates produce only migration-local plan/binding values, and prospective,
frozen, and staged records authorize no effect. Freeze replaces the old bound lease with one exact
stable-keyed `FrozenMigrationRunLease`. Only a protected
compare-and-swap over the complete set can archive old active
records, switch the lineage old→new, consume that frozen capability, return only the new-bound lease,
and yield one old/new-indexed `PlanMigrationBarrier`; old- and new-bound authority cannot coexist.

`activateMigratedPlan` must consume that barrier, the exact new-bound lease/active revision, local
plan/binding, and complete set before exposing a journal or preparation authority. It rechecks that no old session
remains Open and jointly yields the new revision's `CurrentBrokerSessionAdmission`; completed configless
recovery must produce the same admission before opening a teardown session. A pre-CAS restart resumes
the frozen old-active migration under a fresh local `migrationId`; `ProjectDown`/`ProjectDestroy` may instead cancel
inactive staging while old remains active. A post-CAS restart selects completed recovery. Both paths
first load and verify the exact prospective snapshot named by the durable `stableMigrationKey`, never a
digest inferred from current config. `withCompletedMigrationPlan` then requires the exact new-bound
recovery profile and rebuilds configful forward state only when it matches those persisted bytes, while
`withCompletedMigrationRecovery` uses the same non-secret protected snapshot data for configless teardown. Kill
injection between CAS and activation must not issue a `PreparedOperation`. Old-digest binding/preparation cannot reopen
after the CAS, and released tombstones cannot become managed.
Before a new harness run, `recoverAbandonedHarnessRuns` handles both unbound no-effect and bound
snapshot-driven old leases through separate rank-2 folds over the exact
`VerifiedIncompleteRunLease` values; terminal closure is rechecked after every callback. Bound recovery
first eliminates `BoundInvocationRecovery`; a persisted Closing epoch resumes only its close journal,
while Open revision recovery selects
normal/incomplete/completed activation. Normal activation with an older Open operation session must use
the recorded-session interpreter and independent session/operation manifest before any current-broker
session admission. Only the
protected empty-set compare-and-swap proof can be
consumed by `withHarnessRoot` for fresh allocation. Harness brokers cannot sign
Production grants. Replay/wrong bindings refuse; broker loss before prepare refuses, while loss after a
prepared backend call leaves an explicit unknown for reprobe. Every ordinary config/forward edge invocation
receives a fresh token. A prepared reverse-recovery edge instead durably selects one exact binding/token pair
from the complete live-broker, canonical binding-input, and prepared-adapter identity, then repairs only an
absent or exact planned token row under that same live-broker guard; a granted or conflicting token refuses,
and a retry reuses only the exact stored choice. Before recovery pre-signing or transmission, a private Bound
row nests the exact Prepared bytes with the validated offer, and crash rehydration accepts only byte-identical
Bound state. Neither durable step exposes a reusable token, offer, Prepared closure, or public recovery seam.
Nested recovery derives a signed non-secret adapter wire from the bound snapshot and requires an exact
parent→child `RecoveryProjectionBinding`, `VerifiedRecoveryWire`, and
`VerifiedRecoveryHandoff scope brokerGeneration planDigest parentFrame childFrame recoveryWireDigest
recoveryWireId verb` plus the closed teardown
authorization point produced only by the forest for either ordinary child-settled work or destroy-only
pre-descent reachability. The recovered frame and exact resource evidence must come from the bound
snapshot plus complete rehydrated set; raw receipt bytes cannot authorize it. Recovery does not
reconstruct a normal child config and cannot authorize `ProjectUp`.
The `RecoveryHandoff` tag itself belongs to the **authenticated-handoff-and-child-admission phase**,
which owns every v1 protocol tag and pins each one's round trip and negative paths; the
recursive-lifecycle-command and recovery-and-migration phases consume it. This is the same wire the
recursive teardown descent admits its nested verb with (§ X, § Y) — a nested teardown and a nested
recovery are one edge, not two, so they share one tag rather than each minting a private one.
Controller-managed service restarts use a separate platform/OS verifier. The signed manifest authorizes
an immutable rollout revision/controller template; after creation, independently measured workload/OS
identity contributes the concrete pod UID plus restart count or invocation nonce. Together with the
pinned, independently provisioned Activation verification key they yield one
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`; its activation authority, role-plan
projection, and protected secret-channel locator cannot be separated or mixed.
The scope-correct project-owned `RoleCodec` verifies the mounted role-wire bytes, and the activation
internally reads/verifies the Production-empty or Harness-private bundle, into a fresh
`VerifiedConfigWire`/`ValidatedServiceRequest`. The signed projection proves its narrowed
`rolePlanDigest` and exact `configDigest` belong to that parent `planDigest`; the child does not recompute
the full lifecycle plan from its least-authority wire. `verifyRolePlanDraft` first checks the project
draft/digest without durable mutation. `withRoleLifecycleAdmission` then atomically reserves the one-use
lifecycle admission/journal—or yields only the complete predecessor recovery manifest—and
`withRuntimeRolePlan` linearly consumes that exact admission plus verified draft. It yields only
`RolePlan scope specDigest planId configId secretDigest frame revision instanceId`, the matching
`RolePlanDigestBinding`, and a same-`planId` `VerifiedServicePlacement`; `selectAndRunService` also requires
the exact Serve cursor, ready handles, retained receipt/lease package, and finalized runtime spec. It rechecks the
workload-instance identity, proves the selected handler's exact effect row (including opaque
durable-placement authority where required), and atomically transfers a private
`ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
ServePhase service effects` into the internal selected package. R1/I1 values cannot run in R2/I2 or after
I1 terminates; non-exclusive rollout overlap is permitted. Exclusive lease transfer publishes the
successor only after exact-set old-instance recovery produces typed
`ServiceLeaseTransferBarrier` from an atomic backend fence or retained-lock in-flight-settlement barrier
covering every predecessor; `resumeRoleLifecycleAdmission` consumes it before a new plan exists, and
unsupported backends refuse. The core-owned masked run-to-Exit operation is the only public runner. Activation alone cannot authorize
effects or execution. A restart cannot construct a
lifecycle `ProjectPlan`, root authority, or lifecycle mutation. The target Dockerfile-time gate uses an
ephemeral, project/spec/config/build/source/builder-bound `BuildInvocationAuthority` joined with its exact
`ImageBuildFrame projectId specDigest configId frame`, never the baked config alone.
`verifyBuildInvocation` checks the delivered `BuildChannel` against an independently installed Build key,
locally supplied project/spec/config/coordinator identities, and fresh measurements of the source context and
builder binary; only its rank-2 continuation receives that pair. `authorizeCheckCode` and
`authorizeBuildPhase` then authorize each narrow phase at most once. Phase 13 owns that reusable protocol;
the worked-demo phase owns the static command consumer, delivery to, and consumption by the actual
derived-Dockerfile `check-code` route. Current derived builds still use the sibling-config-gated
non-attesting path. The canonical full algebra is
[lifecycle_state_model](../documents/architecture/lifecycle_state_model.md).

### FF. Rolling Base Selection and Native Compatibility

**Owning phase**: [the base-image-and-warm-store phase](phase-23-base-image-and-warm-store.md)
`hostbootstrap` is greenfield and intentionally uses rolling
`basecontainer-<flavor>-<arch>` tags. Each base rebuild discovers and selects the current/latest
compatible upstream parent, tools, and package sets at build time; rebuilding the same source revision
need not reproduce an earlier image. A committed base-input version lock is not required. TLS and
available integrity metadata should still protect downloads, but neither turns the selected versions
into a replayability contract. A resulting digest may identify one published build for inspection or a
single workflow handoff; it does not make locked inputs, digest-pinned consumers, or reproducible rebuilds
part of the architecture.

`base build` and `base build-and-push` validate that the requested architecture matches the native Docker
engine/host architecture before work starts. Cross-architecture emulation is not silently selected. A
publish workflow runs the complete Python, Haskell, and consumer source-quality gates, builds natively,
pushes the rolling tag, pulls that published tag, and may use the pulled result in a real-consumer
compatibility smoke. Local same-named images do not substitute for that post-publish pull. The smoke
checks compatibility only; it is not reproducibility or complete-cache evidence.

Host-native and container builds use the same consumer `cabal.project`. A derived Dockerfile never swaps
in a container-only project and never imports base-owned freeze files. The inherited Cabal store is an
opportunistic cache: matching artifacts may be reused, while cache misses may resolve, download, and
compile normally. Offline builds and guaranteed cache hits are not acceptance criteria. Rolling publication,
native-architecture enforcement, the source gates, the pull, the compatibility smoke, and the
single-project and opportunistic-store policy are all this section's owning phase's.

### GG. Scope-Indexed Network Reachability and Blob Delivery

**Owning phase**: [the composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md)
A network endpoint is not interchangeable text. Core models the scope from which a client can reach an
endpoint (`ClusterOnly`, `ProviderLocal`, `HostLocal`, or `Public`) and keeps that index on opaque
endpoint, exposure, and client values. A finalized registry plan jointly binds the client, verified
published exposure, backing object-store endpoint, credential authority, and blob-delivery strategy.
Consumers may contribute concrete registry resources and image operations, but may not independently
select endpoint strings or a serialized redirect boolean.

A local publication is also a runtime-owned resource, not a configured number. A plan names the service,
protocol, and stable cluster-internal target. The cluster backend asks the container runtime to bind the
relay on loopback with no host-side number, then authenticates the exact relay identity and inspected mapping
before minting `ResolvedExposure`. That value carries the selected port with its scope, plan, cluster
generation, service, relay identity, and ownership operation; it travels only through the matching dependency
package and is never written back into Dhall. The runtime bind is the allocation. Scanning for a free port,
closing the probe, and later passing that number to Kind, nvkind, Docker, or a child process is forbidden
because another process can acquire it in the gap. Kind/nvkind `hostPort: 0` is not sufficient when the
launcher resolves zero to a candidate before the runtime binds it. Cluster teardown releases the exact relay
and its mappings by identity.

`RedirectToBackend` is constructible only from a proof that the client scope can reach the backend
scope. There is no proof from `HostLocal` to `ClusterOnly`; that topology can construct only
`ProxyThroughRegistry`. Rendering is total over delivery strategy, so proxy delivery emits
`storage.redirect.disable: true` and redirect delivery emits `false`. The boolean is output, never an
input to the DSL.

Static coherence does not replace runtime identity. The plan-owned route probe verifies the exact
client→exposure and registry→store paths, rejects an out-of-scope redirect, and yields a
revision-/plan-/registry-/store-indexed `ReadyBlobRoute`. A bare `/v2/` response cannot satisfy an image
operation precondition. the composition-and-network-algebra phase owns the generic reachability and delivery algebra, the canonical-quantities-and-reconcile-results phase owns the
identity-bound readiness/precondition machinery, and the worked-demo phase owns the demo renderer and live
host-client→NodePort→cluster-only-MinIO proof. The canonical architecture is
[network_reachability](../documents/architecture/network_reachability.md).

### HH. Unrepresentable Illegal State

**Owning phase**: [the installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
A boundary is a type, not a convention. Where a value has exactly one lawful shape, the unlawful shapes
have no constructor: a private constructor with a validating smart producer, a rank-2 continuation that
prevents a value escaping the scope that authorized it, a closed sum with a total eliminator, and
phantom indices that refuse cross-plan, cross-scope, or cross-resource mixing. Sections § CC, § EE, and
§ X are instances of this rule rather than competitors to it — readiness witnesses, capabilities, and
command authorities are three boundaries that already apply it. § K governs *which* path a host
invocation names; this section governs the *shape* every such value is allowed to take.

A claim of unrepresentability carries a proof obligation. A boundary asserting that a shape cannot be
constructed ships a compile-fail fixture under `core/hostbootstrap-core/test/compile-fail/`, registered
in `CompileFailSpec`, that fails for the named reason rather than incidentally. Without that fixture the
claim is a comment, and a comment is not a boundary. A fixture whose expectation can be satisfied by an
unrelated compiler error is worse than none, because it reports the boundary as held.

A test that asserts the current value of an unsealed field pins whatever that field happens to hold. When
the held value is wrong, the test makes the defect the contract and every gate agrees with it. Prefer a
behavioral assertion that the lawful shape *does the lawful thing*: such a test cannot be satisfied by an
unlawful shape, so it fails when the boundary is missing rather than certifying its absence.

Spawning a child process is such a boundary. A child that outlives its launcher has exactly one lawful
stdio disposition, file-descriptor inheritance setting, session, environment, and working directory, and
each of `System.Process`'s other `StdStream` constructors is wrong for its own reason: `Inherit` retains
the launcher's capture pipe so nothing reading the launcher observes EOF, `CreatePipe` leaves the parent
blocked on an EOF that never arrives or delivering `SIGPIPE` after it closes the read end, and `NoStream`
closes the descriptor — which the `process` documentation restricts to children that never use it, and
which a threaded-RTS child answers by claiming the freed descriptors for its own IO-manager control
channel. The assembled `CreateProcess` for such a child is therefore not caller-constructible: no module
outside the sealed boundary builds one, and the disposition is not a parameter.

A recursively bracketed lifecycle child has a different lawful launch shape from a detached child. Its
forward owner accepts only one opaque planned-forward package constructed from the exact parent plan/current
frame/context, a finalized-project-owned child projector, independently validated project-specific child
configuration and target plan/digest/binding, and topology-owned lift context, input, and payload. The
projector derives remote durable-root lineage without a parent-forged child-local `CanonicalProjectRoot`. Its reverse owner
accepts only the already-prepared reverse descent. Neither route accepts a caller-supplied `CreateProcess`,
executable, channel, working directory, environment, payload, binding, or completion constructor. The bracket
assembles its process internally with cwd fixed to `/` and the environment currently inherited internally;
inherited is neither sanitized nor plan-derived.

Protocol success is also an unrepresentable boundary rather than exit-status convention. The root catalog's
exact-binding-keyed child-frame row is v1 Published→v2 Received. Its separate parent slot is v1
Reported→v2 Acknowledged→v3 Adopted. Publication, acknowledgement, adoption, and child receipt are all
root-coordinator durable mutations; neither the immediate parent nor the frame executor obtains a protected
store. Live admission and mutation finish under the exact root session guard, which releases before fixed
callbacks deliver the committed response or adoption. Protocol supplies only structural one-field tags/states
and a nullary/fixed invalid-report error; Relay owns their canonical transport envelopes and can forward only
the sealed rooted request/response packages. The root prepares the parent transition, the immediate parent
forwards the exact acknowledgement to the child, and only then may the root conditionally adopt. Only fresh
Adopted invokes the immediate-parent continuation; replay redelivers the stored acknowledgement without
another callback. Routed acknowledgement and receipt consume only sealed received edge/descent packages; the
process owner receives neither Receiver internals, a raw protocol channel, durable record operations, nor a
store locator.

The bracket's lifetime guarantee is bounded by what the host can execute. Timeout, cancellation, protocol
failure, callback exception, and other catchable host exits terminate and reap the complete host-side child
process group before ownership is released. An uncatchable parent death executes no Haskell cleanup and cannot
promise termination or reap; only pipe EOF and the kernel's descriptor/process cleanup remain. This boundary
makes no claim about guest or container descendant groups.

What this does not buy. Hidden constructors exclude construction by cooperating code inside this
repository. They do not exclude an external actor, do not bind a caller who reaches past the boundary to
the underlying package directly, and do not make a runtime disposition safe — § EE's limit that no plan
may claim compile-time exactly-once effects from phantom types alone applies here unchanged. A sealed
shape is a guarantee about what this repository can express, not about what the operating system can be
made to do. The
[host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md) owns the
host-invocation boundary, the
[canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md)
owns the readiness foundation, the
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
owns the lower authority boundary, and the
[lifecycle-modes-and-run-leases phase](phase-9-lifecycle-modes-and-run-leases.md) plus the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) own the
lifecycle instances. The
[documentation-reconciliation-and-drift-guards phase](phase-29-documentation-reconciliation.md) owns the
mechanical guards that keep a sealed surface sealed. The canonical architecture is
[unrepresentable_state](../documents/architecture/unrepresentable_state.md).

### JJ. Host-Portable Static Gate And Test Harness

**Owning phase**: [the Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md)
The repository builds every project binary host-native on every substrate (§ N), so the sources that
binary is built from — and the suites that gate them — are host-portable. The **host static gate** (§ II)
runs as an ordinary process of the outer host, and it passes host-native on macOS, Linux, and Windows
alike. A suite that only builds and self-tests on POSIX cannot gate a binary the plan says is built
host-native everywhere.

The harness therefore holds five rules. Each is a property of the test harness, never a weakening of the
contract a guard asserts: a host-portable guard proves the same thing on every host, which is exactly why
it may not be written in terms of one.

- **A guard over source bytes reads bytes.** A frozen source digest is computed from the file's own
  bytes, so it is a property of the file rather than of the process locale. The suite driver also fixes
  the locale encoding, so a spec that reads a source file or captured command output decodes the same
  text on every host.
- **A repo-relative module path is separator-neutral.** An import allow-list, importer set, or
  module-ownership list compares canonical forward-slash paths, so a native path separator cannot make
  an otherwise-satisfied allow-list fail.
- **A host tool-path fixture is absolute on the host that runs it; a guest path stays POSIX.** § K
  already draws this line for invocation: a host tool is resolved and invoked by the outer host, while a
  guest path names a file on a different machine reached through one host-provider command. A fixture
  respects the same split, and the host side is admitted by the same total constructor production uses.
- **A conditional expectation follows the subject, not the package.** A platform row exists on every gate
  host, so what varies is what it *answers* there: the kernel result where the row can hold its
  obligations, the total refusal where it cannot. A case reads that from the row's own declaration
  rather than from a build symbol the suite repeats, so the expectation cannot drift from the subject it
  is about, and a compile-fail fixture expects one diagnostic because the module it names is built
  everywhere.
- **No case is skipped, and no module is excluded from the build.** A case whose subject is unavailable
  on this gate host asserts the refusal its row declares; it does not disappear. A conditional that
  changes an *expectation* keeps the evidence, while one that removes the case removes it — and a green
  total that quietly shrank on one family is the most complete form of spoofing available, because the
  number reads the same. Platform rows are therefore compiled everywhere and stubbed to a total
  `Unsupported` where they cannot apply, rather than excluded by a Cabal `os` condition. The suite
  reports what it did not run, and the gate compares that against a declared per-family expectation, so a
  case vanishing is a failure rather than a smaller number nobody reads.

#### The gate host

A host static gate run is evidence about a **gate host**: the operating system, architecture, and
toolchain the gate *process* runs on. That is a different unit from § II's **outer host**, which pairs a
physical machine with the provider it realizes a hardware context through, and which selects substrates
and owns acceptance phases. Conflating them makes the plan unreadable in both directions — a container
run would have to be reported as evidence about the machine hosting the container, and a Linux VM the
project itself provisions would be a substrate that somehow also proves outer-host portability.

A gate host is therefore identified by what it *is*, never by how it came to exist. Bare metal, a virtual
machine, a container, and a WSL2 distribution are each a gate host, and a run on any of them is evidence
for its own OS family and for no other. There are three supported families — Windows, macOS, and Linux —
and a phase's dated evidence names the family and the machine that produced it.

This is not a way to obtain a substrate gate cheaply. § II's distinction is untouched: a substrate gate is
about where the *effects of the lifecycle under test* execute, and running a static suite on a Linux gate
host proves nothing about a provider, a container, or a POSIX process boundary. Nor is provisioning
machinery a source of gate hosts: `ensure wsl2`, `ensure lima`, and the provider reconcilers exist to
establish the substrate the project under test runs in, never to obtain a development environment for the
repository's own gates. How a developer or CI comes by a gate host is outside the plan.

#### What a phase owes, and what it does not

A phase closes when its own suites hold the four rules above and its declared gate passes on the gate host
that ran it. It does **not** owe evidence from every family: requiring three gate hosts to close a
baseline sprint is exactly the closure obligation § C forbids, because the hardware is not something the
phase declares. Cross-family confirmation is owned by one terminal acceptance phase, the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md), which runs the gate on each
supported family and lists what it confirms — so a baseline phase closing on one family's evidence does
not silently drop the portability claim.

A phase whose own suites do not hold these rules is `Active` until they do, and its `Remaining Work`
names the assertions it owes. The
[Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns this contract and the shared
harness foundation every suite draws on: the fixture-path constructor, the separator-neutral
repo-relative path helper, the suite driver's locale, and the absence guards that keep each shape from
returning. The
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md),
the [host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md), the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md), and the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) each own their own suites'
conformance. The canonical engineering home is
[testing](../documents/engineering/testing.md); the design justification is in
[rationale.md](rationale.md).

### KK. One Effect Vocabulary, And No Scripts

**Owning phase**: [the host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md)
§ K fixes *which* executable an invocation names and § HH fixes the *shape* it is launched with. This
section fixes *how the command is expressed*: as a value in one closed vocabulary, interpreted by one
runner in the binary.

**The repository contains no script.** There is no `.sh`, `.ps1`, `.bat`, `.cmd`, or `.psm1` file in the
tree, and no build, test, gate, release, or operator procedure depends on one. A capability an operator or
an agent needs is a surface on the binary, reached through the fixed command tree (§ P). Scaffolding that
belongs to a particular development harness rather than to the project lives in that harness's own
configuration, outside the repository.

**A host-level command is a value, not text.** One closed effect vocabulary describes every host command
the binary issues — the tool, its exact argument vector, its stdio disposition, and its frame — and one
interpreter executes it. Argument construction is pure and separately testable; execution is the
interpreter's alone. A function that builds an argument vector does not run it, and a described effect
never sits beside an ad-hoc path that performs the same work without being described. There is one shell
quoter, one process runner, and one rendering of "cross into this frame" (§ LL).

**Interpreter text is not a substitute for the binary.** A shell string, a compiled-in Python program, or
a PowerShell expression is an untyped, unversioned, per-platform fork of logic the binary already owns. It
cannot be type-checked, cannot participate in the prepared-operation and authority machinery (§ EE), and
must reimplement in another language every invariant the Haskell surface already states. Where a host
capability looks like it needs an interpreter — file locking, descriptor passing, process groups,
no-follow opens, atomic replace — the binary uses the platform binding for it behind one seam (§ LL), the
way the host-wall backend already does.

**The one irreducible residue is the guest bootstrap.** Establishing the binary inside a fresh frame needs
commands to run there *before* the binary exists there, and § N forbids copying a binary across hosts. That
bootstrap is therefore a closed, typed vocabulary of its own — install these packages, fetch this pinned
toolchain, build, install the binary — owned by exactly one module, ordered, and re-probed like any other
reconciler (§ L). It is not a general escape hatch: once the binary is established in a frame, every
further command in that frame is the binary's own typed operation, lifted (§ LL). Free-form text in that
module is as forbidden as it is anywhere else.

The [host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md) owns the
vocabulary and its single runner; the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns the guest bootstrap vocabulary. Absence
guards (§ I) assert that the tree carries no script file, that interpreter-invocation tokens appear only in
the guest bootstrap module, that exactly one quoter, one runner, and one crossing renderer exist, and that
each computation the ownership rows share — the identity read, the no-replace publication, the
identity-conditional act, and the record codec — has exactly one definition site.

### LL. The Frame Table: The Substrate Axis Is A Lift, Not A Fork

**Owning phase**: [the host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md)
A provider does not own a workflow. It owns a **frame**: a way to reach a context, plus the small closed
table of facts that context differs by. Every lifecycle behaviour is written once against an abstract
frame and instantiated from that table. Adding a provider adds a **row**; it never adds a parallel copy of
a workflow.

The table is closed and small, and each entry is a value rather than a code path:

- the host tool that reaches the frame, and the exact argument shape it takes;
- the frame's path grammar (§ MM);
- the frame's sizing renderer, mapping one `EffectiveBudget` to that provider's own wall vocabulary (§ O);
- the frame's ownership primitive — the platform seam beneath the four clauses (§ EE), never a second
  implementation of them;
- the frame's file-transfer and share primitives.

The ownership primitive is the entry most easily mistaken for a workflow, so it is worth stating what its
row contains. Three rows exist: a POSIX one, a Windows one, and one that ships the transaction to this
same binary at the frame that interprets it. The third is a **transport**, not a third implementation —
every frame the project reaches is Linux, so what runs on the far side is the POSIX row. The transaction
travels as one value and the process that receives it lives exactly as long as the lock it holds, which is
what keeps § EE clause 1 a kernel fact rather than an application-level release that has to be correct on
every error path.

Anything that differs and is not in that table is one of two things. A genuine capability difference is an
explicit typed `Unsupported` or `Conflict` at the point of use, so a caller sees a decision rather than a
gap. Anything else is a defect: a second copy of a workflow that will drift from the first, and whose
drift no gate can see, because each copy passes its own tests.

**WSL2 is Linux.** So is a Lima VM, an Incus instance, and a container. A behaviour that is true of Linux
is written once for Linux and reached through whichever frame the outer host realizes it with. A
provider-specific module contains only what is true of that provider's *own* ownership problem — for WSL2,
that a Windows host owns a single utility VM every distribution shares — and never a second copy of the
Linux behaviour underneath it. The five-constructor `SubstrateName` detector classifies an outer host for
frame selection; it is not a licence to re-spell the same predicate at each site that needs it, and
`isLinux`/`isWindows`/`isAppleSilicon` are the derived predicates that exist so it is not.

**One rendering of "cross into this frame".** The lift fold that turns a layer stack into a dispatch is the
only place a frame-crossing argument vector is produced. A second renderer — for a different call site, a
sanitized route, or an authenticated descent — derives from that fold or is the same defect as a second
workflow: two answers to one question, differing where nobody looks.

The [step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) owns the frame as the
unit its algebra composes over; the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)
owns the one ownership seam; the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) owns the rows and
the single fold; the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns reconcilers as rows rather than as
per-platform modules.

### MM. A Path Belongs To The Frame That Interprets It

**Owning phase**: [the host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md)
§ K draws the host/guest line for *invocation*. It is the same line for every path, and the deciding
question is the same one: **which frame's process will interpret this path?** Not which frame constructed
the string, and not which frame's filesystem the bytes happen to live on.

A **host path** is interpreted by a process of the machine the binary is currently running on: a resolved
executable, a canonical project root, a durable root the current frame opens. It is admitted by that
machine's own path grammar, so it is drive-qualified on Windows and rooted at `/` on POSIX, and the total
constructor that admits it is the platform-aware one.

A **guest path** is interpreted by a process in another frame, reached through one absolute host-provider
command: a path inside a managed VM, a node container, a mounted share as the guest sees it, or an
argument to an ownership driver running in the realized Linux substrate. It stays POSIX on every outer
host, and its validator is POSIX for the same reason.

Two consequences are worth stating because both have been got wrong by reasoning from the wrong end. A
path derived from a host value can still be a guest path — the derivation says nothing, the interpretation
says everything. And a validator that admits a path must use the grammar of the frame that will read it,
so a POSIX-only absoluteness check over a guest path is correct rather than a portability defect, while
the same check over a host path is a defect that only shows on the outer hosts nobody ran.

Test fixtures respect the same split (§ JJ): a host tool-path fixture is rendered onto the gate host that
runs it, and a guest path fixture is written POSIX and left alone.

The [host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md) owns the
host-path constructors, the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) owns the guest-path
grammar and the host-to-guest translations a frame declares, and the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns the
in-frame cluster paths. The design justification is in [rationale.md](rationale.md).

### NN. Evidence, And What Cannot Count As It

**Owning phase**: [the Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md)
A gate is worth exactly what its evidence is worth. § JJ governs whether a guard proves the same thing on
every host; this section governs whether it proves anything at all.

**A fake exists because a decision is trapped inside an effect.** A suite needs a stand-in binary when the
logic deciding what to do with that binary's output lives inside a subprocess; it needs an injected
executor when the classification that follows a command lives beside the command. Lift the decision into a
total function over a closed sum and there is nothing left to stand in for — the test applies the real
function to real values. So the rule below is not an extra burden on the harness. It is the harness
consequence of § KK's pure/impure split, and a phase that cannot satisfy it has usually not finished
separating its decisions from its effects.

Four things count as evidence:

- **applying a pure total function to values** — not spoofable, because there is no stand-in: the function
  under test *is* the function;
- **exercising a platform row against the real kernel**, in a temporary directory it created — not
  spoofable, because it is the real syscall. Clause 1's "the OS releases the lock on process death" is
  proved by a real process actually dying;
- **a compile-fail fixture that fails for its named reason** (§ HH), expecting one contiguous diagnostic
  phrase rather than a list of tokens an unrelated error could also satisfy;
- **a row reporting `Unsupported` on a gate host where it genuinely cannot hold a clause** — the row is
  real; only the host differs.

Four things do not:

- an executable a spec wrote and placed on `PATH` so production would resolve it;
- an injected seam standing in for a subject the gate claims to cover — and a seam whose only production
  instance lives in an opt-in component *is* that, whatever it is called;
- a case a conditional removed (§ JJ);
- a branch in production code that exists for a test — a crash point, a fault token, an execution
  override. It is a spoofable path shipped to operators, and it makes the gate agree with a shape
  production never takes.

The `Unsupported` decision needs no injected row, because "a backend that cannot hold a clause mints no
receipt" is itself a total function from a declared capability value to a refusal. Applying it to every
capability combination is stronger than injecting one fake that returns the answer it was written to
return.

Where a capability cannot be exercised on any available gate host, the honest disposition is to test the
pure classification with values and record the live confirmation as **owed to the acceptance phase that
declares that hardware** (§ II). Coverage that is owed and named is a smaller claim than coverage that is
simulated, and it is a true one.

The [Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns this contract with the rest
of the shared harness foundation, and each phase ships the absence guard for the shape its own work
removes (§ I). The canonical engineering home is [testing](../documents/engineering/testing.md); the
design justification is in [rationale.md](rationale.md).
