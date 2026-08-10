# Phase 9 — Lifecycle modes and run leases

**Status**: Done
**Depends on**: Phase 5 (installed identity, operator verification, and authority kernels), Phase 7
(Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Establish exact Production and Harness mode, run, lease, snapshot, and lifecycle-profile
> authority before project-plan construction begins.

## Phase Objective

Each installed project holds a protected mode lease whose type identifies Production or one exact Harness
run. Harness acquisition mints its run identity generatively, and every mode, snapshot, and lease value
retains that identity through its phantom indices. Binding changes an unbound lease into a bound lease only
when the verified snapshot has the same scope.

An opaque `ActiveProjectMode` narrows the project-wide lease to its exact lifecycle scope. The Production
and Harness lifecycle-profile openers then consume matching root, mode, and unbound-lease evidence through
separate protected one-use slots. Each opaque profile retains the exact installed-project name,
protected-store identity, and broker epoch observed at that transition, so downstream plan admission can
reject evidence assembled from distinct stores even when their project names and epoch numbers happen to
match. Retaining ordinary Haskell values therefore cannot open a second profile or erase its durable origin.

## Sprints

### Sprint 9.1: Indexed `ProjectModeLease` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Represent the held project mode in the lease type so only the transition for that exact mode can consume
it.

#### Deliverables

- Opaque `ProductionMode` and `HarnessMode runId` types are the only public mode tags.
- `ProjectModeLease projectId mode brokerGeneration` binds installed project, exact mode, and broker
  generation in one opaque capability.
- The protected record uses an internal stable wire sum that decodes only into the matching typed mode
  transition.
- Production acquisition retains an already-held Production mode for the same project, while a Harness
  acquisition contends on the same protected record.
- The public surface consists of opaque mode witnesses and scope-specific transitions; wire constructors
  and mutation kernels remain package-private.

#### Validation

`AuthoritySpec` proves exact-mode acquisition, Production retention, cross-mode refusal, and a
multi-process contention case with one winner. `CompileFailSpec` proves that a Production lease cannot
inhabit a Harness mode and that callers cannot construct a mode tag or generic mutation authority. The
phase gate runs with `-Werror`.

#### Remaining Work

None.

### Sprint 9.2: Generative `RunId runId` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Give each Harness acquisition a fresh type identity that cannot be selected or reconstructed by a caller.

#### Deliverables

- `RunId runId` is opaque and exposes only a non-authorizing text projection for diagnostics and stable
  record keys.
- The Harness acquisition transition mints `RunId runId` only inside a rank-2 continuation.
- `HarnessMode runId`, `Harness projectId runId`, the indexed mode lease, and the Harness unbound lease all
  carry the same generative `runId`.
- Production uses a structurally distinct lease-identity branch that contains no Harness `RunId runId`.
- The text projection is diagnostic/key material only and is never accepted as a `RunId runId`
  constructor input.

#### Validation

`AuthoritySpec` proves distinct Harness acquisitions receive distinct stable identities and that the
Production identity branch is classified independently. `CompileFailSpec` proves that values from two
Harness continuations cannot cross-pair and that callers cannot mint `RunId runId`. The phase gate runs
with `-Werror`.

#### Remaining Work

None.

### Sprint 9.3: Scope-indexed lease binding and `VerifiedPlanSnapshot` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Bind a lease only to a protected snapshot verified for the same Production or Harness scope.

#### Deliverables

- `UnboundRunLease scope brokerGeneration` is the sole pre-binding lease capability.
- `VerifiedPlanSnapshot scope specDigest planDigest` binds the protected snapshot observation to its exact
  lifecycle scope and digests.
- `BoundRunLease scope specDigest planDigest brokerGeneration` retains the same scope, both digests, and
  broker generation.
- The protected binding transition has this exact surface:

  ```haskell
  bindRunLease
    :: UnboundRunLease scope brokerGeneration
    -> VerifiedPlanSnapshot scope specDigest planDigest
    -> (BoundRunLease scope specDigest planDigest brokerGeneration -> IO a)
    -> IO (Either LeaseConflict a)
  ```

- A successful compare-and-swap enters only the bound-lease continuation; a conflicting protected lease
  state returns `LeaseConflict` without authority.
- Fresh root acquisition creates an unbound lease from an absent record, or compare-and-swaps an exact
  decoded `LeaseUnbound` record for the supported pre-effect retry. A decoded `LeaseBound` record returns
  `ModeLeaseNotBindable <run> "bound"`, every other non-unbound state is likewise refused, and malformed
  bytes return `ModeMalformedRecord`; none of these refusal branches enters the root continuation or
  changes the lease or snapshot record.

#### Validation

`AuthoritySpec` proves successful same-scope binding, exact digest retention, conflict behavior, and the
supported unbound pre-effect retry. It also proves that a second Production root refuses a bound lease
without entering its continuation while preserving the exact lease and snapshot versions and bytes, and
that malformed lease bytes receive the typed refusal without mutation. `CompileFailSpec` proves that a
Production lease cannot bind a Harness snapshot, two Harness run scopes cannot cross-pair, and a snapshot
for one digest pair cannot yield another pair's bound lease. The phase gate runs with `-Werror`.

#### Remaining Work

None.

### Sprint 9.4: `ActiveProjectMode` narrowing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Narrow an indexed project-wide mode lease into the exact lifecycle scope authorized by its mode tag.

#### Deliverables

- `ActiveProjectMode scope brokerGeneration` is opaque and retains the active broker generation.
- Production narrowing has the exact type:

  ```haskell
  productionActiveMode
    :: ProjectModeLease projectId ProductionMode brokerGeneration
    -> ActiveProjectMode (Production projectId) brokerGeneration
  ```

- Harness narrowing has the exact type:

  ```haskell
  harnessActiveMode
    :: ProjectModeLease projectId (HarnessMode runId) brokerGeneration
    -> ActiveProjectMode (Harness projectId runId) brokerGeneration
  ```

- These two scope-specific functions are the only producers of active-mode authority.

#### Validation

`CompileFailSpec` proves that Production and Harness active modes cannot substitute for one another, that
two Harness run indices cannot cross-pair, and that the constructor is inaccessible. `AuthoritySpec`
checks that each narrowing preserves the broker epoch observed through the originating lease. The phase
gate runs with `-Werror`.

#### Remaining Work

None.

### Sprint 9.5: Protected one-use Production `LifecycleProfile` slot [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Open a Production lifecycle profile exactly once from matching root scope, active mode, and unbound lease
authority.

#### Deliverables

- `LifecycleProfile scope` is opaque and grants only the scope named by its phantom index.
- Its hidden representation retains the exact installed-project name, protected-store identity, and broker
  epoch observed through the opening lease; downstream evidence leaves need not infer that origin from the
  scope phantom or from coincidentally equal epoch numbers.
- The Production opener has the exact type:

  ```haskell
  withProductionLifecycleProfile
    :: RootScopeAuthority (Production projectId)
    -> ActiveProjectMode (Production projectId) brokerGeneration
    -> UnboundRunLease (Production projectId) brokerGeneration
    -> (LifecycleProfile (Production projectId) -> a)
    -> IO (Either AuthorityError a)
  ```

- The opener compare-and-swaps the unbound lease's protected Production profile slot from available to
  consumed before entering the continuation.
- Root scope, active mode, and unbound lease agree on Production scope and broker generation by type.
- A retained input tuple cannot consume the slot again; the protected transition returns an authority
  error and yields no profile.

#### Validation

`AuthoritySpec` proves one successful open, refusal of a second open, and a concurrent same-slot race with
one continuation entry. `CompileFailSpec` proves that Harness evidence and a different broker generation
cannot inhabit the Production opener. The phase gate runs with `-Werror`.

#### Remaining Work

None.

### Sprint 9.6: Protected one-use Harness `LifecycleProfile` slot [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Open a Harness lifecycle profile exactly once from evidence for one generative Harness run.

#### Deliverables

- The Harness opener has the exact type:

  ```haskell
  withHarnessLifecycleProfile
    :: RootScopeAuthority (Harness projectId runId)
    -> HarnessAuthority projectId runId
    -> RunId runId
    -> ActiveProjectMode (Harness projectId runId) brokerGeneration
    -> UnboundRunLease (Harness projectId runId) brokerGeneration
    -> (LifecycleProfile (Harness projectId runId) -> a)
    -> IO (Either AuthorityError a)
  ```

- Root scope, Harness authority, run witness, active mode, and unbound lease share the exact `projectId`,
  `runId`, and broker generation indices.
- The resulting profile retains the exact installed-project name, protected-store identity, and broker epoch
  observed through that Harness lease, just as the Production profile does.
- The opener compare-and-swaps that run's protected Harness profile slot from available to consumed before
  entering the continuation.
- A retained evidence tuple cannot consume the slot again or open a profile for another run.

#### Validation

`AuthoritySpec` proves one successful open, refusal of a second open, and a concurrent same-run race with
one continuation entry. `CompileFailSpec` proves that Production evidence, another Harness run, or another
broker generation cannot inhabit the opener. The phase gate runs with `-Werror`.

Dated evidence for the phase gate and lease-acquisition contract:
`cabal test all --ghc-options=-Werror` from `core/` passed 1169/1169 on 2026-08-09 (aarch64-osx,
GHC 9.12.4), including all 113 public compile-fail boundaries. The same run covered distinct identities
across successive Harness acquisitions, the bound and malformed Production-root refusal/preservation
cases, exact lease/snapshot conflicts, and the Production and Harness same-slot concurrent one-winner
races. The library and test-suite build also passed with `-Werror`.

Origin-retention revalidation on 2026-08-09 (aarch64-osx, GHC 9.12.4) passed the exact gate at 1194/1194,
including Production and Harness project/store profile projections, an end-to-end two-store/same-project/
same-epoch refusal before snapshot persistence, and all 123 public compile-fail boundaries.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**

- `documents/architecture/lifecycle_state_model.md` — indexed modes, generative run identity,
  scope-indexed lease binding, active-mode narrowing, and protected profile slots.
- `documents/architecture/harness_workflow.md` — Harness run identity and one-use profile admission.

**Engineering docs to create/update:**

- `documents/engineering/testing.md` — protected compare-and-swap races and compile-fail authority
  fixtures.

**Cross-references to add:**

- Keep `development_plan_standards.md` § EE and the Phase 9 README status row aligned with these six
  foundations.
