# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md),
[system-components.md](system-components.md)

> **Purpose**: Explain what each phase is responsible for and why it sits where it does in the order, without
> duplicating status.

## Status authority

The [README phase table](README.md) is the sole cross-phase status source of truth. This document contains no
status roll-up and no current test count. Dated validation evidence belongs to the phase whose gate produced it.

## The architecture these phases build

`hostbootstrap` is a Haskell `hostbootstrap-core` library plus a thin Python bootstrapper. Python asserts the
irreducible pre-binary floor, prepares the native toolchain, builds the project binary host-native, and invokes
it; it also owns the operator-invoked base-image and self-update surfaces. Haskell owns host and provider
operations, typed configuration, lifecycle, testing, service roles, and the fixed command tree
(`project`, `test`, `service`, `context`, `check-code`).

Project behaviour arrives through typed extension streams: one lifecycle chain finalized into a plan, project
configuration, test components, and service handlers. Core owns no default config values and no fixed config
type.

## Why the order is what it is

The order is a **dependency layering**, not a subject-matter grouping. That distinction is the whole reason the
plan is executable in numerical order: a plan cut by subject spreads one vertical feature across several
subjects, and its dependencies then criss-cross. Cut by layer, every phase needs only what is beneath it.

The layering, bottom to top:

**Governance (0).** The metadata standard, the plan tree, and the validator that enforces both. It precedes
code because an unenforced standard is a preference.

**Bootstrapping (1–2).** Something must run before the binary exists (1), and the binary needs a package and an
entrypoint to be (2).

**The host (3).** Which executable a call names, the shape the call takes, what substrate this is, and where
durable state lives. Everything above invokes host tools, so both invocation axes close here.

**The kernel (4–6).** A durable exclusively-entered store (4); the authority chain that turns an OS fact into
an unforgeable capability (5); and the canonical quantities, opaque readiness, and ownership-indexed result
types every observation and reconciliation is expressed in (6).

**Configuration (7).** The scope-indexed codec, the generated Dhall vocabulary, and the generic project
specification. It sits above the kernel because a codec's scope index is what keeps a test-only secret out of
production configuration, and above authority because a harness codec requires a harness capability.

**Host dependencies (8).** With the binary, the tool boundary, and typed config in place, the binary can
reconcile what it needs.

**Lifecycle state (9–11).** One mode and one lease per project (9); versioned sessions, the single-writer
journal, and durable fences (10); and the prepare compare-and-swap that every external effect must pass (11).
Each needs the one below: a session belongs to a lease, and a prepare revalidates a session.

**The plan (12).** The step algebra and the single project plan whose forward ordering, frame descent, and
reverse effects are three projections of one value. It is above prepare because a step's action must be able to
reach a gate.

**Crossing process boundaries (13).** The challenge/grant handoff, child admission, and the build and
activation authorities. Above the plan because a grant is bound to a plan edge.

**Ownership (14).** The four ownership clauses and the host-local backends that hold them. Above prepare
because a reservation is a prepared operation, and above the store because clause 1 is the store's entry.

**Providers and clusters (15–16).** One dispatch path for every host provider (15) and the cluster lifecycle
inside a declared budget (16). Above ownership because a provider operation acquires an owned object.

**Interpretation (17).** The recursive lifecycle command: the plan becomes effects across frames, and unwinds
child-first. Above handoff and clusters because it descends through both.

**Recovery (18).** Acting on every durable record the phases below wrote. Above interpretation because
recovering an interrupted run means resuming or reversing an interpretation.

**The test surface (19–20).** The harness that makes a test run an exclusively owned transaction (19), and the
`test`/`context` grammar over it (20). Above recovery because a run's first act is to sweep its predecessors.

**Reusable algebras and the service surface (21–22).** Scope-indexed reachability, proof-gated delivery, and
the opaque role phase machine (21); then the fixed `service` command that adopts them (22).

**Publication (23).** The rolling native base image and the opportunistic warm store, published only behind
the complete gate and proved by pulling the tag and smoking a real consumer.

**The consumer (24).** The worked demo — the real application that proves the library composes. It is last
among baseline phases because a consumer depends on everything.

**Acceptance (25–27).** One phase per non-baseline substrate: Apple Silicon, NVIDIA GPU, Windows/WSL2. Each
adds that substrate's own realizations and confirms the build on it. They are terminal, so a machine without
that hardware stops at 24.

**Reconciliation (28).** The governed-document sweep and the drift guards. Last because its subject is every
other phase.

## Dependency edges worth naming

Most phases depend simply on their predecessor. These are the ones that reach further back, and each reaches
only *backwards*:

- **9** depends on authority (5) and configuration (7): a profile opener needs both a verified root and a
  scope-correct codec.
- **14** depends on the store (4) and prepare (11): clause 1 is the store's entry, and a reservation is a
  prepared operation.
- **15** depends on the reconcilers (8) and ownership (14).
- **17** depends on handoff (13) and clusters (16).
- **21** depends on clusters (16) rather than on the test surface, because reachability is a property of the
  cluster's frames.
- **28** depends on everything.

## Non-goals

- Git history remains user-controlled.
- The Python bootstrapper does not become a second lifecycle or configuration implementation.
- A mutable base tag, an unpublished local image, a test count, or a run on another substrate is not substitute
  evidence.
- Definition-only exports and aspirational integration modes are not retained as supported API.
