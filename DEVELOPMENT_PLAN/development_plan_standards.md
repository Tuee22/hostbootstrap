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
| `Done` | Implemented, its own declared gate passes, and (for a deferred phase) its evidence digest matches |
| `Active` | Started and not `Done`: partially built, or built with work still owed in its scope — including a re-run owed because its evidence expired; remaining work is listed explicitly |
| `Planned` | Not started; work on it begins once every phase it depends on is `Done` |

Every situation therefore has exactly one status. A phase that meets the `Done` rule below is `Done`; a
phase with no work begun is `Planned`, whatever the status of its predecessors; every other phase — work
begun and unfinished, or built with anything still owed in its scope — is `Active`. Status is a property of the phase's own scope: a lower-numbered
phase turning `Active` does not change a later phase's status, which changes only when that phase's own
gate stops passing, its own evidence expires, or work in its own scope is found owed.

There is deliberately no `Blocked` and no `Superseded`. Under § A a phase depends only on lower-numbered
phases, so an unstarted phase whose predecessors are not all `Done` is `Planned` and is simply taken up
later — nothing waits on a *later* phase, so nothing is blocked. And because the narrative is strictly
additive, no phase is ever superseded by another; a wrong phase is rewritten.

Rules:

- `Done` requires the phase's own declared gate to pass, aligned governed documentation, and no
  remaining work in its scope.
- `Active` requires a non-empty `## Remaining Work` section, spelled exactly that. One heading means a
  reader and a validator find the same thing in every phase.
- **A deferred phase whose evidence expires is `Active`.** When the digest over its `**Evidence covers**`
  paths no longer matches (§ G), the phase is set `Active` in the same change that edits the covered path
  — `checkGateEvidence` refuses a `Done` deferred phase whose digest does not match — and its
  `## Remaining Work` names the sprint that owes the re-run. That is evidence expiry, not the design-error
  reopening § A forbids: nothing in the phase is wrong, its claim is simply no longer about the current tree.
- **A phase closes on its own gate.** A phase never carries a closure obligation that needs a substrate
  or accelerator it does not declare in `**Substrates**`. Gate hosts are not substrates (§ II): a phase
  that needs particular gate hosts — an operating system or architecture its static gate must run on —
  names them in its `**Gate**` field, as the host-portability acceptance phase does. Confirmation of a
  non-baseline host or accelerator dimension is owned by the acceptance phase that runs it (§ II), which
  lists what it confirms; the universal `linux-cpu` gate itself remains runnable through every supported
  host realization.
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
├── legacy_tracking_for_deletion.md
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
├── phase-25-documentation-reconciliation.md
├── phase-26-apple-silicon-substrate.md
├── phase-27-nvidia-gpu-substrate.md
├── phase-28-windows-and-wsl2-substrate.md
└── phase-29-host-portability-acceptance.md
```

The `phase-NN-*.md` set is **contiguous from 0 with no gaps and no duplicates**, and `NN` is the
execution position (§ A). Inserting a phase therefore renumbers every phase after it, and that is
expected rather than avoided; the same change updates this file, `README.md`, `00-overview.md`, and
`system-components.md`. Documents outside this directory are unaffected, because they cite phases by
name and link (§ J).

Each file's `**Status**:` line takes one value from a closed set. `development_plan_standards.md`,
`00-overview.md`, and `system-components.md` state contracts and carry `Authoritative source`. `README.md`
carries `Governed orientation document`; its status table is the cross-phase status source of truth (§ J).
`rationale.md` and `legacy_tracking_for_deletion.md` justify and list rather than bind, and carry
`Non-normative`: the ledger schedules nothing on its own (§ I). Each phase file carries `Done`, `Active`, or
`Planned` (§ G).

Obsolete shapes do not belong in a phase narrative. A shape that is absent stays absent through a mechanical
guard in the validator or tests; a still-standing unwanted shape appears only in
[legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md), with the deleting phase named in that
phase's own Remaining Work (§ I). The ledger is part of this layout whether or not its table holds rows.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative **inventory** — what exists and where
it lives:

- `hostbootstrap-core` Haskell module surfaces (`HostBootstrap.*`)
- the `ensure` reconcilers and their host applicability
- the thin Python bootstrapper surface
- the explicit pipx self-update surface for the Python bootstrapper
- the fixed optparse command tree whose behavior consuming project binaries extend through typed
  registries

It **summarizes and links** for topics whose canonical home is a governed document: the project-local
`<project>.dhall` schema belongs to
[schema.md](../documents/engineering/schema.md), the runtime binary-context fields to
[binary_context_config.md](../documents/architecture/binary_context_config.md), and the base image and
warm Cabal store to [base_image.md](../documents/engineering/base_image.md). Naming an inventory
authoritative for a contract another page owns creates two canonical homes for one topic, which
[the documentation standard](../documents/documentation_standards.md) forbids and which no check can
detect once both pages disagree.

When the host-management architecture changes, update the component inventory in the same change.

### G. Phase and Sprint Document Requirements

A phase document opens with this header, then groups its sprints under one `## Sprints` parent:

```markdown
# Phase N — Name

**Status**: Done | Active | Planned
**Depends on**: Phase A, Phase B (by name; every one strictly lower-numbered)
**Substrates**: linux-cpu
**Gate**: the exact command that closes this phase
**Gate kind**: self-verifying | deferred
**Gate evidence**: <ISO date> ; <gate host> ; `<command>` ; pass ; covers <digest|in-gate>
**Evidence covers**: `path` `path` (deferred phases only)

> **Purpose**: one sentence naming what this phase adds to the build.

## Phase Objective

## Sprints

## Remaining Work

## Documentation Requirements
```

`## Remaining Work` is required while the phase is `Active` (§ C) and says "None." once it is not. It
states what this phase owes and nothing else (§ A); a boundary with another phase belongs in
`## Phase Objective`. While the phase is `Active` it also names the sprint that owns the owed run, so
closing the phase is the same act as closing that sprint rather than the deletion of a paragraph.

No other field belongs in that block. An undeclared header field is a convention one phase invents and
the others do not share, and nothing reads it; `checkPhaseHeaderFields` refuses one. An evidence row
records **every leg the gate names** — a phase that names a composed gate and records one half of it is
claiming the whole — and `checkGateEvidenceLegs` compares the two.

`**Gate kind**` says whether the run that validates this plan also re-executes this phase's gate.
**Self-verifying** phases close on `cabal test all` from `core/` (or a spec inside it) — the one leg of
the host static gate (§ JJ) that the run validating this plan re-executes — so the same `cabal test all`
that reads this document re-establishes their currency; their `**Gate evidence**` records `covers in-gate`
and carries no digest, because a stamp re-proved on every run protects nothing. **Deferred** phases
declare something that run does not perform — a live provider, a realized host, a hardware acceptance,
the Python suite, the `demo/` leg, or any other leg of § JJ beyond `cabal test all` from `core/` — so
their evidence is a claim about a tree nothing is currently re-testing. Those name the paths whose
change re-owes the run in `**Evidence covers**`, and their evidence carries a digest over exactly those
paths. When the paths change the digest stops matching and the phase is refused as `Done` — it is
`Active` (§ C) — until its gate is re-run and re-recorded.

That is the currency rule of [the plan index](README.md) made mechanical. What it cannot do is prove a
run happened: the digest is recomputable without executing anything. It raises the cost of a stale claim
from nothing to deliberately recording a result that was not obtained, and absent continuous integration
that is the honest ceiling — so a `**Gate evidence**` row names its gate host and command, which is what
a reader needs in order to judge the run this check cannot.

**A covers digest cannot see the toolchain that drove the run.** `measurePathSetDigest` hashes repository
bytes under the cited paths and nothing else, so two runs of the same gate — one driven by a current
program, one by a stale install of it — produce byte-identical digests over an identical tree. The row's
command field is read only by `checkGateEvidenceLegs`, which matches each `**Gate**` leg's non-flag tokens
as a subsequence of a recorded command and does so only when an evidence row exists; nothing reads which
program the command actually invoked. Two rules follow. A `**Gate evidence**` row whose command invokes a
**separately installed** program is a weaker claim than one invoking `cabal`/`poetry` against the tree
directly, because only the latter is guaranteed to exercise the source the digest measures, so a gate
prefers the in-tree command. And because this repository ships two different programs both named
`hostbootstrap` — the Python bootstrapper and the bare core executable (`hostbootstrap-core.cabal`) — a
row naming it says **which**, or a reader cannot tell what ran.

A gate written as a composition — a static suite *plus* a live run, a focused pattern *plus* the whole
suite — is one claim, and a row naming only the cheaper half claims something the phase did not
establish. Where a gate genuinely closes in two sittings, the phase records two rows rather than omitting
one.

An acceptance phase (§ II) covers the host-portable tree, so ordinary source change expires its claim and
it is `Active` until its next run (§ C). That is the honest reading of a portability claim between visits
to its hardware rather than an unfinished build.

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

`#### Validation` names test cases that exist in the tree: each entry names the spec file and the case
within it, so a reader can find and run exactly what the sprint claims. Coverage that runs only in a live
or opt-in lane — a live provider test, a realized-host run, an accelerator lane — names that lane, so it is
never mistaken for coverage the host static gate (§ JJ) executes on every run.

Every sprint carries `#### Remaining Work`, including a `Done` one, where it begins with "None." — often
followed by the boundary note saying which phase owns what this sprint does not. A `Done` sprint that
declares work is not done, and one whose only outstanding item is a live confirmation is closed here with
that confirmation owned by a later sprint of the same phase (a live `linux-cpu` confirmation) or listed by
the acceptance phase declaring the hardware (a non-baseline context, § II).

**Sprint size budget.** A sprint is one working session. It lands **at most one new named
contract/type, or one call-site adoption**, and stays within:

- ≤ 8 deliverable bullets;
- ≤ ~400 lines of production Haskell across ≤ 3 source modules, plus their specs;
- closable by the **host static gate** alone — all four commands of
  [§ JJ](#jj-host-portable-static-gate-and-test-harness).

A live confirmation is never in the same sprint as the change it confirms. A live `linux-cpu`
confirmation — a run on a realized `linux-cpu` host or a live provider, cluster, or service run there — is a
later sprint of the same baseline phase, whose `**Gate**` names it. A confirmation of a non-baseline
hardware context belongs to that context's acceptance phase (§ II). A sprint whose `#### Remaining Work`
has grown into a chronicle has exceeded the budget and must be split into further sprints, and its dated
evidence recorded against the gate rather than narrated.

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

Dead code is the commonest such shape: an export, constructor, kernel, field, or module that no production
path reaches. No contract requires it, it tells a reader the tree does something it does not, and an
authority-bearing one is a producer the sealing rules (§ EE, § HH) never constrain. It is tracked in the
ledger until the phase that introduced it removes it.

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
  the only place that summarizes every phase's status. Its columns are `#`, `Phase`, `Status`, `Substrate`,
  and `Open`: the `Status` cell is exactly `Done`, `Active`, or `Planned` and nothing else, and the `Open`
  cell names the sprint that owns the remaining work while the phase is `Active` and reads `—` otherwise.
  A phase document carries the matching local `**Status**`; `00-overview.md` and
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

- the **host static gate** — all four commands of
  [§ JJ](#jj-host-portable-static-gate-and-test-harness), each run as an ordinary process of the
  **outer host**. It proves the pure, typed, and lexical contracts: type boundaries, compile-fail diagnostics, codecs, source-shape guards, plan projections,
  and the documentation validator. Because § N builds every binary host-native, this gate must pass
  host-native on **every** supported outer host realization — macOS, Linux, and Windows alike (§ JJ);
- the **`linux-cpu` substrate gate** — a gate whose gated process and its POSIX/container effects
  execute inside the realized Linux substrate. It may be launched from any supported host, but a
  native Windows or macOS process is not one of these merely because its assertions are otherwise
  static.

Neither substitutes for the other. A host static gate does not establish live provider, container, cluster, or accelerator acceptance.
Compiled native process fixtures can establish the protocol and kernel behavior they actually exercise;
a substrate gate on one realization proves nothing about whether the same
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
in one realization of that substrate or is pure-static; a phase whose gate is pure-static declares
`none (static)`. A hardware-context acceptance phase additionally targets the one context it declares.

- A phase declares `**Substrates**:` and may name **at most one** substrate beyond `linux-cpu`. Every
  declaration — phase header and sprint alike — draws from a closed set that `checkSubstrateBudget`
  enforces:

  | Value | Meaning |
  |---|---|
  | `none (static)` | Phase header: the gate is pure-static and realizes no substrate |
  | `none` | Sprint: the sprint's validation realizes no substrate |
  | `linux-cpu` | The universal baseline substrate |
  | `apple-silicon` | `linux-cpu` plus the Apple/Metal context; the detector class `AppleSilicon` |
  | `nvidia` | `linux-cpu` plus the NVIDIA-accelerated Linux context; the detector class `LinuxGpu` |
  | `windows` | `linux-cpu` plus the Windows/WSL2 context, including Windows-host CUDA; the detector classes `WindowsCpu` and `WindowsGpu` |

  A non-baseline value always implies the `linux-cpu` baseline beside it. The detector's `LinuxCpu` class
  names a Linux outer host without an accelerator, which is one realization of the `linux-cpu` substrate,
  not the substrate itself.
- Non-baseline hardware contexts and acceptance dimensions — Apple/Metal, NVIDIA acceleration, and
  Windows-host CUDA — are each owned by exactly one **acceptance phase**. An acceptance phase adds any
  remaining host/provider- or accelerator-only realization and confirms both the universal `linux-cpu`
  floor and the selected context's additional behavior on real hardware.
- The acceptance phases are exactly four: the three hardware-context acceptance phases —
  [Apple Silicon](phase-26-apple-silicon-substrate.md), [NVIDIA GPU](phase-27-nvidia-gpu-substrate.md), and
  [Windows and WSL2](phase-28-windows-and-wsl2-substrate.md), each declaring one non-baseline substrate —
  and the [host-portability acceptance phase](phase-29-host-portability-acceptance.md), which declares
  `none (static)` and names the gate hosts it needs in its `**Gate**` (§ C). They occupy the end of the
  narrative, Phases 26 to 29, after the
  [documentation reconciliation phase](phase-25-documentation-reconciliation.md) (Phase 25).
- **Acceptance phases are terminal**: nothing depends on them. `checkAcceptanceTerminal` refuses a
  dependency edge into a phase declaring a non-baseline substrate, and the host-portability acceptance
  phase, as the highest-numbered phase, can have no dependent under § A. Lack of Apple, NVIDIA, or Windows
  hardware prevents only that realization's acceptance; it never prevents a supported host from realizing
  and validating the universal `linux-cpu` baseline through its own provider.
- **Acceptance phases close last.** Each covers the host-portable tree (§ G), so any change to a lower
  phase's sources re-owes their runs; they are closed once no lower phase carries open work.
- An acceptance phase lists what it confirms, so a baseline phase closing on its static gate does not
  silently drop live coverage.

Three limits are recorded here because they are easy to assume away. `fourmolu` and `hlint` run in the
repository source gate that `base build` and `base build-and-push` run on the maintainer's host before any
Docker build, in a derived image's `check-code`, and in the base image's tool smoke, but not in the host
static gate, so the host static gate is not the complete quality gate — the
[base-image-and-warm-store phase](phase-23-base-image-and-warm-store.md) (Phase 23) owns those two (§ R),
and [code_check_doctrine.md](../documents/engineering/code_check_doctrine.md#where-the-style-tools-run) is
canonical for where they run. The long demo gate brings up real provider and cluster state under
the project's own identity, so it runs on a disposable host: one carrying no production demo state, so
that every provider, cluster, and data root the run touches is its own (the
[demo runbook](../documents/operations/demo_runbook.md) names the state that must be absent).
Disposability is a property of the host's state, not of the machine; a host carrying production demo state
never runs it. And a host static gate run is evidence for the one outer host that ran it, so its dated
evidence names that host and a passing run on one outer host is not a claim about another.

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

**Owning phase**: [the host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md)

That phase owns the boundary; the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) ships the
enumeration's exact membership pin.

External tools use a closed package-owned resolver and are invoked by absolute path. The ordinary resolver is
the closed `HostTool` enumeration in `hostbootstrap-core`; no library or project code calls
`proc "<bare-command-name>"` against ambient `$PATH`, and ordinary invocations read their absolute path from
typed host configuration. Discovery is where the search path enters: `HostTool.discover` looks each bare
name up on the process's ambient `PATH` (plus fixed Windows fallback paths) and admits only an absolute
result, so the enumeration closes *which names* can be invoked, not *which directory* supplies them. Two
further sites are discovery by design. `resolveInstalled` in `HostBootstrap.HostConfig` is the sanctioned
re-measurement: it reads the typed configuration first and calls `discover` only for a tool absent from it,
so a tool an `ensure` step installed mid-invocation resolves absolutely while a recorded path is never
replaced. Substrate detection's GPU probe (`hasNvidiaGpu` in `HostBootstrap.Substrate`) is a discovery
spawn: it runs before any typed host configuration exists, looks `nvidia-smi` up on ambient `PATH`, and runs
the path that lookup returns. An install step delegated through the enumerated `Sudo` tool names its program (`apt-get`, `systemctl`,
`nvidia-ctk`, `incus`) as an argument to `sudo`, which resolves it through its own `secure_path`, not
through this resolver. The worked demo's `check-code` resolves `fourmolu`, `hlint`, and `cabal` from ambient
`PATH` with its own lookup outside the enumeration; that is a gap against this contract, owed by the
[worked-demo phase](phase-24-worked-demo.md).

Two things are owned separately here, and conflating them is what makes the boundary look like it waits on
its consumers. That the set is **closed** — that entry is by construction, that resolution is absolute, and
that a failure is a typed refusal — is a property of the boundary, settled where the boundary is built.
**Which** tools are in the set is a description of what the binary drives, and that is settled by the phases
that drive them; the enumeration narrows when the last driver stops driving a name, and the phase holding
that driver ships the membership pin as its own absence guard (§ I). The enum names the external tools the binary drives — provider tools such as
`incus`, cluster tools such as `kind` and `kubectl`, the compilers the reconcilers reach, the package managers
they invoke directly (`brew`, `ghcup`, `winget`), and `sudo` for the steps they delegate. It does **not** name an interpreter or a locking front end: ownership is the binary's own typed
operation over one platform row (§ EE, § LL), so no clause is held by a resolved `python3`, `flock`, or
`lockf`. A tool the enum names is one the project genuinely delegates to, not one it uses to reimplement
something it already owns. A consumer-specific resolver is admissible only when its
candidate table is fixed in an unexposed component, callers can select neither candidates nor results, every
admitted executable and helper directory is opened without following links and bound to its canonical
owner/mode/device/inode, the complete namespace is fingerprinted and revalidated around effects, and child
`PATH` contains only those admitted helper directories.

The direct-Colima adapter is the consumer-specific realization: its private Apple resolver admits only the
fixed Python/Colima/Docker/Lima candidates (and Brew only while Colima is missing) and returns an opaque
retained toolchain. Host-static tests reach the resolver through its fixture-layout entry
(`executeNativeResolverFixture`) and the pure settlement and revalidation functions, never through a branch
production consults (§ NN). The tree still carries a Cabal-private, thread-local resolver override
(`Resolver/Override.hs`, consulted by `resolveTrustedAppleToolchain` and `discoverDirectColimaBackendAt`)
that substitutes a fixture root/home/bootstrap identity; it is an execution override § NN forbids, and
Sprint 16.20 of the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owes deleting
it. No public module exposes it or a trusted-result constructor. The direct-Colima adapter never
turns ambient `PATH`, `HOME`, cwd, Docker context, or caller output into authority. The in-VM tools a resolved provider
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
by probe-first `ensure` reconcilers — a per-frame `FrameTable` plus a reconcile action. Each table row is
either `InstallHere` (the steps that install the dependency in that frame) or `ProvidedElsewhere` (the
dependency is probed there, and an absent one is refused with the named owner); `appliesTo`, the
`requirement` text of the wrong-host diagnostic, and each host's install plan are all derived from that one
table, so applicability and the wrong-host refusal cannot disagree (§ LL). Each
module contributes exactly one `reconciler` value (`HostBootstrap.Ensure.Docker.reconciler` and its
peers for Lima, Cuda, CudaWin, Wsl2, Homebrew, Ghc, Incus, and the accelerator build stack
AppleMetal); `allReconcilers` collects them and `runEnsure` applies one. They reach a chain as `ensure-*`
step kinds. There is no per-dependency `ensureX` entry point, because a nine-name surface is nine places
a new host dependency has to be registered instead of one. There is no
top-level `ensure` command, and no reconciler is reachable as a verb. The command surface is exactly the
tree § P fixes; the closed set of internal entries § P admits is not a command and cannot reach a reconciler.
The reconcile action **installs** the
dependency when its total probe reports absence and a plan exists, then re-probes; a satisfied capability
is a verified no-op. The config-free reconcile action has type `HostConfig -> IO ()`: success is a passing
probe or re-probe, failure exits, and no value distinguishes "already satisfied" from "installed". Its
idempotence is only as strong as each probe or package-manager no-op path, and a probe does not prove
resource identity. That is the accepted contract for config-free reconcilers; a managed resource transition
that needs a typed outcome or exact identity goes through the indexed `ReconcileResult` algebra and prepared
operations instead (§ EE). An absent-but-installable dependency is therefore
installed rather than reported as a manual prerequisite. The Python wrapper's host minimums (§ M) are the only intentionally non-installing
**pre-binary** prerequisite gate, not the system's only failure class. A reconciler fails closed on
wrong-host applicability, an irreducible/non-installable precondition, a conflict or safety refusal, or
failed post-install verification. NVIDIA device/driver visibility is part of
substrate detection (`hasNvidiaGpu`): a host is a GPU substrate when an NVIDIA kernel marker
(`/proc/driver/nvidia/version` or `/dev/nvidiactl`) exists, or, when neither exists, when `nvidia-smi -L`
succeeds and lists a GPU. On Windows the kernel markers do not exist, so `windows-gpu` requires that
`nvidia-smi` listing; a Linux host with a loaded driver is `linux-gpu` even when `nvidia-smi` is missing.
A host with no driver evidence is not a GPU substrate, so the GPU reconciler rejects it rather than
claiming it can install a driver for hardware it cannot yet identify. Once a GPU substrate is established, its installable toolchain
dependencies are reconciled normally. `ensure incus` is explicitly applicable
on **both** apple-silicon and linux — on Apple it prepares the Colima-backed Incus provider for explicit
Incus workflows, and on Linux it initializes the native daemon that encapsulates a fresh linux host (§ U).
It is not the only cross-substrate table: `Ensure.Docker` has three rows — `InstallHere` on Linux, and
`ProvidedElsewhere` on Apple Silicon (the per-project Colima provider wall) and on Windows (the WSL2
host-provider path) — so a reachable daemon is a verified no-op on every frame and only Linux installs one.
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
invoked within **chain steps** in `project up` (§ Y), not as hand-run verbs. The provider
reconciler reaches a **usable** provider, not merely an installed binary, and observes any egress the next
step requires before minting readiness. Incus's total capability observation checks client, daemon access,
VM capability, and image-server egress. The host-providers phase owns managed provider observations;
config-free reconcilers retain the individual probe limits described in
[ensure_reconcilers](../documents/engineering/ensure_reconcilers.md).

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
distribution operations. An operator or an agent may ask Python to update the installed application or build/publish
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
  conditionalized to build the binary host-native: each Cabal component that needs it declares it under
  `if !os(windows)`, and each module that imports `System.Posix` guards those imports and their uses with
  CPP.
- Inside a managed Linux VM (§ U) the same host-native build applies — Lima on Apple Silicon,
  native Incus on Linux. The VM is a fresh linux host: the pipx-installed `hostbootstrap` ensures the
  toolchain, builds the binary host-native, and hands off by POSIX `exec`; the binary then ensures Docker and builds the
  container in the VM. The worked demo's pristine-host bootstrap counts **3 builds** — a metal
  orchestrator build plus, inside the pristine VM, the host-native binary build and the binary-driven
  project-container build — a demo-only illustration, not the standard workflow.

### O. Resource Budget and Cordoning

**Owning phase**: [the step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md)

The plan has one opaque validated per-project budget (`cpu`, `memory`, `storage`) and no independently
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
`EffectiveBudget ... wallSpecId`. `verifyPlannedWorkloadFit` consumes that `EffectiveBudget` with the
same-plan `PlannedWorkloadSet` and yields only the matching `VerifiedWorkloadFit`. Partition construction
(`withBudgetPartition`) consumes those pure values and mints exact plan/frame resource slices before any
provider-wall acquisition or reconciliation effect. (`fitsBudget` in `HostBootstrap.Cluster.Cordon` is a
descriptive calculation over the Haskell mirrors (`HostBootstrap.Config.Vocab`) of the hand-written
`Core.dhall` vocabulary; it takes no plan index and yields no proof.)

**What runs today.** The proof chain from `ValidatedBudget` through `ProviderWallAuthority` and
`WslGlobalWallLease` is built as opaque kernels with their producers and consumers, exercised by the core
suites. No production lifecycle path mints a `ValidatedBudget` or derives a `PlannedWorkloadSet`,
`VerifiedWorkloadFit`, or `BudgetPartition`: the worked demo's cluster step mints its `ResourceSlice` with
`withActionResourceSlice` from the planned cluster resource and the cluster resources of its config
projection, and the direct-Colima consumer that requires
the full chain (`prepareColimaWallCall`) has no production caller; nor do the storage-wall kernels
`prepareStorageWallCall` and `settleStorageWallCall` in `HostBootstrap.Cluster.Budget`, which the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) keeps as a
target contract. `withValidatedBudget` ignores its `ProjectPlan` argument and sizes the budget from a
caller-supplied `ResourceEnvelope`, so one plan can mint several differently sized budgets against the
single-budget rule above; Sprint 12.30 of the step-algebra-and-project-plan phase owes deriving it from the
plan. Production budget enforcement is the metal preflight (`preflightHostBudget`), the provider sizing
renderers applied when a VM is created, the kind node cordon, and the WSL global wall through
`HostBootstrap.Wsl2.GlobalWall` under the § EE clauses. The in-frame cluster-capacity preflight
(`preflightBudget` over `verifyBudget`) runs only inside the compatibility `clusterCreate`, which only the
bare binary's cluster-live gate reaches; the worked demo does not run it. Production adoption of the
fit/partition chain is owed by the [worked-demo phase](phase-24-worked-demo.md). The canonical topic statement
of which controls apply is
[resource_budgeting.md § What runs today](../documents/engineering/resource_budgeting.md#what-runs-today).
The owned-cluster kind
backend applies that whole cluster slice to every node (`cordonOwnedCluster` renders one
`kindNodeCordonLimits` set and applies it to each node), so an N-node cluster's aggregate cap is N times the
slice, unlike `clusterNodeCordonArgs`, which divides it per node; that defect is owed by the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md). The
reservation, settlement, partition, and three-ring paragraphs below state the target contract those kernels
implement.

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

The current state of each budget element:

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
- the demo interpreter receives a descriptive cluster slice rather than a `BudgetPartition` proof (see
  "What runs today" above);
- `verifyBudget` is wired as the cluster-capacity preflight of the compatibility `clusterCreate`, which only
  the bare cluster-live gate reaches. `fitsBudget` is a descriptive calculation used
  by the demo web API and tests; lifecycle does not derive or check the exact non-empty concurrent workload
  set;
- a new Lima, Incus, or WSL resource is sized from the budget when it is created. An existing Lima or Incus
  VM is started with the sizing it was created with: a changed declaration is neither compared, applied, nor
  refused. An existing WSL distro keeps the VHDX size it was installed with. That silent retention is a gap against the "applied everywhere or typed refusal" ring below,
  owed by the [host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md);
- the direct-Colima consumer is one exact `ProjectPlan`, matching provider
  resource/topology, matching budget/capability/wall/workload-fit/partition, and `PreparedGate`-derived
  reservation plus provider-start package. It rejects total storage at or below the fixed 20-GiB root disk;
  the canonical wall is `--root-disk 20 --disk (total-20)`, with both quantities observed and bound. One
  128-bit plan/lifecycle namespace key owns the isolated `COLIMA_HOME`, reusable global lock, isolated
  `DOCKER_CONFIG`, and a socket-safe local profile. The private fixed resolver and bounded process-group
  runner feed one § EE ownership entry over the shared protected store
  (`HostBootstrap.Ensure.Colima.Ownership`), whose durable
  `reserved`/`home-staged`/`home-ready`/`context-staged`/`prepared`/`managed` stages bind the exact invocation,
  namespaces, root/data wall, machine/context identity, and complete artifact manifest. A profile present
  from `prepared` without a managed stage is outcome-unknown `Conflict`, never adoption. Only the hidden
  successful backend bridge may jointly settle the provider start and wall. Live Docker reuses the isolated
  context under the retained identity, and independently journaled `--force --data` cleanup enters
  `releasing` before mutation and conditionally releases the exact context, artifacts, namespaces, and origin.
  Missing clauses are `Unsupported`; mismatches are `Conflict`. The consumer has no production caller (see
  "What runs today" above);
- direct Linux GPU outer build/container effects are uncapped and return no typed `Unsupported`; only the
  later nvkind nodes receive CPU/memory caps. That is a gap against the "applied everywhere or typed refusal"
  ring, owed by the
  [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md). Bare Linux
  has no storage quota or image-GC wall, and the cluster consumer receives that as the typed
  unsupported-storage decision;
- WSL2 has no per-distro CPU/memory cap. Its global `%UserProfile%\.wslconfig` affects every distro. The
  production route holds the four § EE clauses behind one host-wide lock: it writes a durable origin
  record before mutation that distinguishes exact present bytes from absence, binds the managed target
  to its object identity and wall ownership, and re-observes under the same lock before conditional
  restore so a foreign replacement is preserved as a conflict;
- the normal WSL2 `project down` route releases the wall: teardown restores `.wslconfig` first and
  then runs `wsl --shutdown`, while the managed body derives finite six-hour VM and distribution idle
  timeouts from one constant rather than pinning them to `-1`. The
  [Windows-and-WSL2-substrate phase](phase-28-windows-and-wsl2-substrate.md)'s native-Windows gate on
  2026-08-01 observed the durable record removed, the exact absent origin restored, the distro stopped,
  and the WSL utility VM/memory balloon gone after `project down`. Lima and Incus release their walls on
  stop.

The target budget defense has three closed rings: promotion mints the sole provider-exact
`ValidatedBudget`; plan preparation runs `verifyBudget` and `verifyPlannedWorkloadFit` over the exact
non-empty workload/effect set and constructs the proved `BudgetPartition` (`withBudgetPartition`) before its
first dependent mutation; and runtime reconciliation first journal-acquires/revalidates the same
`wallSpecId` and then either applies the matching `EffectiveBudget` everywhere or returns typed
`Unsupported`/`Conflict`. The wall kernel settles an existing wall as unchanged (`WallAlreadyExact`),
migrated (`WallMigrated`), or refused. In production the first ring runs as the refined `Resources` and
exact `parseQuantity` arithmetic rather than as a minted `ValidatedBudget`, followed by the capacity
preflights; the second and third rings and the existing-wall settlement have no production caller (see
"What runs today" above). Lima and Incus own per-VM walls. WSL2 instead owns
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
unsupported-storage decision. Those source boundaries are implemented; their production adoption is the
gap "What runs today" names. The
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)
supplies the portable host-wall ownership protocol, while the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) supplies the
provider realizations. The [worked-demo phase](phase-24-worked-demo.md) owns the concrete demo workload,
overhead, partition, and slice projection, and the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
owns the scope-indexed configuration input. The
[step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) owns the single finalized
plan authority. A Dhall-native `fitsWithin` assertion is not attached to the generated project config
because that config contains text quantities and no resolved pod set; `deployConfigText` renders it only
into a standalone deploy config that carries an explicit budget and pod list.

Project budget interpretation remains Haskell-owned; Python does not size project VMs or clusters. On
Linux, the maintainer-only `hostbootstrap base build` separately measures host CPU/RAM and caps the
warm-store build container. On macOS and Windows the current command supplies no explicit Docker
CPU/memory caps and retains the Dockerfile's `-j1`; it must not be described as host-sized there. That
build-phase limit is not an interpreter of `<project>.dhall`; see
[base_image.md](../documents/engineering/base_image.md#host-sized-warm-store-budget).

### P. Fixed Command Surface And The Extension Streams

**Owning phase**: [the Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md)

`hostbootstrap-core` exposes a **fixed** command surface plus a project entrypoint
(`runHostBootstrapCLI progName projectSpec`). Every project binary — and the bare `hostbootstrap` binary —
surfaces the **same** tree: the three DSL-driven commands `project init|up|down|destroy`,
`test init|run`, and `service init|schema|run` (§ Y, § Z, § AA), plus the read-only `context`
introspection command and `check-code`. There are **no per-project verbs**: `hostbootstrap-core` is a
**library of composable tools** (step kinds, reconcilers, the self-reference lift, service handlers), not a
CLI topology, so a project never adds a command. The subcommands, flags, and per-command behavior are
canonical in
[hostbootstrap_core_library.md](../documents/architecture/hostbootstrap_core_library.md#surfaced-commands);
this section fixes only the shape of the tree.

**A closed set of internal entries is not a command.** A binary that crosses into a frame must be able
to recognize that *it is* the process on the far side, and no verb can express that: a verb is something
an operator types, and this is something only core's own launchers produce. `runCLI` therefore classifies a
closed, ordered set of five core entries out of argv before the parser runs: the installed identity
(`installedIdentityEntryArguments`), the exposure relay (`runExposureRelayEntry`), the Colima command
transaction (`shippedCommandEntryArguments`), the lifecycle child (`lifecycleChildArguments`), and the frame
child (`classifyFrameChild`). Each matches the whole argument vector or nothing, is absent from `--help`,
names nothing an operator could usefully type, and opens no route to a `ProjectSpec` extension stream. The
identity, lifecycle-child, and frame-child entries carry nothing on the vector — no coordinates, no path, no
authority, no caller-selected action — and the frame child refuses unless its standard input and output
decode as the protocol channel; it carries a transaction the caller already holds and returns that
transaction's outcome. Two entries carry caller-selected work, confined by their launcher: the exposure
relay's targets (validated for distinct services and listen ports; a malformed vector refuses rather than
falling through to the parser) are written only by `HostBootstrap.Cluster.Backend` as the relay container's
command, and the Colima command transaction's command arrives on standard input from the Colima backend's
bounded runner; both owners are Cabal-hidden or private-sublibrary modules no project imports. The set is
closed: a sixth entry is a change to this section, not to a module, and an entry a project's own `main`
intercepts before `runHostBootstrapCLI` is a per-project verb wearing a different hat. The worked demo
carries one such entry, which the [worked-demo phase](phase-24-worked-demo.md) owes deleting. The
inventory, with each entry's launcher and payload, is canonical in
[hostbootstrap_core_library.md](../documents/architecture/hostbootstrap_core_library.md#entries-before-the-parser).

A project extends the core only through the
**extension streams** finalized into opaque `ProjectSpec`: additive step fragments resolved to one
validated **lift plan** (`StepPlan`, § Y),
the **Dhall vocabulary**, the **schema-gen** `ConfigArtifact` registry, the **test seams** (a non-empty
test suite), and the **service runtime seam**: a possibly empty typed `ServiceRegistry`. Each definition
inseparably binds identity, structural field projection, reflected role codec, and handler; there is no
independent string selector. Registry finalization jointly binds the full `ProjectCodec`, role-wire
`RoleCodec`s, and canonical `specDigest`. A parent/local admission projects only a role-specific
descriptive wire; verification mints the opaque
`ValidatedServiceRequest specDigest configId secretDigest fields service`. `service run` reaches the
selection gate only through `runInstalledServiceProgram`, which first verifies the signed activation
revision, the measured binary digest, and the concrete instance identity against the protected store and
reindexes the finalized registry only when its retained digest equals the signed specification. The gate,
`withDecodedServiceProgram`, selects the one finalized definition the activation names, decodes only the
narrowed role wire through that definition's `RoleCodec`, and passes its continuation one existential
package: the `RoleCodec`, the `ValidatedServiceRequest`, the declared effect row `DeclaredEffects effects`,
and the `ServiceProgram payload service effects ()` built from the very `RoleParams` the request retains.
The one-use request-indexed `RolePlan` and the `VerifiedServicePlacement` then authorize that declared
effect row before the program is interpreted (§ AA). The handler receives only those `RoleParams specDigest configId secretDigest fields service`, never the
full config. The Dhall
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
- the **generated child config** `<project>.dhall`, materialized at VM and container boundaries from the
  finalized plan's exact child projection. Service and daemon roles use narrowed role-wire types. Each
  consumer receives its exact plan/frame resource slice and separately verified opaque authority;
- the **rich project/deploy** Dhall and one project-defined typed `<project>.test.dhall`. The latter maps validated
  `CaseId`/`VariantId` selections and overrides to generated run `cfg` variants through the
  project-owned projection (the Dhall-configuration-and-project-model phase); it is not one file per case. Selected top-level scalar/resource
  fields are checked at decode; exact workload fit is checked by the admitted plan and its cluster workload
  adopter. No generated `fitsWithin` assertion is claimed. Both are
  generated by the project binary from a reusable Dhall vocabulary. The ungated
  `context render` surface renders static registry examples; runtime deploy and child projections are
  emitted by commands that have already validated the active local config.

The project binary exposes two distinct schema surfaces and one default writer.
`context schema` prints the in-scope static `ConfigArtifact` registry; `service schema` prints, in order, the
registered service variant names, the validated-codec full project-local `cfg` schema (labelled as not a
service-role wire), and the `Production` and `Harness` role-wire schema families; and `project init` writes
a default full project config. The opaque lower-layer witness admits that schema only after the normalized `ToDhall`
`declared` and `FromDhall` `expected` expressions are judgmentally equal; semantic round trips remain a
separate test obligation.

The command tree remains fixed while trust domains stay separate. Static authoring uses
`ProjectSpec cfg tcfg`, with no lifecycle scope or specification phantom. Scope finalization computes one
canonical `specDigest` and yields `FinalizedProjectSpec scope specDigest cfg`, retaining the
matching `ProjectCodec`, finalized service registry, and identity-parametric plan builder. Service field
identity remains on the finalized service/runtime vocabulary rather than becoming a fourth
`FinalizedProjectSpec` parameter. `ProjectCodec scope specDigest cfg` validates the full root/Harness
config. Because the scope-indexed secret vocabularies differ, the full schema is an
explicitly named `Production`/`Harness` `ConfigArtifact` family in the
`context schema`/`context render` registry, never one scope-erased union. Each jointly finalized
project-owned `RoleCodec scope specDigest fields service` carries the codec witness of its
`RuntimeRoleWire fields`, derived from the hidden consumer-indexed field schema and typed service registry.
The role-wire families `service schema` prints are named `Production` and `Harness`, because their secret
vocabularies can differ; it never conflates them as one schema. Harness role schemas contain typed
secret handles, not an inline `ScopedTestPlaintext`; private run-scoped bundle bytes are a separate digest-bound
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

`specDigest` remains on `ValidatedConfig`, `ProjectPlan`, plan drafts/bindings/frames, the service
codec, request, and parameters (`RoleCodec`, `ValidatedServiceRequest`, `RoleParams`), and build authority. An activation manifest additionally binds
the measured `binaryDigest`, exact `configDigest`, and separate `secretDigest`. This document sometimes
uses shorter type names in explanatory prose; those are readability abbreviations only, never permission
to erase these indices. Same-shaped values of an indexed type from different finalizations, binaries,
config bytes, or secret bundles cannot cross-pair; the descriptive framework record below is checked at
runtime instead.

One descriptive framework record, `FrameworkValidation`, describes a wire: a closed wire-kind discriminator
(`FullProjectWire` or `ServiceRoleWire`), a closed Production/Harness scope-kind discriminator, the
`specDigest` text, and an unindexed `LocalContextView` (project, binary, source root, context kind, role name,
current frame). The full project wire carries no such record, so neither its scope nor its specification
digest is on the wire. The opaque `FrameworkEnvelopeCodec scope specDigest cfg` serves the full wire only: it
wraps the matching `ProjectCodec` with its scope kind, and `inspectFullConfig` projects a config that codec
decoded to a record reporting `FullProjectWire` and the codec's scope kind and digest. A role wire carries the
record on the wire: it is `RuntimeRoleWire fields`, the record plus the service fields, and `decodeRoleWire`
decodes it with the selected `RoleCodec` and then refuses it unless its wire kind is `ServiceRoleWire` and its
scope kind and specification digest equal that codec's. Those agreements are runtime comparisons of
descriptive fields, not type indices: `LocalContextView` carries no scope, digest, wire-kind, or frame index,
and it can neither expose service parameters nor mint command authority. Authority-bearing dispatch gets scope
only from its independently verified root/handoff/activation package; on the role-wire route it then requires
the wire's descriptive tag to agree.

No route may choose the wrong second-stage decoder. `service run` reads its wire only from a verified
activation, which selects the one `RoleCodec`, and admits it only through `decodeRoleWire`, so a full project
wire there fails the role codec's schema decode. In the target, project lifecycle and ordinary `check-code` run
a first-stage envelope check on the sibling config before invoking `ProjectCodec`: a file whose framework
record declares `ServiceRoleWire` receives a structured wrong-command refusal instead of being mislabeled
malformed full config, and a file without a framework record is a full project wire, which the second-stage
`ProjectCodec` judges. Today they decode the sibling config directly through `ProjectCodec`, and
`FrameworkEnvelopeCodec` has no production caller; the first-stage check and that caller are owed by
Sprint 7.15 of the [Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md).

Config-free `context inspect`/`context show` hold no run, so they decode with the binary's one Production
`ProjectCodec`; a Harness `ProjectCodec` exists only inside `withHarnessProjectCodec`, which takes a run's
`HarnessConfigAuthority`. Because neither the full wire nor `BinaryContext` carries a scope, the rendered
composition asserts none: a Harness-written config that is also a valid Production wire renders, and one that
carries a Harness-only value fails the Production decode. Today a role wire fails there with the same one-line
decode diagnostic as any file the Production codec cannot decode. Sprint 20.8 of the
[`test`-and-`context`-commands phase](phase-20-test-and-context-commands.md) owes two changes: the Sprint 7.15
check runs before that decode, so a role wire is refused as one and no decoder runs, and a decode failure
names the Production codec it ran.

### R. Quality Gate Contract

**Owning phase**: [the base-image-and-warm-store phase](phase-23-base-image-and-warm-store.md)

Static quality is a first-class requirement. The Haskell formatter is `ormolu`/`fourmolu` and
`hlint` runs against supported source roots, both installed in the base image from current compatible
upstream releases selected by the rolling build. Every image build is gated, and the two gates differ. A
derived image gates on the project's canonical `check-code` — a single in-Dockerfile
`RUN <project> check-code` stage whose body is project-defined. The base image has no project binary and
so no `check-code`: it gates on its warm-store build succeeding and on a `fourmolu --mode check` and
`hlint` pass over the warm-store sample sources (`core/warm-deps`). The standardized test harness's
`<project> test` report card is the project-level validation gate. The mechanical documentation
validator (`HostBootstrap.DocValidator`) runs through the code-check. The plan
distinguishes mechanically enforced gates from editor-only guidance, and § II from § JJ: the container
`check-code` owns the formatter and linter for a derived project, while the host static gate owns the
behavioural and source-shape suites on every supported outer host.

**This repository's own Haskell sources are inside that contract, not beside it.** The formatter check
and the linter run against `core/hostbootstrap-core` and `demo/` source roots in the repository's
canonical source gate, on the same footing as the Python `check_code`. A source root that no formatter
reads is a source root with no style contract at all, however carefully the doctrine is written — and
the library is the largest root the family builds on.

**The style contract is committed, not defaulted.** `fourmolu.yaml` and `.hlint.yaml` live in the
repository. Without them the contract is whatever the tools happened to default to on the day the
rolling base was last republished, so a base rebuild can change what passes with no repository change —
which makes the gate's verdict a property of the calendar rather than of the source.

**`-Werror` belongs in the build description.** It is declared in the `common warnings` stanza of
`hostbootstrap-core.cabal` and of `hostbootstrap-demo.cabal`, not supplied as a flag each caller
remembers. A gate that depends on a remembered flag is a gate that is weaker exactly when someone is in
a hurry, and it is why the same gate came to be written three different ways in three different
documents. `-Wpartial-fields` is declared beside it: a record selector on a multi-constructor type
throws at the call site rather than failing to compile, so the build refuses the shape instead of
leaving it to a test to find.

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
`ConfigArtifact` registry (concatenated across levels through `ProjectSpec`); the **test harness**, a
five-field `TestSuite` (safety probe, assertion-environment opener, non-empty case list, per-case assertion,
and post-reverse absence assertion; the per-case `Seams` are built internally by `HostBootstrap.Harness`);
and the **service runtime seam** (an additive, possibly empty
typed registry jointly finalized with the config/role codecs; the service-runtime phase adds the
activation-verified service program package that `withDecodedServiceProgram` yields, § AA). A project integrates through a Cabal dependency
(`source-repository-package` with a full immutable commit `tag` for a remote consumer, or a local
package in this repository) plus the `runHostBootstrapCLI` extension. A moving branch or omitted remote
tag is not a governed input. Scope finalization yields
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
  `reachLeaf` and the four blob leaf smart constructors (`blobUploadSessionLeaf`, `blobUploadPatchLeaf`,
  `blobUploadFinishLeaf`, `blobHeadLeaf`), which it adds to the ensure-reconcilers phase's `HostBootstrap.Lift`
  module itself, and `liftSubcommandWithAuth`, which lives in `HostBootstrap.Registry`. Registry imports lower
  Lift and its generic quoting helper; Lift never imports Registry.

Contexts compose as provider-backed frames, outermost-first; the empty stack is the local host. The VM layer
is provider-specific: Apple Silicon uses Lima (`limactl shell <instance> -- ...`) for the demo VM, native
Linux uses Incus (`incus exec <vm> -- ...`), and Windows uses WSL2 (`wsl -d <distro> -- ...`) provisioning a
fresh Ubuntu-24.04 distro. A **derived project container** is the `docker run --rm` layer whose project
Dockerfile installs the binary as its `ENTRYPOINT`; the base image itself exposes no freeze-driven
`ENTRYPOINT` integration mode (§ T).
The stack nests — host → VM → container folds to the selected VM provider command followed by
`docker run --rm <image> <subcmd>`. The finalized projector derives each exact child configuration and
plan. The root catalog binds its canonical payload, resource slice, digest, frame, and one-layer route
before effects. The authenticated process protocol carries that payload over the private duplex channel;
service and daemon consumers receive narrowed role wires through their signed activation revision.
Configuration remains descriptive and carries no protected-store or journal authority.

The argv fold is pure and honors § K: only the outermost host dispatch names a tool the resolver maps to
an absolute path; nested tools are interpreted in their own frame. `SubstrateProvider` plus the n-level
`LiftContext` frame stack and generic Lift fold is the one provider/dispatch abstraction. No public
`HostTarget = Local | InVM` or `runInTarget` path exists; source/API guards prevent a parallel dispatch
representation. L0 supplies the reusable context, fold, and provider primitives; the specific chain is
project logic.

The recursive-lifecycle-command phase supplies the root-owned durable coordinator, exact per-frame catalog
and journals, authenticated rooted grant/observation protocol, and storeless frame executor. A nested
process reconstructs and interprets only its exact projected frame; it receives no protected store,
lifecycle cursor, or durable-record operation. Managed operations consume the plan-minted descriptor,
exact freshly revalidated prepared pair, and structured reconciliation result. Config-free install helpers
retain their narrower local probe/install contract; they cannot mint managed lifecycle authority.

Recovery rehydrates exact journal, receipt, lease, and snapshot evidence before retry or refusal. Each
frame transition repeats provision → build/install → authenticated handoff, of which the Python
bootstrapper (§ M) is the metal-frame instance. See
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
No Production forward/reverse bridge over a `LifecyclePlan` and no public plan-only command-authority API
exists. The `Reconcile.LifecyclePlan` compatibility family itself is still exported from
`HostBootstrap.Reconcile` with only test callers, and the exposed `HostBootstrap.Lifecycle.Execution`
re-exports `newStepRuntime`; Sprint 12.27 of the step-algebra-and-project-plan phase deletes that family and
`carryManagedResource` and withdraws the public runtime constructors. Independently supplied plan, frame-context, and teardown interpretations violate this doctrine;
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
- the project Dockerfile installs the measured builder and config from the coordinator's read-only build
  context and fixed secret mounts. The config is descriptive; build-time `check-code` additionally
  consumes ephemeral `BuildInvocationAuthority` bound to the exact project, specification, config, build,
  source, coordinator, and builder. The resulting image digest is recorded afterward;
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
orchestration placement. `service run` reads no sibling config: it requires the framework context carried
inside its activation-bound role wire to name a `ClusterService` or `Daemon` kind and the activation's
frame (§ AA), while `project up|down|destroy` consult the closed `placementAllowsCommand` relation derived from the
validated topology rather than trusting the declared command-class list. The
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
owns that descriptive placement relation. The
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
supplies the independent lower root and reservation vocabulary. Sprint 12.14 supplies the pure plan/context
admission, and Sprint 12.21 supplies the broker-indexed plan-bound acquisition journal. Sprints 12.22–12.29
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
or mutation authority; the recursive-lifecycle phase's root entry supplies the independent authorization. The implemented
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
nor any independently composable journal/cursor package.

Service dispatch does not pass through that root admission. `verifyRuntimeRoleActivation` pairs a
broker-signed `ActivationManifest` with what the starting process measures for itself — its executable
digest, the role-wire and private-bundle digests, and its concrete instance (pod UID plus restart count, or
a protected OS invocation nonce) — and yields one
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId`. Those
seven indices are nominal, and the single private constructor holds the signed manifest, the
`MeasuredInstance`, and the protected-store identity together. The config digest, secret digest, service,
role-plan digest, effect ceiling, and private-channel locator are fields of that signed manifest, checked
by value at each consumer rather than carried as type indices. The manifest signs the immutable rollout
revision before a workload exists and never an instance identity. The project-owned `RoleCodec` decodes
the measured role-wire bytes into a `ValidatedServiceRequest` under a fresh existential `configId`; the
private bundle is measured against the signed secret digest and is not handed to the role. Before Prereq
or acquisition, `verifyRolePlanDraft` checks the non-empty draft against the signed role-plan digest and
effect ceiling without durable mutation. `withRoleLifecycleAdmission` then reserves the instance's one-use
admission under a key derived from the plan digest, frame, revision, and measured instance; its total
`RoleAdmissionOutcome` is Reserved, `RoleAdmissionOpenUnknown` (the matching row is already Consumed),
`RoleAdmissionRecoveryRequired` (a contradictory predecessor row), `RoleAdmissionRefused` (another
protected store), or `RoleAdmissionUnknown` (an unclassified store failure). `withRuntimeRolePlanForRequest`
checks the decoded request against the activation, compare-and-swaps the exact Reserved row to Consumed, and
mints `RolePlan scope specDigest planId configId secretDigest frame revision instanceId`,
`RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId`,
`VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects`, and
the sole Prereq cursor in one rank-2 continuation; duplicate holders of one reservation have one winner.
After `RoleAdmissionOpenUnknown`, `resumeRuntimeRolePlanOpenForRequest` reopens only that same consumed
plan. The binding states that the signed `rolePlanDigest` belongs to the parent `planDigest`; a narrowed
child never recomputes the full lifecycle-plan digest, never rebuilds a lifecycle `ProjectPlan`, and mints
no root authority. `runRoleLifecycle` then drives Prereq through Exit (§ AA); project callbacks never
receive a cursor or receipt and cannot skip Drain by throwing. Runtime verification mints no
`HarnessConfigAuthority` and does not replay a consumed edge handoff. Thus context
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
- existing-frame routes: `project up|down|destroy` and `check-code`;
- the activation route: `service run` reads the absolute platform coordinates
  `HOSTBOOTSTRAP_SERVICE_ACTIVATION` (one immutable installed activation revision),
  `HOSTBOOTSTRAP_ACTIVATION_KEY` (the independently installed verification key), and
  `HOSTBOOTSTRAP_AUTHORITY_STORE` (the protected store), plus its measured instance, and never the sibling
  project config. A missing, relative, or ambiguous coordinate exits 1 before verification (§ AA).

Existing-frame commands fail
fast with exit code 1 when the context file is missing, fails to decode, names a different
project/binary, does not declare the required capabilities, or does not permit the requested command. An
existing-frame command also fails when the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)'s
required local witnesses cannot all be verified. A
daemon/service command must refuse to start unless the context its role wire carries declares a
daemon/service role;
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
config is generated rather than hand-authored. The finalized projector verifies the exact child frame,
resource slice, payload, and execution digest. A service or daemon receives only its descriptive
`RuntimeRoleWire fields`: the framework envelope (`FrameworkValidation`) plus that service's own field
record. Its matching `RoleCodec` decodes those bytes and mints a fresh child-local `configId`;
neither the parent's `configId` nor a `ValidatedServiceRequest` is serialized.

The `context-init` action announces its declared frame boundary. Its descent and finalized child projector
belong to that same plan node; the root catalog verifies the payload and the interpreter owns authenticated
preparation and delivery. VM bootstrap establishes the executable and its initial local config; service
configuration is installed with the exact signed activation revision. Lifecycle payloads travel on the
private process channel, never `argv` or an environment variable. Production command adoption retains the
opaque `ProjectPlan` through the interpreter. The hidden authenticated frame entry binds signed delivery to the cataloged target
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
renders that plan through the same admission path (see the dry-run note under `project up` below);
effectful `up` persists/binds it, admits the root-refined lifecycle context, and enters the
Cabal-private root-Up `LifecycleEntry` producer/fixed interpreter. That producer alone derives the acquisition
journal/current cursor and calls generic `authorizeRootProject` before reaching public Chain. `down` and
`destroy` derive their
current-frame reverse work from the same exact plan representation. No Production compatibility command
authority, forward interpreter, descriptor, or teardown-plan producer remains. The
[test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns the corresponding
consumer for Harness: it retains the exact Harness-scoped plan across generated-config ownership,
interprets root Up through the same hidden fixed entry and retains the separate teardown route, and exposes no project-lifecycle
callback through `TestSuite`.

The current stable snapshot format (version 7, `canonicalPlanSnapshotFormatVersion`; the decoder refuses
any other version) binds that exact canonical root into the canonical bytes and
content-derived digest as a bounded, length-framed stream of big-endian 32-bit `Char` code points. The
structural parser exactly decodes the root, rejects empty, partial, NUL, oversized, and out-of-range
payloads, and accepts only an absolute root or the one shared non-absolute compatibility sentinel. The
current `Reconcile.LifecyclePlan` encoder uses that sentinel because its compatibility constructor receives
no `CanonicalProjectRoot`; an admitted `ProjectPlan` always uses its absolute canonical root. Sprint 12.27
deletes that encoder and its sentinel, after which admission accepts only an absolute root.

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
`openTeardownForest` returns `TeardownProjectUpHasNoReverse` before its empty-plan check. The one
exception is the failed-`up` projection: `failedUpTeardownPlanKernel` keeps the `ProjectUp` verb, projects
only the removable effects whose durable prepared gates that failed run reached (an ordered,
duplicate-free subset of the plan's operations), and opens normally; it cannot be promoted to Destroy
settlement. The pure plan and
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
  pair is refused during assembly. `--force` (replace an existing output) and `--if-missing` (keep an
  existing output) are mutually exclusive spellings of one `ExistingOutputPolicy`; supplying both is a
  parse error (exit 1), and supplying neither refuses an existing output. The
  [installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
  contributes no init-request or role-selection constructor. Python builds
  and invokes the host-native binary using the platform-specific handoff in § M; it does not initialize
  or trigger config creation. A normal
  existing-frame command fails fast (exit 1) when no sibling `<project>.dhall` exists (§ M).
- `project up` — the root coordinator interprets the chain recursively: run the steps for this frame,
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
  `--dry-run` renders the admitted plan's chain and runs no step, but it is not side-effect free and
  not outside Production. It skips installed-identity validation, then opens the authority store and
  enters the same Production admission path as effectful `up`: existing-bound recovery, or
  `withFreshProductionPlan`, whose `withProductionRoot` verifies the operator, acquires or retains
  Production mode, and records an unbound run lease. After a successful render that bracket releases
  neither, so a dry run leaves Production mode held with an unbound lease. A dry run that holds no mode,
  records no lease, and writes nothing to the authority store is owed by the
  [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md).
- `project down` — child-first recursive stop across every acquired frame. VM frames use the
  provider **stop** operation (incus/Lima **stop**; WSL2 releases the global wall with
  `ReleaseGlobalWslWall` and then runs the global `wsl --shutdown`, see
  [wsl2.md § Wall release](../documents/engineering/wsl2.md#wall-release); never destroy or unregister), so
  the guest and its disk survive. At the kind-cluster frame, `down` deletes the kind cluster, because kind
  has no reliable stop/restart contract; its removal set is **empty**, so no filesystem path is removed.
  Cluster-local persistence (for example a PVC on kind's default `local-path` provisioner) lives **inside
  the kind node container** and does not survive that delete. Best-effort and idempotent means every
  independent cleanup is attempted and any failures are aggregated and reported; it never means silently
  swallowing cleanup failure. The root coordinator drives the typed recursive acquisition unwind.
- `project destroy` — recursive `down`, then deletion of everything this run acquired,
  **including the provisioned frame
  and its disk** (`incus delete --force`, `limactl delete --force`, `wsl --unregister`, which removes the
  vhdx). The host-root `.data` is **inside** the single plan with an explicit `Preserve` policy and a
  verified receipt, but neither reverse projection places it in a destructive removal set. The demo now
  creates that host project-root, carries it through the provider share/alias and nested mounts, and
  retains it across frame teardown. The worked-demo phase records Production preservation and the Harness
  write → destroy → up → read-back acceptance. The canonical home is
  [durable_state](../documents/architecture/durable_state.md).

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
or the exact abandoned-run recovery authority, names the project, run, close origin, and broker epoch.
Harness close then takes two separate protected steps:

1. `authorizeHarnessClose` checks that root against the exact Harness mode lease and
   `BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration`, requires the supplied
   `VerifiedAllSessionsClosed` proof to name the bound lease's plan digest, rejects the true-pre-effect
   branch of the supplied `ProjectClosureEvidence` (only settled-destroy evidence is accepted), and records
   the fresh Harness Closing epoch in the run's invocation record. A persisted Closing epoch therefore
   proves ordinary destroy had already settled.
2. `beginClosingProject` then compare-and-swaps the project journal from `OpenProject` to that
   `ClosingProject` epoch against the caller's exact permit version. Session opening advances the same
   version, so a concurrent prepare and close have exactly one winner, and a permit retained from before
   destroy→up cannot close the new journal version. Repeating it with the same persisted epoch is
   idempotent; a different epoch is refused as a second close.

If step 1 succeeds and step 2 does not, the run is not lost: recovery's `resumeHarnessClose` re-reads the
persisted Closing epoch and yields the same close authorization without persisting a new epoch, and the
idempotent step 2 completes. The sole
`verifySubtreeSettled` producer checks the complete frame-bound plan projection against the exact ordered
terminal observations, retaining released, foreign-retained, and refused distinctions while rejecting any
failure or unresolved node. `verifyDestroySettled` then checks the exact plan digest, current frame, full-root
terminal sequence, and unique topology root before minting unframed project-wide proof.
`ProjectClosureEvidence` has three producers, each recording which way closure was reached:

- `verifyNoProjectResourcesAcquired` takes an `UnboundRunLease` and refuses if any effect-shaped or same-run
  acquisition record exists for it;
- `verifyBoundRunHasNoProjectResourcesAcquired` takes a `BoundRunLease` and refuses if any effect record or
  canonical resource record (including a released tombstone) exists for its plan; it is separate so neither
  lease state can be substituted for the other;
- `destroySettledClosure` is a conversion, not a verifier: it joins the bound lease with
  `VerifiedAllSessionsClosed` and `DestroySettled` after checking both name the lease's plan digest.

Unresolved partial ownership produces none of them.

The close projection releases the exact owned generated config and `.test_data/<runId>` generations
through the same durable intent/unknown/reprobe/fence protocol, specialized to the Closing epoch. Every
terminal close observation returns `HarnessCloseAdvance` on success or typed failure; its eliminator
yields the only successor close journal. A persisted Closing run resumes only its exact close
authority/journal; it cannot remint Open, general Harness, or `ProjectUp` authority. After all close
operations and sessions settle, one protected finalizer atomically records `ClosedProject`, closes the
bound lease, and releases the exact Harness mode epoch last. Production mode release instead requires a
closed `ProductionClosureAuthorization` with two constructors. `SettledProductionClosure`, built only by
`authorizeProductionDestroy`, holds four members: the exact `ProjectDestroy` root authority, the
`BoundRunLease`, `VerifiedAllSessionsClosed`, and `DestroySettled`, and it checks the root against the
lease's project, store, and epoch. `PreEffectProductionClosure` accepts the `ProductionRoot` of any
Production verb and is minted only by `authorizeProductionPreEffect`, which rechecks inside a protected
entry that the mode and unbound lease are the root's own, that no effect-shaped or same-run acquisition
record exists, and that every session is Closed. A true pre-effect `up` refusal can therefore close, but
partial `up`/`down` teardown cannot be relabeled as settled. The finalizer records Closed, closes its invocation
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

A normal root-frame `project up` failure runs the receipt-driven failed-`up` teardown (the
`failedUpTeardownPlanKernel` projection above) before it reports failure. Outcome classification is exhaustive and consistent: compatible but unowned state is
`ForeignResult`; an incompatible/occupied identity or contradictory ownership claim is `Conflict`; a
policy decision declining an otherwise authorized owned/absent transition is `SafetyRefusal`; a backend
that cannot provide the required strong semantics is `Unsupported`; and an attempted operation failure
is `Failure` with recovery disposition. Only a refusal proven to precede every acquisition has an empty
rollback set. A late policy refusal after journaled preparatory effects unwinds those exact owned effects;
it must not skip cleanup merely because its report label says refusal.

The **Step algebra** is the reuse unit: `hostbootstrap-core` ships the host-management step kinds
(`deploy-vm`, `ensure-*`, copy-source, build-pb, build-image, `context-init`, deploy-kind, deploy-chart,
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
  scoped overrides such as secrets. The test-config writer refuses an existing file by default;
  explicit `--replace` authorizes replacement of the test config only.
- `test run <case-id>|all` — runs one registered typed case or every registered case. Entry is
  root-only, fails fast without `<project>.test.dhall`, and rejects a non-root context before side
  effects. The root gate is not built: `testCommand` applies no binary-context root check to `test init` or
  `test run`, and Sprint 20.7 of the
  [test-and-context-commands phase](phase-20-test-and-context-commands.md) owes it. For each **distinct test
  configuration**
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
operation set. Registering an initial intent consumes the exact closed `IntentOrigin`—`NoHistory` (no
prior generation) or `ReleasedReacquisition`—and atomically adds the operation/generation to
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

Before every child reservation, mutation, or delete, the root prepares the operation in five ordered
steps:

1. **Verify the request.** The prepare request names the exact authority epoch, verb/phase/frame, session,
   journal/resource/generation/operation version, current authoritative fence, precondition-set identity,
   and call digest.
2. **Derive the precondition set.** The plan is the sole producer of the exact closed zero/one/many
   dependency snapshot and the jointly indexed `OperationPreconditionSet` and verified backend call. It
   traverses the descriptor's complete edge set and runs the plan-owned probes; callers cannot supply
   retained readiness or omit an edge, and its private no-dependency branch prevents fabricated
   requirements.
3. **Revalidate under one compare-and-swap.** One protected compare-and-swap consumes that set, reruns
   every target/dependency probe and observation version, obtains conditional backend versions, and
   revalidates the active project mode, bound lease, active plan revision (no migration freeze),
   Open-project state, command/session/fence, readiness generation, and record phase.
4. **Record unknown first.** That same transition records the exact operation-specific unknown state
   **before** anything is returned.
5. **Return the prepared pair and successor.** Only then does it return the
   resource/generation/operation/precondition-set/call-digest/session/fence/attempt/journal-indexed
   `PreparedOperation` and matching fresh `PreparedPreconditions` the adapter requires, together with the
   fresh-versioned successor Open-session, Open-project state, and revision-permit authority.

Every adapter terminal observation returns `OperationAdvance` on success or
typed failure; its eliminator yields the result only with the sole next state/permit pair. An adapter
accepts neither retained `Ready`/prerequisite data nor either half of the prepared pair. Initial fence
creation and `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved` rotation persist and resume one
stable proposed epoch while returning the sole successor state/permit pair; a delayed old permit is
rejected or deduplicated. Terminal acknowledgment first
verifies every registered outcome settled and then compare-and-swaps the exact Open-session version
Closed, so a retained proof or concurrent prepare cannot win. Loss before prepare refuses, while loss
after a prepared backend call leaves an explicit unknown state for total reprobe. Generative handles,
verified journal records (`VerifiedJournalRecord`; only the untrusted `PersistedJournalRecord` is
stored), and receipts are never serialized. The token is never in Dhall, `argv`, an environment variable, or durable config; teardown gets a fresh token, and a harness broker cannot sign Production
authority. Before allocating a new run, the root must recover/teardown any protected incomplete old
harness lease under that exact old run scope.

This contract is built by the authenticated-handoff-and-child-admission phase over the sessions/journal/
fences and prepared-operations phases beneath it, and consumed by the recursive-lifecycle-command,
recovery, and test-harness phases above it.

`context` is a **read-only** command that treats **every** `<project>.dhall` uniformly: it introspects the
explicit context and renders the global compositional sequence of lifts (`topologyFrames` / `parentChain`)
with the current frame highlighted, so an operator can see the whole `metal → VM → container → cluster`
chain and where this binary lands in it — regardless of which roles the config declares. It performs no
mutation. Child-config creation and authenticated delivery are internal plan-owned `project up` work;
the `context-init` action announces the descent bound to that same node (§ Y). It is not a
`context` subcommand.

### AA. Service Runtime Command

**Owning phase**: [the service-runtime phase](phase-22-service-runtime.md)

`service` is the third DSL-driven core command (alongside `project` and `test`). It runs a project's
**long-running roles** — the `HostDaemon`/service run-model (§ T). `service init` writes a
**service-configured** `<project>.dhall`; `service run` is driven by an installed, broker-signed activation
revision that carries the narrowed role wire, never by the sibling config:

- `service init` — writes one descriptive Production role wire from a selected service in the finalized
  registry, one legal `ClusterService` or `Daemon` placement, and role fields assembled/projected through
  that same spec. Callers cannot choose the hidden field row or arbitrary roles. Its
  writer-specific request has no overwrite flag and uses `RefuseExisting`. It does not sign or install
  runtime authority: an authorized controller/OS-service launcher must atomically pair those bytes with
  the broker-signed manifest and measured identity before `service run`.
- `service schema` — prints the full project schema with an explicit label and the
  finalized project-owned role-wire schema registry/union derived by `RoleCodec`, with separately named
  `Production` and `Harness` scope families; round-trip/anti-drift tests prove every runnable role wire
  agrees with the decoder for its exact scope (§ Q).
- `service run` — verifies the platform-installed activation coordinates (§ X) and runs the one role the
  signed activation selects. There is no positional variant argument. There is **no `service down`**:
  lifetime is owned by the enclosing Kubernetes controller or host project lifecycle and torn down by `project down` / `project destroy` (§ Y).

`service run` is a **leaf-frame runtime command, never an orchestrator**. Its only inputs are the platform
coordinates § X lists and a measured instance: `HOSTBOOTSTRAP_POD_UID` with
`HOSTBOOTSTRAP_CONTAINER_RESTART_COUNT`, or exactly one `HOSTBOOTSTRAP_SERVICE_INVOCATION_NONCE`. It hashes
its own executable and hands everything to `runInstalledServiceProgram`, which takes these steps in order:

1. **Verify the activation.** `withInstalledServiceActivation` rereads the digest-addressed revision's
   members (two manifest copies, signature, public key, `role.dhall` role wire, and `secret.bundle` private
   bundle), refuses a public key that differs from the independently installed one or a directory name that
   is not the manifest digest, and passes the measured binary, role-wire, private-bundle, and instance
   identities to `verifyRuntimeRoleActivation`. Success yields the seven-index
   `VerifiedRuntimeRoleActivation` described in § X.
2. **Match the registry.** The finalized registry is reindexed to the activation's signed specification
   digest; a mismatch refuses before any decode.
3. **Decode the selected role.** `withDecodedServiceProgram` selects the one definition named by the
   activation's signed service, decodes the measured bytes as that definition's `RuntimeRoleWire fields`
   through its `RoleCodec`, and yields one existential package: the
   `ValidatedServiceRequest specDigest configId secretDigest fields service` under a fresh `configId`, the
   declared effect row, the resource and payload backends, and the `ServiceProgram` built from the very
   `RoleParams` the request retains. An unknown or duplicated service refuses.
4. **Verify the draft.** `verifyRolePlanDraft` checks the definition's resource draft against the signed
   role-plan digest and effect ceiling, with no durable mutation.
5. **Admit and open the plan.** Inside one protected entry, `withRoleLifecycleAdmission` reserves the
   one-use admission, and `withRuntimeRolePlanForRequest` (or, after `RoleAdmissionOpenUnknown`,
   `resumeRuntimeRolePlanOpenForRequest`) checks the request's config digest, specification digest,
   service, frame, and `ClusterService`/`Daemon` context kind against the activation and mints the
   `RolePlan`, `RolePlanDigestBinding`, `VerifiedServicePlacement`, and Prereq cursor (§ X). Recovery-required,
   refused, and unknown admission outcomes exit before Prereq.
6. **Run the lifecycle.** The protected entry closes, then `runRoleLifecycle` drives
   Prereq → Acquire → Ready → Serve → Drain → Exit under `mask`, restoring each project callback
   individually so a catchable shutdown or exception becomes that callback's typed outcome. When the signed
   ceiling names an exclusive effect, the whole run is held inside `withRunLiveness`, a kernel lock named
   for the service and frame that the OS releases on process death; a live holder refuses before the first
   acquisition. In Serve, `authorizeServiceEffects` admits the declared row only if every effect is in the
   placement's signed ceiling, and `interpretServiceProgramWithReady` runs the program against only the
   handles Ready probed. After the first acquisition, every outcome reaches Exit only through Drain, which
   attempts every release despite individual failures and aggregates them in the `RoleExitReport`.
   `service run` prints that report and exits 1 unless it is clean.

The finalized project specification hides each project-declared role field type and jointly derives its
full `ProjectCodec` and `RoleCodec scope specDigest fields service`; callers cannot pair codecs or choose
`fields`. A `RuntimeRoleWire fields` holds the framework envelope (`FrameworkValidation`: wire kind, scope
kind, specification digest, and local context) and the service's own field record; each definition owns
the projection from `cfg scope` to that record, and plan/build/deploy-only fields are simply not in it.
The private bundle is measured against the manifest's secret digest and is not handed to the handler; no
step mints `HarnessConfigAuthority`. A `ValidatedServiceRequest` is an inseparable bundle of the framework
envelope, the measured config digest, and
`RoleParams specDigest configId secretDigest fields service`; neither member has a public independent
constructor, and neither crosses the process boundary.

A handler is a `ProgramServiceHandler payload effects fields`. It receives only
`RoleParams specDigest configId secretDigest fields service`, never `ValidatedConfig ... cfg`, and returns
a `ServiceProgram payload service effects ()`. That program type is closed: its constructors are private,
and it has no `IO`, `MonadIO`, arbitrary filesystem, or config-read escape hatch. Each effectful
constructor (`serve`, `call`, `readDurable`, `writeDurable`, `work`) carries a `HasEffect` constraint over
the declared `RoleEffect` row, so an undeclared effect is a compile error, and the only eliminator demands
the `EffectAuthorization` that `authorizeServiceEffects` mints from the signed ceiling. `DurableStore` is
executed by core against a `DurablePath` minted from the admitted canonical root; the network and process
families reach the definition's own `ServiceBackend`. Listener, peer, and worker arguments are
`AcquiredResource` handles whose sole producer is Ready, so Serve has no handler-visible open/bind/spawn
escape hatch. Therefore the public handler API cannot reopen the sibling path or pair a Web payload with an
accelerator handler.

An effect row is family permission, never mutation or retry authority. Rolling revisions and instances may
overlap for non-exclusive service work. Each measured instance has its own admission key, so a value
retained from one instance cannot run as another, and a genuine restart (a new restart count or invocation
nonce) receives a fresh admission rather than replaying the old one. Exclusive work is serialized by the
`withRunLiveness` lock held from Prereq through Drain.

**Target, not built.** The runtime above holds role receipts in process memory and journals nothing per
service effect. The target adds four protections:

- a durable per-call effect journal, in which each mutating durable-store, process, or backend call is
  sealed with its exact target and arguments, prepared under a fence before it runs, and resolved after a
  crash between the call and its acknowledgment by same-key reprobe or retry;
- durable role receipts, so the resources an uncatchably killed instance acquired are recovered rather
  than left behind; today Drain releases only what the running process holds;
- predecessor-instance recovery: today a contradictory predecessor admission row yields
  `RoleAdmissionRecoveryRequired` and `service run` refuses, with no core recovery path that enumerates,
  settles, and clears the old instances;
- an exclusive-lease transfer barrier that proves a predecessor's prepared or in-flight backend mutations
  are fenced before a successor mutates; today the liveness lock excludes only a live holder.

That target is owed by the [service-runtime phase](phase-22-service-runtime.md).

Core need not impose a universal service field: each definition's projection and `RoleCodec` define how a
full validated config projects its role wire and how a verified local wire yields its typed request.
Construction-time and property tests validate that mapping. The existential package binds the hidden row,
local wire, request, and role parameters together; callers never choose `fields` independently. Core cannot
infer that a project's projection is semantically accurate, so the generic guarantee is relative to the
project's declared definitions; the demo's role projections have compile-fail and projection tests.
`service run` diagnostics name the missing or malformed platform coordinate or the failed verification
step; they never imply that a descriptive file alone authorizes `service run` and never recommend root
`project init`. The registry may be explicitly empty; then the activation names a service this binary does
not register and `service run` fails before any handler.

`project up` and `service` **compose, they do not overlap**: the chain's `deploy-chart` step deploys the
pod whose entrypoint is `service run`. The step renders the narrowed role wire from the validated
parent-derived projection, has the root sign its activation manifest, and installs the immutable,
digest-addressed revision with `installRelayedServiceActivationRevision`; the pod template names that
revision, so a changed role wire is a new revision and rolls the workload. `service run` reads the role wire
from that revision, not from a sibling `<project>.dhall` baked into the image or mounted over it, and a
hand-maintained chart copy is not a second config authority. The child verifies that wire and creates the
request locally.
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
requires the exact generative run authority. Generated-config cleanup verifies recorded ownership and bytes,
and the demo derives its live cluster and durable root from the exact Production or Harness plan. The
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md)
owns cross-process child admission, the
[test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns Harness lifecycle
isolation, and the
[`test`-and-`context`-command-semantics phase](phase-20-test-and-context-commands.md) owns the command entry.
Their dated gates separately establish handoff, isolation, and command behavior; a configuration round trip
alone does not establish those properties.

The type spellings below are the source's current spellings. Where the prose abbreviates,
`Production` is shorthand only for the project-indexed `Production projectId`, and `Harness runId` for
`Harness projectId runId`. The full index is required at
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
  string selector exists: finalized project validation projects a role-specific wire; at runtime
  `withDecodedServiceProgram` selects the definition the signed activation names, and its `RoleCodec`
  decodes the measured wire into the opaque
  `ValidatedServiceRequest specDigest configId secretDigest fields service`, packaged with the declared
  effect row and the program built from the same `RoleParams` (§ AA). Core owns the role-wire envelope
  (`FrameworkValidation`) and the closed-program boundary but none of the project field names or value
  types; the handler receives only `RoleParams specDigest configId secretDigest fields service`, never the
  full `cfg` or arbitrary `IO`. An effect the declared row omits does not type-check, and
  `authorizeServiceEffects` refuses a declared row wider than the placement's signed ceiling.
  `ProjectConfig` / `Resources` / `DeployConfig` become the demo's concrete instance, not core types.
- **The resource budget is a provider concern (refines § O).** Budget/provider-cordoning is a field of a
  project's `cfg` carried by a provider lift, **not** a universal config field. A secrets-strict,
  RKE2/EKS-sized consumer carries no provider budget at all. For a project that does declare one, § O's
  sole admitted `EffectiveBudget` is the provider-effective wall: a per-VM wall on Lima/Incus, or an
  exclusively owned shared utility-VM wall plus a per-distro VHDX slice on WSL2. An incompatible
  concurrent WSL declaration is `Conflict`; it cannot overwrite the global wall.
- **DRY, scope-aware assembly.** A single project-owned
  `psAssemble :: forall projectId scope. AssemblyRequest projectId tcfg (TestVariant tcfg) scope -> ConfigAssembly scope (cfg scope)`
  is the only default-bearing function. `ConfigAssembly` permits only declared config/secret reads and
  exposes no general `IO`, `MonadIO`, or lifecycle/backend mutation; assembly therefore cannot hide an
  effect before the plan snapshot/journal/permit exists.
  `AssemblyRequest projectId tcfg variant scope` is the sole closed scope-input GADT, and its constructor
  fixes the result scope. `ProductionAssembly` carries only the parsed `InitArgs` and yields
  `Production projectId`. `HarnessAssembly` carries the exact `HarnessAuthority projectId runId`, the
  canonical project-root path, the decoded `tcfg`, and one opaque validated `VariantDraft variant` that
  already contains its stable variant identity and typed override payload, and yields
  `Harness projectId runId`.
  Identity and variant occur once, so two inputs cannot disagree. It has no generic role/class list,
  output path, overwrite flag, or service/test writer policy; those belong to the command-specific
  writers.
  `project init` and per-variant harness assembly are projections of that same assembler. The pure
  `TestCfg` method `projectTestMatrix :: [CaseId] -> tcfg -> Either TestMatrixError (TestMatrix (TestVariant tcfg))`
  receives the case IDs of `psTestSuite` (a project builds the opaque matrix with the `mkTestMatrix` smart
  constructor) and validates stable reporting IDs/references before effects; for each distinct variant
  draft the engine opens a **fresh** generative harness `runId`/lease, then calls
  `psAssemble (HarnessAssembly authority projectRoot testConfig draft)`. The exact
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
  Production wire schema has only `Vault | TransitKey | Prompt`; the untrusted Harness wire
  (`HarnessSecretRefWire`) adds a `TestPlaintext` alternative. Its Haskell counterpart
  `ScopedTestPlaintext` is minted only by `testPlaintextSecret`, which requires opaque
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
  record update. The
  [Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
  implements the root-local construction/codec boundary; the child handoff and plan transitions remain
  owned by their downstream lifecycle phases.
- **A project field that flows to the workload is a field of the project's OWN `cfg`.** A value the
  workload reads and renders (the demo's `message` the web service reads/renders) is a field of the demo's
  own `cfg`, never a core-owned field and never a generic extra slot — core owns no project-specific field.
- **A suite may declare more than one test config.** The demo's two clusters are two config variants; the
  Harness interpreter brings each retained plan up, runs assertions, and reverses it in turn, with
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
retained witness or select/omit a member. The second, public producer, `zeroDependencyPreconditions`,
accepts only a descriptor whose edge list is empty and refuses any descriptor that declares an edge. Thus
"act before the dependency is ready", choose an unrelated
dependency, or mix production and harness values is a **type error**, not a convention. The witness is
generative and bound to the exact resource identity observed; readiness for one VM, daemon, mount,
registry, or generation cannot authorize another resource with the same phantom tag. A plan-indexed
`Ready` is minted only by the polling transition (`awaitPlanReady`/`awaitPlanReadyWith`), and `planDependencyProbe` registers such
a probe in a plan's dependency snapshot. Production prepares register backend reprobes through
`dependencyProbe` instead (for the durable share, `providerShareDependencyReprobe`), and
`withOperationPreconditions` runs every registered probe at prepare time. The durable-share mount must gate
the alias step (§ DD).

What runs today falls short of that rule at the worked demo's own steps. The demo sequences its in-VM
project-image build, image push, and guest alias reconcile behind non-authorizing `ObservedReady` evidence
(`ObservedReady DockerDaemon`, `ObservedReady RegistryServing`, `ObservedReady DurableShareMounted`) rather
than plan-indexed `Ready`; core's managed provider and share operations do consume the prepared pair.
Moving those demo steps onto plan-indexed readiness is owed by the
[worked-demo phase](phase-24-worked-demo.md).

The canonical-quantities-and-reconcile-results phase foundation now removes `HostBootstrap.Readiness.Internal`, keeps every readiness constructor
private, validates `Micros` and `PollPolicy`, and fixes each `BackendProbeKey` to a closed planned-resource
family. A plan-indexed probe can be constructed only with the matching `PlannedResource` and positive
generation, phase, and observation versions; tests drive the real polling transition rather than minting
test witnesses. `ObservedReady` remains only as explicitly non-authorizing compatibility evidence for
local convenience helpers. Managed provider/interpreter operations consume the plan-owned prepared
pair; they cannot treat compatibility evidence as mutation authority.

The opaque witness retains the observed backend generation, resource phase, and journal version, but it
is only a precondition-set input. The plan-owned dependency probes run once, in the
`withOperationPreconditions` traversal immediately before preparation; `withPreparedOperation` is then pure:
it consumes the descriptor, that sealed set, and the `PreparedGate`, and checks that all three name the same
plan, operation, and call digest, that the attempt and journal version are positive, that every sealed
observation carries positive generation and phase versions, and that the sealed dependency keys equal the
descriptor's ordered list. Only success jointly returns the exact
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
`pollUntilReady`/`awaitPlanReady` polling loops plus a pure classifier over the probe output), not in an
inline shell loop.

**Failure is legible.** A bring-up failure never collapses to a message-less `ExitFailure 1`. Lifecycle
failures raise `LifecycleFailure` (the peer of the `SafetyRefusal` round-trip, § Z), which carries one
rendered reason string (`lifecycleFailureReason`); its `Show` form prefixes `lifecycleFailureMarker`, so a
parent runner finds the reason in a child's stderr and re-raises it across the subprocess and harness
boundary. The cause travels as text in that reason, not as fields a caller can match on. A runner that captures a child's
output **streams it, then dies with it** rather than folding it into a stderr the harness unwinds. The test
report card renders the carried message (`displayException`), so a failed variant states *why*. The
canonical homes are [readiness](../documents/architecture/readiness.md) and
[harness_workflow](../documents/architecture/harness_workflow.md).

### DD. The Durable-Share Primitive

**Owning phase**: [the host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md)

A host directory reaches a guest through **one** per-substrate share primitive on `SubstrateProvider` /
`HostPathShare`, modeled as pure data and interpreted generically (the lifecycle peer of the launch/cordon
effect lists, § U). It has three parts, and the substrates differ only in which parts they need:

- a **host-side reconcile** — Incus attaches a disk device post-create; Lima declares the mount at instance
  create; WSL2 needs none (drvfs already exposes the drive and the path rewrite already exists). The managed
  Incus and Lima shares run through the prepared provider share (`withPreparedProviderShare` and
  `runProviderShareCall`), whose Incus disk device is named `hb-share-` plus 12 hex digits of the share
  binding digest. The provider row's `ShareReconcile` field (the optional field shaped like the
  cordon-reconcile of § O) is the pure per-row plan; the worked demo reaches it only on its WSL2 route, where
  the row carries none;
- a **guest-side alias reconcile** — where a provider guest is present, its stable Docker-visible path is
  a symlink to the share, built from a `GuestAliasSpec` (`mkGuestAliasSpec`) and settled by
  `reconcileNodeGuestAlias` in `HostBootstrap.Substrate.Provider.Alias`. The pure `AliasState` classifier
  (`classifyAlias`) and its create/remove planners in `HostBootstrap.Substrate.Provider` have no production
  caller; they are a diagnostic view that the
  [host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) deletes (Sprint
  15.2). Direct Linux has no guest boundary and supplies the canonical host projection directly, so it must
  not create or consume this alias;
- a **mount-readiness** probe (§ CC) — the guest share is proven present and writable before the alias is
  scheduled, and the alias transition revalidates the same share identity immediately before mutation.
  The capability prevents logical out-of-order use; it does not pretend an external actor cannot unmount
  the share between unrelated system calls.

Managed share operations consume exact prepared-operation authority and revalidate the lexical provider/share
dependency package. Convenience helpers may return non-authorizing `ObservedReady`; that value cannot
substitute for plan-indexed `Ready` or the prepared pair. Direct-host root admission uses the same canonical
host root, while provider routes bind the host source to the verified guest mount/alias. The worked-demo
phase records destroy→up→read acceptance (§ C, § J). The canonical home is
[durable_state](../documents/architecture/durable_state.md).

### EE. Opaque Capabilities and Phase-Indexed Lifecycle State

**Owning phase**: [the installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md)
Capabilities are authority, not descriptive labels. Authority-bearing capabilities (for example
`RootInvocationAuthority`, `OwnershipReceipt`, and `AdoptionAuthority`), readiness witnesses, ownership
witnesses, and lifecycle-state tokens expose no constructors or record updates from a public or `Internal`
library module, and each index they carry is `nominal` under a `type role` annotation, so `coerce` cannot
re-index a held value. They are minted only by validated transitions, narrowed when crossing a frame, and
consumed by the operation they authorize. Tests use injected interpreters and typed fixture builders;
exporting a constructor “for tests” defeats the boundary. The `Capability` type in `HostBootstrap.Context`
is not authority: it is a descriptive, Dhall-decodable claim a context makes about its frame, exported with
its constructors, and it grants nothing.

**What runs today.** Three surfaces fall short of that rule. `HarnessAuthority` and
`HarnessConfigAuthority` in `HostBootstrap.Config.Authority.Internal` are newtypes over `Text` whose
project and run indices carry no `type role` annotation, so `coerce` moves a held value to another project
or run; the [Dhall configuration and project model phase](phase-7-dhall-configuration-and-project-model.md)
owns that module. The production `PreparedGate` producers are `withPreparedGate` in
`HostBootstrap.Lifecycle.Session` and `gateFor` in `HostBootstrap.Lifecycle.FrameExecutor`, both through
the package-private `mintPreparedGate`. The public `HostBootstrap.Lifecycle.Prepared` also exports
`recordDurableUnknown`, a public `PreparedGate` producer no library module calls, and the public library
re-exports `HostBootstrap.Protected`, so any consumer can open a store, enter `withProtectedEntry`, and mint
a gate under a plan digest, operation key, session, fence, and attempt of its own choosing; Sprint 17.72 of
the [recursive lifecycle command phase](phase-17-recursive-lifecycle-command.md) owes making
`recordDurableUnknown` package-private, because its callers and its compile-fail boundary live in files that
phase and the providers phase introduce. `HostBootstrap.Ensure.Colima.Ownership` is an exposed module whose entry points accept a
caller interpreter or `HostConfig` and which exports its observation constructors; Sprint 16.29 of the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) moves it into
a private sublibrary.

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
it **detects** rather than silently overwrites foreign replacement, deletion, or substitution of the bound
object. Clause 4 compares kernel identity only, so a foreign in-place edit that keeps the
`(volumeOrDevice, fileIndexOrInode)` pair passes it; an owner that must also detect in-place content
mutation adds its own content check after clause 4, as the generated-config owner does with a byte
comparison against the payload digest it recorded. It does **not** exclude a hostile
same-privilege process. No substrate supplies that exclusion, so no plan may claim it. A backend that
cannot satisfy all four clauses — an unsupported filesystem, an unavailable lock, an identity the
platform will not report — reports `Unsupported` and mints no receipt. Two parts of the tree fall short of
that rule. An unavailable lock or an unwritable state directory surfaces as the store fault
`OwnershipProbeFailed` rather than `OwnershipUnsupported`, and the Windows row trusts the volume serial and
file index without checking the filesystem type; both are owed by Sprint 14.21 of the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md).
The Lima and WSL2 guest-VM provider realization holds none of the four clauses: provisioning reports an
existing instance with the configured name as already owned (`ProviderProvisionAlreadyOwned`) with no origin
record, owner claim, or bound identity; holding the clauses there, or refusing an unclaimed instance, is
owed by the [host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md). The
Direct provider realization holds none by design: it claims nothing and answers stop and delete with
`Unsupported`. A pathname compare, content hash,
or immediate re-probe substitutes for none of the four; a content check can only supplement them. No plan
may claim compile-time exactly-once effects from phantom types alone.

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
adopts the ownership seam for it, and builds the adapter as a library boundary with no in-tree production
consumer: the core CLI dispatches only the adapter's shipped-command re-entry (`runShippedCommandEntry`),
the provider-neutral recursive lifecycle command holds no direct-Colima call site, and the worked demo
provisions its Apple Silicon path through Lima by design
([build_and_run_model](../documents/architecture/build_and_run_model.md#the-direct-colima-adapter)). A
production consumer would be a project's own step choice, and no phase schedules one; the adapter's live
coverage is the direct-Colima lane of the [Apple Silicon substrate phase](phase-26-apple-silicon-substrate.md).

The canonical statement of this contract, with its per-substrate realization, is
[ownership_invariant](../documents/architecture/ownership_invariant.md).

**Sub-contract owners.** This section's header names the phase that owns the opacity rule. The protocols
the paragraphs below summarize are owned, and reopened when they change, by their own phases, as
[system-components](system-components.md) assigns their modules: clause 1's exclusive-entry primitive (the
exclusively entered protected store and its liveness lock, `HostBootstrap.Protected`) by the
[protected-store phase](phase-4-protected-store.md); the reconcile result and error shapes,
resource handles, and the persisted journal graph (`HostBootstrap.Reconcile`) by the
[canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md);
mode, root, lease, and migration brackets (`HostBootstrap.Lifecycle.Mode`) by the
[lifecycle-modes-and-run-leases phase](phase-9-lifecycle-modes-and-run-leases.md); the session/fence
protocol — sessions, operation intents, and fences — by the
[sessions-journal-and-fences phase](phase-10-sessions-journal-and-fences.md); the
prepare compare-and-swap and `PreparedGate` by the [prepared-operations phase](phase-11-prepared-operations.md);
plan admission, snapshots, the acquisition journal, and cursors by the
[step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md); signed handoff, child
admission, activation, and build authority by the
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md);
the four clauses by the [ownership-clauses-and-reservations phase](phase-14-ownership-clauses-and-reservations.md);
the rooted catalog, frame session, and recursive traversal by the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md); recovery and resource-record
rehydration by the [recovery-and-migration phase](phase-18-recovery-and-migration.md); the role lifecycle by
the [composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md); and the service
command by the [service-runtime phase](phase-22-service-runtime.md). The canonical full algebra is
[lifecycle_state_model](../documents/architecture/lifecycle_state_model.md); where this section and that
page disagree, that page is canonical.

The lifecycle interpreter carries lifecycle scope, resource identity, ownership, and phase indices in
its state type: `ResourceHandle scope planId id resource ownership phase`. `Unclassified`, `Managed`,
and `Unmanaged` are distinct ownership states, and `Observed`, `Provisioned`, `ReadyPhase`, `Staged`,
`Built`, `Running`, `Stopped`, and `Destroyed` are distinct phase types; all eleven are empty data types
exported from `HostBootstrap.Reconcile`. A transition accepts only the predecessor
scope/plan/resource/ownership/phase it can legally follow and returns the successor state plus
capabilities retaining that same scope and plan.
Recursive descent and teardown use these values rather than reconstructing authority from a
`BinaryContext`, a file path, a process check, or a Boolean. A context may describe requested placement,
but only a validated local transition can mint authority to mutate it.

Every mutating reconciler returns `Either ReconcileError ReconcileResult`. A `ManagedResult` carries a
`ResourceHandle scope planId id resource Managed phase`, the matching
`OwnershipReceipt scope planId id resource`, and a non-authorizing `ChangeView`: `Changed` with
`Created`, `Repaired`, or `Adopted`, or `Unchanged`. The `ReconcileResult` constructors are hidden, and
each completion function fixes its legal from/to/outcome combination: adoption consumes matching
authority, and `Unchanged` requires a `PriorCommitProof` of committed ownership. A `ForeignResult` carries
only a `ResourceHandle scope planId id resource Unmanaged Observed` and a `ForeignObservation`; that handle
cannot be passed to mutation, stop, or destroy. The only `Unmanaged` → `Managed` transition requires an
opaque `VerifiedForeignOrigin scope planId id resource originId`, whose `originId` is a rank-2 generative
brand minted by `withVerifiedForeignOrigin` from that handle and observation, plus a matching
`AdoptionAuthority scope planId id resource originId operationKey` from `withAdoptionAuthority`, and it
reports `Changed Adopted`. Generation and observation version are runtime fields the origin retains;
`withAdoptionAuthority` compares them with the handle and refuses a mismatch as `Conflict`, so they are
value checks, not indices. Ordinary reconciliation cannot silently adopt. Idempotence never degrades a
resource validated as ours into an unmanaged observation.
`ReconcileError` distinguishes `Conflict`, `SafetyRefusal`, `Unsupported`, and `Failure`. A conflict
carries structured expected/observed identity and an
operator-safe remedy; a safety refusal records why an otherwise legal transition was declined; a failure
records the attempted operation, cause, and `RecoveryDisposition`. Observation is total (§ CC), so absence, not-ready,
unsupported, foreign ownership, and probe failure cannot collapse into one branch. A conflict or safety
refusal never triggers cleanup of the refused resource.

A mutation of any object in the Locked-Origin Identity Ownership list above holds all four clauses
first. The resulting ownership receipt records the exact plan/resource identity and generation and is
required by recursive teardown. Cleanup is therefore a typed
ownership operation: compatible unowned state remains `ForeignResult`, incompatible identity is
`Conflict`, a policy refusal remains `SafetyRefusal`, and an unsatisfiable clause is `Unsupported`.
Owned partial state is unwound in reverse lifecycle order and all cleanup failures are aggregated.

Because an external effect and the ownership record cannot share one atomic transaction, durable state
is an untrusted, generative-identity-free `PersistedJournalRecord` of plan digest, frame key, resource
key, generation, operation, operation key, record version, and phase. `verifyPersistedJournalRecord`
checks it against the exact `LifecyclePlan` (Sprint 12.27 owes taking the exact `ProjectPlan` instead),
`ResourceHandle`, and expected operation — plan digest,
resource key, generation, and operation must match, the record version must be positive, and the frame
and operation keys must be non-empty — and yields `VerifiedJournalRecord scope planId id resource`. Only
those four are indices; generation, operation, operation key, record version, and phase are runtime
fields that the check compares. The legal graph is enumerated by `legalJournalTransition` in
`HostBootstrap.Reconcile`, which is canonical for it, and `advancePersistedJournalRecord` refuses any other
edge as `SafetyRefusal`. Ordinary acquisition is `IntentRecorded → ReservationOutcomeUnknown`;
reservation unknown branches to `ReservationAbsent`, `Reserved`, `ObservedManaged` (reserve-is-create),
or terminal `ObservedForeign`; `Reserved → EffectOutcomeUnknown`; effect unknown branches to
`EffectAbsent`, `ObservedManaged`, or terminal `ObservedForeign`; and **only**
`ObservedManaged → Committed`. Cleanup is `Committed → TeardownOutcomeUnknown`, which branches to
`Released`, back to `Committed` when the same identity is observed (for retry), or to terminal
`TeardownObservedForeign` when the object was replaced. The graph has no absent-to-commit or
foreign-to-commit edge.

**Every retry is fenced.** In each of the five families — acquisition reservation, acquisition effect,
adoption, repair, and phase change — an authoritative absent or original observation returns to its
unknown state only through that family's explicit fenced state (`ReservationRetryFenced`,
`EffectRetryFenced`, `AdoptionRetryFenced`, `RepairRetryFenced`, `PhaseRetryFenced`), entered under the
same operation key after old-permit fencing. No observation has a direct edge back to its unknown state.

A later generation of an operation starts from `registerOperationIntent`, which takes a caller-selected
`IntentOrigin`, either `NoHistory` or `ReleasedReacquisition`. Inside the protected transaction it reads the
operation's record: `NoHistory` is refused when any record exists, and `ReleasedReacquisition` is refused
when a record exists whose phase is not `Released`, so an `AdoptionReleased` record does not qualify. Both
origins are accepted when no record exists. That is a runtime phase check over a caller-chosen origin, not
a typed proof of eligibility. Registration writes the intent and its session membership atomically. An
unknown or foreign generation has no rollover edge. Stable scope/plan digest/frame/resource/generation/
operation key — not `planId`, resource `id`, or handles — are persisted before a mutating backend call;
each unknown state is durable before its external operation.

Adoption is a separate journal transaction:
`AdoptionIntentRecorded → AdoptionOutcomeUnknown`; total reprobe then records
`AdoptionObservedManaged`, `AdoptionObservedAbsent`, or terminal `AdoptionObservedForeign`/refusal.
Only `AdoptionObservedManaged → AdoptionCommitted` can mint adopted ownership. Authoritative absence
permits an explicit retry under the **same** adoption operation key only after `OldPermitsFenced` proves
that a delayed transfer cannot land; without that proof it is `Unsupported`/operator resolution, not a
new attempt. Foreign observation and policy refusal (`AdoptionRefused`) are terminal. Cleanup is
`AdoptionCommitted → AdoptionTeardownOutcomeUnknown`, which branches to `AdoptionReleased`, back to
`AdoptionCommitted` on the same identity, or to terminal `AdoptionTeardownObservedForeign`, and there is
no adoption edge from an ordinary `ObservedForeign` acquisition entry.
Only an ordinary `Released` record admits `ReleasedReacquisition`; over an `AdoptionReleased` record,
`registerOperationIntent` refuses both origins. Neither unknown phase can roll over.
Receipt rebinding requires a `VerifiedJournalRecord` and the `PriorCommitProof` that `withPriorCommitProof`
mints only from a record in `Committed`. A phase transition, teardown entry, same generation under another
resource/operation, or foreign observation cannot mint a receipt. A record in `AdoptionCommitted` yields no
`PriorCommitProof` today, so an adopted resource cannot be rebound as `Unchanged`; the rebinding of a
matching adoption transfer is owed by the
[canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md).
Operational failures carry their recovery disposition and never erase journal state.

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
can enter acquisition/adoption commit, teardown release, or a reacquisition origin. Kill recovery reprobes
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
Harness opener, `withHarnessRoot`, generates the run identity and yields only the matching existential
`HarnessRoot projectId runId brokerGeneration verb`, which bundles the Harness `RootInvocationAuthority`,
the `HarnessAuthority`, the run identity, the mode lease, and the `UnboundRunLease`. The public root
brackets are composite: they
invoke the lower authority kernel inside the protected mode/lease transaction without exposing an
intermediate state. Only the
[lifecycle-modes-and-run-leases phase](phase-9-lifecycle-modes-and-run-leases.md)'s fresh profile openers
can combine the exact root scope/authority,
active mode, and still-unbound lease into the matching `LifecycleProfile`. The opaque profile retains the
opening lease's exact installed-project name, protected-store identity, and broker epoch; fresh
`ProjectPlan` admission carries those values privately so the effectful snapshot leaf can reject a
cross-store pairing even when project text and numeric epochs coincide. Sprints 12.7–12.20 of the
[step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) provide plan admission, stable snapshot bytes, pure `PlanDigestBinding` verification, the indexed bound
snapshot plus ordered fresh persistence/binding, read-only admission of an existing Production snapshot,
pure refinement of its exact indexed Open package into the recovered Production profile, safe restart
config/specification refinement, and fixed-identity recovered plan reconstruction.

`withPersistedPlanSnapshot` first uses one protected entry to revalidate the unbound lease,
store and flush the private indexed snapshot, and read it back under its exact bytes/digest. After that
entry closes, it compare-and-swaps the separate lease record through the existing fresh-only
`bindRunLease`. Snapshot durability and lease binding are ordered durable transitions, **not** one atomic
multi-record transaction. A crash between them leaves a classified persisted-snapshot/unbound-lease stage
that recovery may resume or refuse; only full completion yields the matching bound snapshot, binding, and
lease evidence.

Existing-snapshot admission through `withBoundPlanSnapshot` starts from only the protected
store and installed Production identity. In one protected-record-read-only entry it requires the existing
authority binding, exact currently allocated broker generation, Production mode and bound-lease epoch,
canonical snapshot bytes and content-derived digest, and durable invocation disposition. A terminal
acknowledgment is routed after that entry closes to a close-key-only callback and generates no plan
identity; only a verified Open invocation generates the sole local `planId`. The fully indexed
`BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration`, recovered Production
profile, and plan reconstruction retain that identity; neither the recovery-profile opener nor
reconstruction quantifies or mints a second `planId`. The pure recovered-profile refinement
requires the exact Production `ProjectUp` root, active mode, existing-bound lease, verified/bound snapshot
and binding, and that recovery value. It revalidates the retained project, store, Production run, stable
identities and bytes, broker epoch, and binding origin, then yields only the correspondingly indexed
recovered profile. It opens no protected-store entry or one-use slot and cannot inhabit Harness or teardown
scope. On restart, an independently repeated finalization retains the same stable specification text under
a distinct local phantom. The hidden recovery token is issued only after exact profile/finalized
codec digest agreement and independently checks the abstract validated config's retained specification. The
public input bridge preserves the config's `configId`, canonical digest, and value while regenerating drafts
from the finalized builder. Fixed-plan reconstruction then requires exact root-bound canonical bytes/digest,
origin, verified/bound snapshot, and binding agreement before yielding the existing-admission `planId`; it
opens no journal, cursor, migration, fence, or effect authority. Production dispatch consumes that one
identity through dry rendering or snapshot persistence and the hidden root-Up `LifecycleEntry`; the entry
alone derives journal/cursor/authorization and supplies the lower Chain interpreter. Reverse verbs derive
current-frame work from that exact plan without minting teardown command authority.
Phase 12 owns the exact local current-frame `project up` authority substrate; the
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
command-authority/lifecycle-validation cycle. Sprint 12.21's lifecycle boundary opens
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
source binding; Sprint 12.23 opens
`LifecycleCursor scope planId frame brokerGeneration verb phase` only from that journal and the matching
`ProjectFrame`. The journal row is the initial seed only until a frame's cursor row exists; thereafter the
strict canonical per-frame row is authoritative. Existential current-phase recovery avoids phase guessing,
and exact resume is no-write. At-most-once compare-and-swap transition reservation is deliberately distinct
from at-least-once callback delivery after unlock. The root-only reservation boundary checks the bound
lease's full retained origin, then revalidates live mode/lease/snapshot, source journal, and exact current row
with the one-use reservation. Its result remains inside the fixed root interpreter; pure frame evidence and
the descriptive lifecycle context authorize nothing and contain no store. `withProjectPlan` consumes the
profile/config/draft into the exact `ProjectPlan scope specDigest planId configId cfg`. The target is that
every consumer cluster name, path, and profile is a projection of that plan, with no independent argument
that can disagree with it. Today the demo's `containerPlan` takes a separately derived `ClusterProfile`
(its call sites pass `clusterProfileOf` of the config) and the context's source root, so the profile and
the plan can disagree; the [worked-demo phase](phase-24-worked-demo.md) owes the plan-owned projection.
Harness retains its exact Harness-scoped plan
through generated-config ownership and invokes the same fixed root-Up entry interpreter, leaving
`TestSuite` assertion-only. The lifecycle value's raw constructor is confined to a Cabal-private internal
component, and the public facade exposes only the opaque value and its engine eliminators.
Harness config assembly before binding is restricted to `ConfigAssembly`; normal failure closes the
unbound lease only after protected proof that no token, prepared attempt, same-run plan-bound acquisition
record, resource-operation journal, or effect exists, while a crash leaves an explicit unbound incomplete
lease for the recovery sweep.

In-process authority is non-serializable. For recursive child-frame transitions, the independently
authorized root retains the protected `RootBroker`, bound lease, signing key, protected store, root
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
session remains a required member. Initial intent registration checks its `IntentOrigin` and writes
session membership atomically with the generation. A persisted initial intent with no fence is an explicit
recovery state; the classifier idempotently completes the stable initial-fence protocol
(`establishInitialFence`) before continuable work receives its `FenceEpoch`. It also verifies/rebinds the
complete resource-record set; only the matching bound snapshot and that opaque set can yield a recovered
frame and a closed owned-or-released evidence sum for the forest's exact authorization point. The owned
branch alone yields a managed handle/receipt; the released branch alone yields the verified tombstone,
after which a new generation enters only through `registerOperationIntent` with `ReleasedReacquisition`.
Only both complete
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
knowledge of the coordinates is not another gate origin. (The public `recordDurableUnknown` producer named
under **What runs today** above is the gap in this rule.) The executor runs the plan-owned local probes and
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
revalidate the exact `ProjectUp` migration root, active mode, old-bound lease/snapshot/binding, and that
the bound lease's binding origin is `FreshBinding`, without a new plan. The pre-freeze `withProspectiveMigrationPlan` bracket
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
owned-or-released disposition, and complete `recordSetDigest`. A plan-owned exact-set fold verifies each
complete `VerifiedResourceRecordBundle` once, and the frozen lease (`LeaseFrozen`) pins the resulting set
digest, which commit and frozen recovery recompute and compare; no per-member staging record is written.
Owned members carry their receipt, released members carry only their tombstone, and
missing/duplicate/extra/unknown/disposition-mismatched members refuse.
Live migration binds the already-built candidate through `withPlanMigration`, which reloads it under its
stable key and compares its digests with the candidate before returning the `FrozenMigrationRunLease`, and
`commitMigrationActivation`, which consumes that frozen lease; it never reconstructs a plan after freeze. Abandoned Production
`ProjectUp` must first load the exact persisted prospective `VerifiedPlanSnapshot` named by the
incomplete recovery record and then use the exact bound-recovery profile plus
`withRecoveredMigrationPlanSnapshot`. It may reconstruct only when the provided config/drafts render
that loaded snapshot. These gates produce only migration-local plan/binding values, and prospective,
frozen, and staged records authorize no effect. Freeze replaces the old bound lease with one exact
stable-keyed `FrozenMigrationRunLease`. Only one protected transaction over the complete set can swap
the frozen lease to the `LeaseMigrated` lease and record `CompletedMigration` under the same stable key,
switching the lineage old→new, consuming that frozen capability, returning only the new-bound lease, and
yielding one old/new-indexed `PlanMigrationBarrier`; old- and new-bound authority cannot coexist. The old
resource records stay in place under the superseded plan digest with their owned/released dispositions;
nothing is archived. In the tree `commitMigrationActivation` makes the lease swap and the revision write as
two separate writes, and the incomplete-migration readers refuse the intermediate state; Sprint 18.12 of the
[recovery-and-migration phase](phase-18-recovery-and-migration.md) owes the single transaction.

`activateMigratedPlan` must consume that barrier, the exact new-bound lease/active revision, local
plan/binding, and complete set before exposing a journal or preparation authority. It rechecks that no old session
remains Open and jointly yields the new revision's `CurrentBrokerSessionAdmission`; completed configless
recovery must produce the same admission before opening a teardown session. A pre-CAS restart resumes
the frozen old-active migration under a fresh local migration identity; `ProjectDown`/`ProjectDestroy` may instead cancel
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
`RecoveryHandoff` in `HostBootstrap.Handoff` is a constructor-hidden phantom payload discriminator, not a
wire tag. On the wire, a recovery handoff is the `RecoveryRequestTag`/`RecoveryResponseTag` pair of the v1
`ProtocolTag` set, and its signed `HandoffBinding` names the `RecoveryAdapterWire` payload kind where a
config handoff names `NarrowedProjectConfig`. The
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md)
owns every v1 `ProtocolTag` and pins each one's round trip and negative paths; the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) and the
[recovery-and-migration phase](phase-18-recovery-and-migration.md) consume them. A nested teardown descent
(§ X, § Y) and a nested recovery cross the same parent→child edge over that one v1 tag set; neither mints a
private tag.
Controller-managed service restarts use a separate platform/OS verifier, and § AA is canonical for the
`service run` sequence. The signed manifest authorizes an immutable rollout revision; the independently
measured instance contributes the pod UID plus restart count, or an invocation nonce. With the pinned,
independently installed Activation verification key, `verifyRuntimeRoleActivation` yields one
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId`, whose
signed manifest, measured instance, and protected-store identity cannot be separated or mixed.
`withDecodedServiceProgram` decodes the measured role-wire bytes through the scope-correct `RoleCodec`
into a fresh `ValidatedServiceRequest`; the child does not recompute the full lifecycle plan from its
least-authority wire. `verifyRolePlanDraft` checks the definition's draft against the signed role-plan
digest and effect ceiling without durable mutation. `withRoleLifecycleAdmission` then reserves the
one-use admission — a contradictory predecessor row yields `RoleAdmissionRecoveryRequired` and refuses —
and `withRuntimeRolePlan` consumes that admission plus the verified draft, yielding only
`RolePlan scope specDigest planId configId secretDigest frame revision instanceId`, the matching
`RolePlanDigestBinding`, and a same-`planId` `VerifiedServicePlacement`. `runRoleLifecycle` is the only
runner: it drives the masked Prereq-to-Exit sequence over that plan and placement. Each measured instance
has its own admission key, so a value retained from one instance cannot run as another, and non-exclusive
rollout overlap is permitted. When the signed ceiling names an exclusive effect, `leaseRequirementOf`
yields `RequiresGenerationLease` and the whole run is held inside `withRunLiveness`, a kernel lock the OS
releases on process death; a live predecessor holder makes the successor refuse before its first
acquisition. That lock excludes only a live holder: the exclusive-lease transfer barrier that would prove
a dead predecessor's prepared or in-flight mutations fenced is target, owed by the
[service-runtime phase](phase-22-service-runtime.md) (§ AA). Activation alone cannot authorize effects or
execution. A restart cannot construct a lifecycle `ProjectPlan`, root authority, or lifecycle mutation.
The Dockerfile-time gate uses an
ephemeral, project/spec/config/build/source/builder-bound `BuildInvocationAuthority` joined with its exact
`ImageBuildFrame projectId specDigest configId frame`, never the baked config alone.
`verifyBuildInvocation` checks the delivered `BuildChannel` against an independently installed Build key,
locally supplied project/spec/config/coordinator identities, and fresh measurements of the source context and
builder binary; only its rank-2 continuation receives that pair. `authorizeCheckCode` and
`authorizeBuildPhase` then authorize each narrow phase at most once. Phase 13 owns that reusable protocol;
the worked-demo phase owns the static command consumer, delivery to, and consumption by the actual
derived-Dockerfile `check-code` route. Both demo build lanes deliver the signed channel through fixed
BuildKit secret mounts and consume authenticated check-code authority; ordinary host developer checks remain
config-gated local actions. The canonical full algebra is
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

**Three selections do not roll.** The bootstrapper's base-image module (`hostbootstrap/base_image.py`)
fixes them as constants rather than discovering them:

| Fixed selection | Value source | Why it is fixed |
|---|---|---|
| GHC version | `GHC_VERSION`, shared with the host bootstrap | it keys the warm store (below) |
| LLVM major | `LLVM_MAJOR` | the LLVM toolchain packages are installed by major version, so a new major is a deliberate bump, not a discovery |
| Ubuntu release line | `CPU_BASE_IMAGE` for the CPU parent; the CUDA parent is the newest `cudnn-devel-ubuntu24.04` tag | the parent never moves to a newer Ubuntu LTS without a source change; within the line, the parent tag and the CUDA version still roll |

Every other version is discovered so that a rebuild finds what consumers will actually resolve against.
**The compiler pin is a different kind of selection.** GHC arrives as an explicit build argument carrying
the same version the Python bootstrapper installs on the host and the guest bootstrap pins in a VM, and the
image build verifies the installed compiler reports it. The compiler *keys* what the base ships. A Cabal store lives at `store/ghc-<version>-<abi>/`, so a base whose compiler drifts from the one
consumers select ships a warm store none of them can read, and a workspace that names its compiler
explicitly cannot even be configured inside the image. The pin also costs nothing in maintenance: the
version was already written down twice for the host and the guest, and this makes the base agree with
them rather than hold a third opinion. Cabal continues to roll, matching the host, which pins no Cabal
either.

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
endpoint — `NetworkScope` is exactly `HostLocal`, `VmLocal`, `ClusterOnly` — and keeps that index on
opaque endpoint, exposure, and client values. The three name the three places a client can stand: the
machine running the binary, the provider guest, and inside the cluster. There is no scope for "public",
because nothing this algebra admits is reachable from outside the host it was brought up on, and an
unreachable fourth tag would be a proof obligation nobody can discharge.

A finalized `RegistryPlan` jointly binds the client, verified published exposure, backing object-store
endpoint, blob-delivery strategy, and a positive plan revision. It carries no credential: the demo's
in-cluster registry is anonymous, and the Docker Hub credential forwarded to nested image pulls is a
separate policy ([registry credentials](../documents/engineering/registry_credentials.md)).
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

A `Redirect` delivery strategy is constructible only from a `Reachability` proof that the client scope
can reach the backend scope. There is no proof from `HostLocal` to `ClusterOnly`; that topology can
construct only `Proxy`. `renderStorageRedirect` is total over delivery strategy: proxy delivery emits the
`storage.redirect.disable: true` stanza, and redirect delivery emits no `storage.redirect` stanza, which
leaves Distribution's redirecting default in force. The boolean is output, never an input to the DSL.

Static coherence does not replace runtime identity. The plan-owned route probe verifies the exact
client→exposure and registry→store paths, rejects an out-of-scope redirect, and `settleBlobRoute` yields a
`ReadyBlobRoute client store lifecycleScope planId clusterId service` only at the plan's current revision,
which the witness retains as a runtime value rather than an index. A bare `/v2/` response cannot satisfy an
image operation precondition. The
[composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md) owns the generic
reachability and delivery algebra, the
[canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md)
owns the identity-bound readiness/precondition machinery, and the [worked-demo phase](phase-24-worked-demo.md)
owns the demo renderer and the live proof along host client → resolved relay exposure → internal NodePort
registry → cluster-only S3 store. The canonical architecture is
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

**A coordinate carried across a sealed boundary is a type, not a primitive.** Hiding a constructor stops
a stranger forging the value; it does nothing about the authorized minter transposing two of its
arguments. A producer of the shape `Text -> Text -> Text -> Word64 -> Word64 -> Word64 -> Sealed` accepts
every permutation of its own coordinates, and when the canonical renderer beside it has the same untyped
shape, a transposition is self-consistent from mint to wire and no test distinguishes it. So each
coordinate role — a plan digest, an operation key, a session, a fence, an attempt, a journal version —
gets its own newtype, shared by the producer and the renderer. It costs nothing at runtime and converts
an argument-order defect into a type error.
[unrepresentable_state.md](../documents/architecture/unrepresentable_state.md) states the same rule about
indices: an index on a type whose accessors return plain `Text` is documentation, not enforcement. It
applies to the values a sealed producer consumes for exactly the same reason.

**A registered compile-fail fixture pins the diagnostic it expects.** A fixture that merely fails to
compile proves nothing, because a typo satisfies it equally. The rule is one contiguous expected phrase per
rejected binding, matched inside one diagnostic: an expectation split into separately matched fragments is
weaker, because an unrelated error elsewhere in the output can satisfy each fragment independently. A
boundary whose fixture pins nothing is a boundary with prose where its proof should be.

What runs today is weaker than that rule. `rejectsWith` takes a list of expected fragments, and
`rejectsWithUsing` in `CompileFailSpec` requires each fragment to appear somewhere in the whole compiler
stderr, matched independently with `isInfixOf`. Several registrations list bare tokens rather than complete
phrases. Re-joining them into one phrase each, matching per diagnostic block, and giving the combinator a
non-empty argument are owed by Sprint 5.10 of the
[installed-identity, operator-verification, and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md).

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
stdio disposition, file-descriptor inheritance setting, session, and console detachment, so none of those is
a parameter. Its working directory and environment are `detachedLaunch` parameters, constrained rather than
fixed: an absolute `DetachedWorkingDirectory` and the child's complete environment, because a detached child
never inherits the launcher's. Each of `System.Process`'s other `StdStream` constructors is wrong for its own reason: `Inherit` retains
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
assembles its host-side process internally (`frameChildProcess` in `HostBootstrap.Handoff.Transaction`,
`childProcess` in `HostBootstrap.Handoff.Process`): stdin and stdout are its own pipes, stderr is inherited,
the child leads its own process group, and descriptors are closed. That host-side process sets no working
directory and no environment, so it inherits both from the launcher; the inherited environment is neither
sanitized nor plan-derived. Only an admitted container layer of the route fixes a working directory: its
container process runs with `-w /` (`HostBootstrap.Handoff.Process.Route`).

Protocol success is also an unrepresentable boundary rather than an exit-status convention: a child's
completion counts only as a sealed, root-owned durable state transition, never as a process exit code. The
root coordinator alone writes those transitions, and a process owner receives only sealed received packages —
no protocol channel, durable record operation, or store locator. The protocol vocabulary
(`HostBootstrap.Handoff.Protocol`) and the rooted receipt (`HostBootstrap.Lifecycle.Rooted.Receipt`) are hidden
modules, proved by the compile-fail fixtures `ImportHandoffProtocol.hs` and `ImportLifecycleRootedReceipt.hs`.
The transition sequence (Published, `FrameComplete`, `ReceiptConfirm`, Received, `ReceiptRecorded`, and the
parent's Reported, Acknowledged, Adopted slot) is canonical in
[composition_methodology](../documents/architecture/composition_methodology.md#the-recursive-project-up-interpreter),
and its proof rows are in [unrepresentable_state](../documents/architecture/unrepresentable_state.md).

The bracket's lifetime guarantee is bounded by what the host can execute. On a POSIX host, timeout,
cancellation, protocol failure, callback exception, and other catchable host exits signal and reap the
complete host-side child process group before ownership is released. On a Windows host the same exits
terminate and reap only the direct child: `HostBootstrap.Effect.ChildGroup` calls `terminateProcess` on the
child handle, so a descendant the child started outlives the bracket. Job-Object containment that ends the
whole tree on Windows is owed by Sprint 13.20 of the
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md).
An uncatchable parent death executes no Haskell cleanup and cannot promise termination or reap; only pipe EOF
and the kernel's descriptor/process cleanup remain. This boundary makes no claim about guest or container
descendant groups.

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
[authenticated-handoff-and-child-admission phase](phase-13-authenticated-handoff-and-child-admission.md)
owns the frame-crossing bracket (`HostBootstrap.Handoff.Transaction`), the protocol vocabulary, and the
child-group termination (`HostBootstrap.Effect.ChildGroup`), and the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns the lifecycle process
route with its forward and reverse launch owners (`HostBootstrap.Handoff.Process`) and the root
coordinator's durable receipt and acknowledgement transitions. The
[documentation-reconciliation-and-drift-guards phase](phase-25-documentation-reconciliation.md) owns the
mechanical guards that keep a sealed surface sealed. The canonical architecture is
[unrepresentable_state](../documents/architecture/unrepresentable_state.md).

### JJ. Host-Portable Static Gate And Test Harness

**Owning phase**: [the Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md)
The repository builds every project binary host-native on every substrate (§ N), so the sources that
binary is built from — and the suites that gate them — are host-portable. The **host static gate** (§ II)
runs as an ordinary process of the outer host, and it passes host-native on macOS, Linux, and Windows
alike. A suite that only builds and self-tests on POSIX cannot gate a binary the plan says is built
host-native everywhere.

**This is the gate, spelled once.** Every other document cites this list rather than paraphrasing it.
Each command runs from the repository root, as a separate invocation; the two `cd` legs do not chain, so
pasting the list as one script runs the second `cd` from `core/` and fails:

```
cd core && cabal test all
cd demo && cabal test all
poetry run python -m hostbootstrap.check_code
poetry run python -m hostbootstrap.test_all
```

All four legs, in the spelling above. There is no `-Werror` flag to remember: both Cabal packages carry
the warning policy in their `common warnings` stanza, so it is a property of the source tree rather than
of whoever typed the command. Dropping the `demo/` leg leaves the only real consumer ungated; dropping
`check_code` leaves the Python layer's types and formatting unchecked. A paraphrase that omits either is
a weaker gate wearing this one's name, and the omission does not announce itself.

The harness therefore holds five rules. Each is a property of the test harness, never a weakening of the
contract a guard asserts: a host-portable guard proves the same thing on every host, which is exactly why
it may not be written in terms of one.

- **A guard over source bytes reads bytes.** A frozen source digest is computed from the file's own
  bytes, so it is a property of the file rather than of the process locale. Each suite driver also fixes
  the locale encoding, so a spec that reads a source file or captured command output decodes the same
  text on every host. The core driver (`core/hostbootstrap-core/test/Spec.hs`) sets
  `setLocaleEncoding utf8` before the runner starts; the demo driver (`demo/test/Spec.hs`) does not, and
  Sprint 24.57 of the [worked-demo phase](phase-24-worked-demo.md) owes it.
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
  is about, and a compile-fail fixture's expectation is the same on every gate host because the module it
  names is built everywhere.
- **No case is skipped, and no module is excluded from the build.** A case whose subject is unavailable
  on this gate host asserts the refusal its row declares; it does not disappear. A conditional that
  changes an *expectation* keeps the evidence, while one that removes the case removes it — and a green
  total that quietly shrank on one family is the most complete form of spoofing available, because the
  number reads the same. Platform rows are therefore compiled everywhere and stubbed to a total
  `Unsupported` where they cannot apply, rather than excluded by a Cabal condition of any kind — an
  `os` guard, an `arch` guard, or a `flag` — around a module, a component, or `buildable`. The row's
  unavailable branch is a CPP-selected total refusal inside a module that is always built. A Cabal
  conditional may vary `build-depends` only, as the `unix` and `Win32` dependencies do; it never varies
  `exposed-modules`, `other-modules`, or whether a component builds. A component the default build
  excludes is a component no gate compiles, and a suite that cannot be compiled reports the same green
  nothing as one that passed. Whether a run was *asked for* is a runtime decision the component makes and
  reports, never a build condition. The suite reports what it did not run, and the gate compares that
  against a declared case count for each conditional test group (`CoverageManifest`, keyed by test-group
  path, identical on every gate host), so a case vanishing is a failure rather than a smaller number
  nobody reads.

#### The gate host

A host static gate run is evidence about a **gate host**: the operating system, architecture, and
toolchain the gate *process* runs on. That is a different unit from § II's **outer host**, which pairs a
physical machine with the provider it realizes a hardware context through, and which selects substrates
and owns acceptance phases. Conflating them makes the plan unreadable in both directions — a container
run would have to be reported as evidence about the machine hosting the container, and a Linux VM the
project itself provisions would be a substrate that somehow also proves outer-host portability.

A gate host is therefore identified by what it *is*, never by how it came to exist. Bare metal, a virtual
machine, a container, and a WSL2 distribution are each a gate host, and a run on any of them is evidence
for its own OS family and architecture and for no other. There are three supported families — Windows,
macOS, and Linux — and a phase's dated evidence names the family, the architecture, and the machine that
produced it.

This is not a way to obtain a substrate gate cheaply. § II's distinction is untouched: a substrate gate is
about where the *effects of the lifecycle under test* execute, and running a static suite on a Linux gate
host does not establish a live provider or container realization. A compiled local process fixture proves
only its exercised native protocol and kernel behavior, with the evidence limits of § NN. Nor is the
project's own provisioning machinery part of the gate: `ensure wsl2`, `ensure lima`, and the provider
reconcilers exist to establish the substrate the project under test runs in, and no gate procedure invokes
them to create the machine it runs on. The test is what the gate procedure does, not which provider the
gate host sits on. A gate host may run on any provider, including one the reconcilers also manage — the
recorded arm64 Linux gate host is a container on a Colima VM — and such a run is evidence for the
container's own family and architecture only, never for the provider or for a substrate. How a developer
or CI comes by a gate host is otherwise outside the plan.

#### The coverage matrix, and visiting hardware once

There are three gate-host families, and the Linux family carries an **architecture** dimension. § N builds
every binary host-native, so an x86_64 Linux gate host and an arm64 Linux gate host compile and self-test
genuinely different code out of one source tree. A run on one is not evidence for the other, for the same
reason a macOS run is not evidence for Windows.

Combining that with the substrate acceptances of § II, exactly **five cells** need real hardware, and no
more:

| Cell | What it establishes | Owning phase |
|---|---|---|
| Apple Silicon / Metal | the apple-silicon substrate acceptance | [phase 26](phase-26-apple-silicon-substrate.md) |
| Linux / NVIDIA | the nvidia substrate acceptance | [phase 27](phase-27-nvidia-gpu-substrate.md) |
| Windows | the windows substrate acceptance | [phase 28](phase-28-windows-and-wsl2-substrate.md) |
| `linux-cpu` on x86_64 | the host static gate passing on an x86_64 Linux gate host; no substrate claim | [phase 29](phase-29-host-portability-acceptance.md) |
| `linux-cpu` on arm64 | the host static gate passing on an arm64 Linux gate host; no substrate claim | [phase 29](phase-29-host-portability-acceptance.md) |

The two `linux-cpu` cells are filled by gate-host runs, not by substrate acceptances: neither needs a
`linux-cpu` substrate gate run, and neither establishes the `linux-cpu` substrate (§ II).

**A cell is a hardware-coverage unit; a gate-host run is not a cell.** The two are counted separately and
the table above counts only the first. Five cells need hardware; the same hardware produces **four
gate-host runs** — Windows, macOS, x86_64 Linux, arm64 Linux — because the three gate-host families split
Linux by architecture. The two Linux runs fill the two `linux-cpu` cells; the Windows and macOS runs fill
no cell of their own and are produced on the Windows and Apple Silicon visits. The host-portability phase
records all four runs. So that phase owns two *cells* in the table and four *runs* in its own document,
and both numbers are right about different things. Anywhere else in this plan, "cell" means a row of the
table above and nothing else; a phase that records a gate-host run calls it a gate-host run.

The order in which the cells are filled carries no meaning. What matters is that every cell is filled
against the current covered source, and that a cell nobody has filled is *named as owed* rather than
assumed from a neighbouring one.

**A hardware set is visited once.** One physical machine can usually fill more than one cell: an Apple
Silicon host carries the Metal substrate, a macOS gate host, and an arm64 Linux gate host, a Linux/NVIDIA
host carries the
nvidia substrate and an x86_64 Linux gate host, and a Windows host carries the windows substrate and a
Windows gate host. A visit that records only the cell it was convened for leaves the machine owing a
second visit for evidence it could have produced in the same sitting — and the cost of a visit is a human
physically changing machines, which is the most expensive step in this plan.

So a visit to a hardware set records **every cell that hardware can produce**, and each cell's dated
evidence names the family, the architecture, and the machine. Three visits fill all five cells and all
three gate-host families; a fourth machine is never required. This is a rule about *sequencing evidence
collection*, not a weakening of any cell: each still carries its own dated run, its own totals, and its own
covers digest.

It follows that no phase may demand a *fresh machine* for a cell another phase's visit already fills, and
that a phase whose gate names one hardware set must not quietly require a second. § C's rule that a phase
never carries a closure obligation for hardware it does not declare is the same rule read from the phase's
side.

#### What a phase owes, and what it does not

A phase closes when its own suites hold the five rules above and its declared gate passes on the gate host
that ran it. It does **not** owe evidence from every family: requiring three gate hosts to close a
baseline sprint is exactly the closure obligation § C forbids, because the hardware is not something the
phase declares. Cross-family confirmation is owned by one terminal acceptance phase, the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md), which runs the gate on each
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
never sits beside an ad-hoc path that performs the same work without being described. There is one quoter
per argument grammar (POSIX shell and PowerShell, both in `HostBootstrap.Effect.Quote`), one rendering of
"cross into this frame" (§ LL), and one process runner (`HostBootstrap.Effect.Run`) for every captured and
bounded run.

**A launch boundary is admitted by the process shape it owns.** A module other than the runner may assemble
a child process only when it owns a launch shape the runner cannot express, and the admitted set is closed.
`EffectSpec`'s `launchBoundaries` pins it at six modules: the runner; the Colima backend runner, whose
shipped command transaction owns the group it kills on parent death; `HostBootstrap.Detached`, a child that
outlives its launcher with a fixed disposition (§ HH); `HostBootstrap.Handoff.Process` and
`HostBootstrap.Handoff.Transaction`, each the bracketed owner of one child, its group, and its descriptor
pair for one authenticated edge or one frame crossing; and the demo's accelerator daemon, a long-lived
worker session whose pipes stay open across requests. A seventh spawn site is a defect unless it owns a
shape none of these expresses, and admitting it changes this list and that guard together.

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
module is as forbidden as it is anywhere else. § KK grants no other exception, including none for a
platform limitation of the runner.

**What runs today.** Interpreter text stands outside the guest bootstrap module, and each site is owed by a
named phase rather than admitted:

- the runner's macOS branch in `HostBootstrap.Effect.Run` execs `/bin/sh -c` to set the working directory,
  because `process` cannot combine `create_group`, an explicit environment, and `cwd` there; replacing it
  with the binary's own working-directory entry is owed by Sprint 3.7 of the
  [host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md), and the
  `wsl.exe` reframing through PowerShell `-Command` in `HostBootstrap.Effect.Interpreter` by its Sprint 3.8;
- `Ensure/Incus.hs`, `Ensure/Cuda.hs`, `Ensure/Docker.hs`, `Ensure/Wsl2.hs`, and `Lift.hs`'s
  `--entrypoint sh` config-write script (`configWriteScript`, Sprint 8.14) are owed by the
  [ensure-reconcilers phase](phase-8-ensure-reconcilers.md);
- `Substrate/Provider/Backend.hs` by Sprint 15.35 of the
  [host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md);
- `Cluster/Cordon/Foundation.hs` by the
  [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md);
- `Registry.hs` by the [composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md);
- the demo's `Commands.hs` by the [worked-demo phase](phase-24-worked-demo.md).

The [host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md) owns the
vocabulary and its single runner; the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns the guest bootstrap vocabulary. The absence
guards (§ I) that hold this section today live in `EffectSpec`: the tree carries no script file (by
extension or by a `#!` first line); each quoter, the captured-run primitive, the bounded runner, the effect
interpreter, and the described-command interpreter has exactly one definition site; no consumer carries a
quoter or interpreter of its own; and the set of modules that assemble a child process equals
`launchBoundaries`. Interpreter-token guards exist only per module (`GuestBootstrapSpec` over the guest
bootstrap's renderings, `ClusterBackendSpec` over the cluster backend). The repository-wide guard that
interpreter-invocation tokens appear only in the guest bootstrap module, beside a named list of files whose
tokens are not an invocation, is owed by Sprint 25.25 of the
[documentation-reconciliation phase](phase-25-documentation-reconciliation.md); it can pass only once every
site listed above is removed by its owning phase, which is why it sits in that phase. No
repository-wide guard yet asserts one crossing renderer (only `RegistrySpec` checks that the registry module
derives its crossing from `foldLeaf`); that guard is owed by Sprint 15.47 of the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md), which owns § LL's
frame table. The fold itself, `foldLeaf` in `HostBootstrap.Lift`, is the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md)'s. No guard yet asserts that each computation the ownership rows share — the identity read, the
no-replace publication, the identity-conditional act, and the record codec — has one definition site;
consolidating those computations onto one seam, with its guard, is owed by the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md).
The `PreToolUse` guard named in `CLAUDE.md` and `AGENTS.md` governs how one development harness launches
the long demo gate on Windows; it lives in that harness's configuration, not in the tree, and enforces
nothing in this section.

### LL. The Frame Table: The Substrate Axis Is A Lift, Not A Fork

**Owning phase**: [the host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md)
A provider does not own a workflow. It owns a **frame** in the frame-table sense of the
[glossary](../documents/README.md#glossary): a way to reach a context, plus the small closed table of facts
that context differs by. This section uses "frame" in that sense throughout. It is neither a topology frame
(`ContextKind`, `ProjectFrame`) nor the host-frame axis: `HostFrame` (`LinuxFrame`, `AppleFrame`,
`WindowsFrame`, enumerated by `allHostFrames`) classifies the outer host, and `substrateFrame` collapses the
detected `SubstrateName` onto it. Every lifecycle behaviour is written once against an abstract frame and
instantiated from that table. Adding a provider adds a **row**; it never adds a parallel copy of a
workflow.

The table is closed and small, and each entry is a value rather than a code path:

- the host tool that reaches the frame, and the exact argument shape it takes;
- the frame's path grammar (§ MM);
- the frame's sizing renderer, mapping one `EffectiveBudget` to that provider's own wall vocabulary (§ O);
- the frame's ownership primitive — the platform seam beneath the four clauses (§ EE), never a second
  implementation of them;
- the frame's file-transfer and share primitives.

The ownership primitive is the entry most easily mistaken for a workflow, so it is worth stating what its
row contains. Two rows implement the clauses: a POSIX one and a Windows one
(`HostBootstrap.Ownership.Row`). A third entry, `HostBootstrap.Ownership.Shipped`, ships the transaction to
this same binary at the frame that interprets it; it is a **transport**, not a third implementation. When
the lift crosses at least one frame, the far side is Linux — every frame the project reaches across a
crossing is — so what runs there is the POSIX row. An empty lift addresses this machine, so the far side is
the local process and runs this host's own row, the Windows row on a Windows outer host. The transaction
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
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) owns the frame
table's provider rows and the repository-wide one-crossing-renderer guard; the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns the single fold (`foldLeaf` in
`HostBootstrap.Lift`) and reconcilers as rows rather than as per-platform modules.

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
- **a compile-fail fixture that fails for its named reason** (§ HH), to the extent its expectation pins
  that reason: a complete diagnostic phrase counts, while a bare token an unrelated error could also
  satisfy proves only that something failed (the matcher's current independent-fragment form, and the
  phase that owes the per-diagnostic form, are stated in § HH);
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
