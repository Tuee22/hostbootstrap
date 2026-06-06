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
- Phase 0 is always documentation and governance. No code-writing phase may be marked `Active` or
  `Done` before Phase 0 closes.
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
└── legacy-tracking-for-deletion.md
```

Phase numbering may grow as later work is scoped. Adding or renaming a phase requires updating this
file, `README.md`, `00-overview.md`, and `system-components.md` in the same change.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative inventory for:

- `hostbootstrap-core` Haskell module surfaces (`HostBootstrap.*`)
- the `ensure` reconcilers and their host applicability
- the skeletal `hostbootstrap.dhall` schema
- the thin Python bootstrapper surface
- the base image contents and warm Cabal store
- the optparse command tree that consuming project binaries extend

When the host-management architecture changes, update the component inventory in the same change.

### G. Phase Document Requirements

Each phase document contains sprint-level sections in this format:

```markdown
## Sprint X.Y: Name [STATUS]

**Status**: Done | Active | Planned | Blocked
**Implementation**: `path/to/file` (required for Done, recommended for Active)
**Blocked by**: sprint id(s) (required for Blocked)
**Docs to update**: `documents/...`, `README.md`

### Objective

### Deliverables

### Validation

### Remaining Work
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
through `$PATH`; every invocation reads an absolute path from typed host configuration.

### L. Substrate and Ensure-Reconciler Contract

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) is owned by `hostbootstrap-core`.
Each host dependency is an `ensure` reconciler — an idempotent value with a host-applicability
predicate and a reconcile action — exposed as an optparse subcommand (`ensure docker`,
`ensure colima`, `ensure cuda`, `ensure homebrew`, `ensure ghc`, `ensure tart`). A reconciler run
on the wrong host fails fast with a one-line diagnostic and a non-zero exit.

### M. Python-Thin / Haskell-Core Boundary

The Python bootstrapper does only what must run before any project binary exists: assert the
fail-fast host minimums, ensure Docker (provision the per-project Colima VM on Apple), build the
project container, copy the binary to `./.build/`, ensure host runtimes, and exec the binary. All
other host-management logic lives in `hostbootstrap-core`. New host logic defaults to Haskell; a
Python addition must be justified by the pre-binary bootstrapping constraint.

### N. Build-Twice / Copy-Out Model

Every project's binary is produced through Docker so the only universal host dependency is Docker.

- On Linux substrates the binary is built in the project container (`FROM` the base image) and
  copied out to `./.build/`; it runs on the host because the host and container share the same
  glibc family.
- On Apple silicon a Linux ELF cannot exec on macOS, so the Python layer ensures a host GHC
  toolchain (via Homebrew) and the binary is built natively on the host into `./.build/`.
- A `./.build/<binary>` is always present on the host, even for container workflows.
- Tart is build-only (Swift/Metal artifacts copied to `./.build/` and run on the host); no built
  binary ever runs inside the Tart VM.
- The container image is built on every substrate, both for containerized workflows and as the
  mandatory code-check quality gate.

### O. Resource Budget and Cordoning

The skeletal `hostbootstrap.dhall` declares a per-project resource budget (`cpu`, `memory`,
`storage`). `hostbootstrap` verifies the host has the spare budget and cordons it: on Apple by
sizing a dedicated per-project Colima VM, on Linux by applying kind node resource limits. The
budget is the one field both the Python layer and the project binary consume.

### P. optparse Command-Tree Extension Contract

`hostbootstrap-core` exposes its subcommands as a composable optparse value plus a generic
entrypoint (`runHostBootstrapCLI progName projectCommands`). A project binary extends the core tree
with its own subcommands rather than re-implementing core verbs. The skeletal `hostbootstrap`
binary baked into the base image is the core tree with no project commands.

### Q. Configuration via Dhall

Configuration is typed Dhall in three tiers:

- the skeletal `hostbootstrap.dhall` (project, dockerfile, resource budget), read by the Python
  bootstrapper, identical in shape across projects;
- rich project-level Dhall (runtime roles plus cluster-bootstrap instructions), read by the
  project binary;
- per-case test-harness Dhall, generated by the project binary.

The rich project and test schemas are artifacts emitted by the project binary; `hostbootstrap-core`
owns only the skeletal-schema decoder.

### R. Quality Gate Contract

Static quality is a first-class requirement. The Haskell formatter is `ormolu`/`fourmolu` and
`hlint` runs against supported source roots, both pinned in the base image. Every image build, base
or derived, gates on the project's canonical code-check. The documentation validator is a Phase-0
deliverable. The plan distinguishes mechanically enforced gates from editor-only guidance.

### S. Imported Practices and Explicit Non-Adoption

`hostbootstrap` borrows the governance shape (metadata blocks, phase plan structure, completion
tracking, declarative current-state language) from the consumer projects. It does not adopt any
consumer's product features, runtime surfaces, daemon-role model, or hardware-correctness
validation cadence; those remain consumer concerns. Non-adopted external doctrine must not be
treated as a current blocker or completion criterion.
