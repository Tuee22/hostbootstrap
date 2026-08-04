# Unrepresentable Illegal State

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [readiness.md](readiness.md), [ownership_invariant.md](ownership_invariant.md),
[hostbootstrap_core_library.md](hostbootstrap_core_library.md),
[binary_context_config.md](binary_context_config.md),
[../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: State, once, the method this repository uses to make an illegal value impossible to
> construct — and state exactly what that method does not buy.

## TL;DR

- A boundary is a **type**, not a convention, a comment, or a review habit.
- Four techniques carry it: private constructor + validating smart producer; rank-2 continuation;
  closed sum + total eliminator; phantom indices.
- A claim of unrepresentability **ships a compile-fail fixture**. Without one, the claim is a comment.
- A test that asserts the current value of an unsealed field pins whatever that field happens to hold.
  When the held value is wrong, the test makes the defect the contract.
- None of this excludes an external actor, and none of it makes a runtime effect exactly-once.

The normative contract is
[§ HH](../../DEVELOPMENT_PLAN/development_plan_standards.md). This page is its canonical
explanation; individual boundaries cite it instead of re-deriving the method.

## Why this page exists

The repository has applied this method at nearly every boundary it has built — and had never stated it.
It appeared as local prose at each site (`AbsExe` "makes a bare command name unrepresentable", readiness
"forged readiness … is unrepresentable at the new boundary", the opaque `StepPlan`, the private
`CanonicalProjectRoot`), and was grounded normatively only in § EE, which is scoped to capabilities and
lifecycle-state tokens, and § CC, which is scoped to readiness.

The cost of having no general statement is not stylistic. Each new boundary re-derived the method from
whichever neighbour its author happened to read, and a boundary nobody thought to seal simply had none.
The host-daemon launch was that boundary: a plain `CreateProcess` record assembled at a call site, with
a stdio disposition that closed the child's descriptors. Every gate passed. One of them asserted the
defect.

## The method

### Private constructor, validating smart producer

The constructor is absent from every exposed module — including any module merely *named* `Internal`.
The producer validates and is the only way in.

`HostBootstrap.HostTool.AbsExe` is the smallest worked example: `mkAbsExe` rejects a non-absolute path,
so a bare command name is not an `AbsExe`, and § K's doctrine holds by construction rather than by
review. `HostBootstrap.Step.ProjectStepId`, `HostBootstrap.Readiness.PollPolicy`, and
`HostBootstrap.Lifecycle.Prepared.PreparedGate` are the same shape at increasing stakes — the last of
these can only exist if the durable compare-and-swap that mints it actually landed.

### Rank-2 continuation

Some values are only meaningful inside the scope that authorized them. A rank-2 bracket binds a fresh
type variable the caller cannot instantiate, so the value cannot outlive its bracket.

`withProtectedEntry`, `withCanonicalProjectRoot`, `withLifecyclePlan`, and `withVerifiedRootInvocation`
all do this. It is what makes "this handle is valid only while the entry is held" a type error rather
than a comment.

### Closed sum, total eliminator

An outcome set is a closed sum, and it is consumed by an eliminator with no wildcard. Adding a case is
then a compile error at every site that must decide about it.

`CaseResult`'s three eliminators are documented for exactly this reason: they are total "so adding an
outcome cannot silently be counted as success". `TeardownOutcome`, `ReconcileError`, and
`DaemonEvent` are the same shape. A wildcard in an eliminator is the defect this technique exists to
prevent — it silently absorbs the case nobody considered.

### Phantom indices

A `scope`, `planId`, `runId`, or `resource` index costs nothing at runtime and makes cross-plan,
cross-scope, and cross-resource mixing a type error. `LifecycleProfile (Production projectId)` versus
`LifecycleProfile (Harness projectId runId)` is the load-bearing instance: a test component has no
route to a Production profile because there is no term of that type it can reach.

Indices are only as strong as the values that carry them. An index on a type whose every accessor
returns plain `Text` is documentation, not enforcement — worth writing when a future consumer will
need the pairing checked, but it should be described as such until then.

## The proof obligation

A boundary that claims a shape cannot be constructed ships a compile-fail fixture under
`core/hostbootstrap-core/test/compile-fail/`, registered in `CompileFailSpec`.

Worked examples: `ForgeStepExecution.hs` (a project cannot fabricate a plan-minted descriptor),
`ForgePreparedGate.hs` (nor a prepare gate, nor reach one by record update), `ForgeTeardownForest.hs`
(nor a teardown forest, nor substitute one verb's projection for another's).

Two rules make a fixture worth having:

1. **It must fail for the named reason.** `rejectsWith` pins the expected diagnostic. A fixture that
   merely fails to compile proves nothing — a typo would satisfy it.
2. **The expectation must not be satisfiable by an unrelated error.** Splitting an expected diagnostic
   into separately-matched tokens is the common way to get this wrong: an unrelated in-scope error on
   the same source line can satisfy each token independently. Keep the expectation one contiguous
   phrase; the matcher collapses whitespace so compiler line-wrapping does not break it.

## Tests that pin a defect

This is the failure mode the method is meant to remove, and the one that hides longest.

A test asserting the current value of an unsealed field cannot distinguish "this is the right value"
from "this is the value that happens to be there". If the held value is wrong, the assertion promotes
the defect to a contract, and every gate then agrees with it — which is indistinguishable, from the
outside, from the boundary holding.

The host-daemon launch carried exactly such a test: three assertions that its stdio disposition equalled
the one that closed the child's descriptors. It was green for as long as the defect existed.

Prefer an assertion that the lawful shape **does the lawful thing**. A child launched through a sealed
boundary can be observed to have an open standard input at EOF and both output streams reaching one
place; no unlawful disposition passes that test, so it fails when the boundary is missing instead of
certifying its absence.

## What this does not buy

Stating the limits is part of the contract, not a caveat appended to it.

- **It does not exclude an external actor.** Hidden constructors exclude construction by cooperating
  code in this repository. A same-privilege process outside it is unaffected, and
  [ownership_invariant.md](ownership_invariant.md) is explicit that no substrate supplies that
  exclusion.
- **It does not bind a caller who reaches past the boundary.** Sealing a module does not remove the
  underlying package from the build plan. Keeping a surface sealed is a drift-guard obligation, owned
  by Phase 21, not a property the type system maintains on its own.
- **It does not make a runtime effect exactly-once.** § EE states the limit directly: no plan may claim
  compile-time exactly-once effects from phantom types alone. Ordinary Haskell values are not linear;
  "consumed" is an interpreter invariant enforced by a journal, and the type only prevents forging the
  token.
- **It does not make an unsound design sound.** A closed sum over the wrong domain is still wrong.
  Totality guarantees every case is *considered*, not that the cases are the right ones.

## Current boundaries

| Boundary | Sealed value | Fixture |
|---|---|---|
| Host-tool resolution (§ K) | `AbsExe` | — (smart constructor, `HostToolSpec`) |
| Readiness (§ CC) | `Ready`, `Probe`, `PollPolicy` | `RawReadiness.hs` |
| Capabilities and lifecycle state (§ EE) | `PreparedGate`, ownership receipts, `RunLease` | `ForgePreparedGate.hs`, `ForgeRunLease.hs` |
| Command authority (§ X) | `CommandAuthority`, `RootInvocationAuthority` | `ForgeCommandAuthority.hs` |
| Plan, descent, reverse (§ W/§ Y) | `StepPlan`, `StepExecution`, `TeardownForest` | `ForgeStepExecution.hs`, `ForgeTeardownForest.hs` |
| Process launch (§ HH) | `DetachedLaunch`, `DetachedChild`, `DetachedWorkingDirectory`, `DetachedOutputSink` | `ForgeDetachedLaunch.hs`, `RelabelDetachedLaunch.hs` |

Phase status is tracked in [the development plan](../../DEVELOPMENT_PLAN/README.md); this page does not
duplicate it.

## The process-launch boundary

`HostBootstrap.Detached` is the worked example of this page applied to a boundary that had none.

A child that outlives its launcher has exactly one lawful stdio disposition, descriptor-inheritance
setting, session, environment, and working directory, so none of those is a parameter. `DetachedLaunch`
hides its record constructor **and every field accessor** — the second half matters, because an exported
accessor still admits record update, which would let a caller re-point a launch it was handed.
`withDetachedChild` is a rank-2 bracket over the *launch*, not the child's lifetime: on exit the child is
still running and only the launcher's own handles have been released, so the acquire is total (it either
succeeds or returns a typed `DetachedLaunchError` having created no child) while the body's exceptions
propagate unchanged.

The lawful disposition is `UseHandle` throughout. Standard input is the host's null device, so the child
sees an open descriptor already at EOF; both output streams share one handle, so the child's own output is
retained where the launcher can quote it and a startup failure names its cause (§ CC) instead of
collapsing to "the process is gone".

It closed on a live run, not only on its static gate. The Apple Silicon lane had reported `0/10` against
this exact defect; re-run against the sealed boundary on 2026-08-03 it reported `10/10 passed`, with the
daemon reaching readiness on every bring-up and the browser case asserting real daemon-computed work.
That is the strongest available evidence that the sealed shape is the *lawful* one and not merely a
different one.

Its gate is the shape this page argues for. `DetachedSpec` launches a real child — this test executable
re-invoked through a probe argv — and observes that the child read its standard input to EOF, that both
its output streams reached the retained sink, and that it kept writing after the bracket returned. No
unlawful disposition passes that: `NoStream` closes the descriptor so the read raises, `Inherit` sends the
output to the test runner instead of the sink, and `CreatePipe` does not typecheck because the disposition
is not a parameter. A textual drift check additionally proves that no production module outside the
boundary so much as names `NoStream`.
