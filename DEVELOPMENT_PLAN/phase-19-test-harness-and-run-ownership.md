# Phase 19 — Test harness and exclusive run ownership

**Status**: Active
**Depends on**: Phase 18 (recovery and migration)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`, plus on a realized linux-cpu host
`cabal test hostbootstrap-core:test:hostbootstrap-core-test --test-options='--pattern recovery-interruption'`
from `core/`
**Gate kind**: deferred
**Gate evidence**: 2026-09-17 ; static leg on `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0, with the realized `linux-cpu` leg on `hb-linux-cpu`,
x86_64 Ubuntu 24.04.5 LTS, Linux 6.8.0-139-generic, GHC 9.12.4, Cabal 3.16.1.0 ;
`cabal test all --test-show-details=direct --test-options=--hide-successes` from native `core/`, then
`cabal --store-dir=/home/ubuntu/hostbootstrap/demo/.build/cabal-store test hostbootstrap-core:test:hostbootstrap-core-test --test-options='--pattern recovery-interruption' --test-show-details=direct`
from `core/` in the CPU VM ; pass ; covers
5a8bbee429919f037959e3874bfd897864a16efd867b4e4d9411919fb7087aae
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs` `core/hostbootstrap-core/src/HostBootstrap/Harness` `core/hostbootstrap-core/internal/harness-lifecycle` `core/hostbootstrap-core/test/RecoveryInterruptionSpec.hs`

> **Purpose**: Make a test run an exclusively owned transaction whose failures are isolated per variant and
> whose cleanup cannot delete foreign or concurrently replaced state.

## Phase Objective

A test run mutates real infrastructure, so it needs everything the lower phases built: an exclusive mode, a
recoverable lease, clause-holding ownership of the objects it generates, and a sweep that resolves whatever a
killed predecessor left. What this phase adds is the engine on top: per-variant isolation, a structured report
card, and a cleanup driven by receipts rather than by paths.

The harness has no route to Production. The command constructs and retains one exact Harness `ProjectPlan`
for each admitted variant, then gives the engine an opaque lifecycle over that plan. A project's `TestSuite`
owns only the safety probe, assertion-environment opener, typed case matrix, per-case assertion, and
post-reverse absence assertion; it receives no lifecycle callback or Production planning path. The exact plan
is retained through lifecycle interpretation, while the demo's cluster profile, durable root, and port terms
still enter through its independently derived run profile. Making those terms exact plan projections belongs
to the [worked-demo phase](phase-24-worked-demo.md).

## Sprints

### Sprint 19.1: Exclusive run ownership [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

One bracket that owns everything a run touches, in one order.

#### Deliverables

- In order, a run takes the project-wide liveness lock and holds it for the whole run; sweeps every abandoned
  run; evaluates the project-supplied Production-state safety probe; takes the Harness mode and its lease in
  one compare-and-swap with the sibling-config safety recheck inside it; takes ownership of its own
  `.test_data/<runId>` generation; and takes ownership of its generated sibling config. Production
  reverse-root kernels take the same liveness lock name on the same store, so contention on it is refused
  with a message naming a held liveness lock, not a second test run.
- On exit it settles **both** owned objects and only then closes the lease and releases the mode, because the
  sweep enumerates incomplete *leases* and a record outliving its own lease is unreachable forever — see
  [rationale.md](rationale.md). A refusal or exception between the mode compare-and-swap and data-root
  ownership still reclaims the run's data-root record and closes its fresh lease and mode before the bracket
  returns, so a refused run never leaves the project held in Harness mode.
- When the body throws, the bracket still runs that settlement and hands its verdict to the engine together
  with the body's exception, so an unresolved release is never reported as a clean one.
- The shared data-root parent is scaffolding: created if missing, never owned, never removed. The run's
  generation is derived from its typed `RunId`, and the sibling directory and the data parent cross the
  ownership boundary as distinct role types, so neither can stand in for the other.
- A conflict on either object is reported and the object left intact; the run's report card carries the row.
- The config existence refusal derives its subject from installed project identity and runs *after* the
  sweep, so an interrupted run's own config is reclaimed before anything can refuse on it, while an operator's
  config still refuses the run and survives it untouched. Two checks hold it: `harnessPreconditions`
  rechecks the sibling `<project>.dhall` inside the mode compare-and-swap, and `acquireOwnedRunConfig` refuses
  an object already at the path before any mutation, closing the window between that recheck and acquisition.
- The Production-state probe also runs after the sweep, while project liveness is still held and before any
  fresh run lease, data root, config, or plan is allocated. Provider state owned by the abandoned Harness run
  is therefore a recovery subject rather than a false Production conflict, and each later variant repeats the
  same recovery-then-safety ordering.

#### Validation

`HarnessSpec` covers the acquisition order, both settlements, the conflict reports, the config-existence
refusal ("an operator's production config still refuses the run, and survives it"), admission after an
abandoned provider release, a hard kill holding each owned object, and a racing-harness probe converging on
one acquisition. Replacement fixtures keep the original directory alive at a sibling path so their new object
has a distinct kernel identity.

The sprint closes when the `HarnessSpec` cases and the `CompileFailSpec` fixture named in Remaining Work
exist and pass, together with the existing ownership cases, under `cabal test all` from `core/` and from
`demo/`.

On 2026-09-17, the replaced-data-root bracket case passes 20 consecutive focused runs. The complete
native Linux gate passes 2,552 core cases in 176.58 seconds, the full demo workspace passes 2,552 core
cases and 151 demo cases, and the Python code check and all 251 Python tests pass. In `hb-linux-cpu`,
the exact recovery-interruption command in the header passes all five real-process interruption cases
and its coverage-manifest check, six tests in 1.18 seconds. The remeasured seven-file covers digest
matches the header; these fixture changes are outside that production/recovery path set.

#### Remaining Work

- Close a refused data-root acquisition. In `runOwned` (`Harness/Ownership.hs`), the `generalBracket` release
  ignores a `Left` from `takeDataRoot` and is skipped when `takeDataRoot` throws, so the fresh unbound lease
  and Harness mode recorded by `withHarnessRoot` stay open and every Production opener gets
  `ModeHeldByAnother` until the next `test run` sweeps. Make both paths call `reclaimAbandonedDataRoot` for
  the run's `dataroot.<project>.<runId>` record and then `runTerminalClose`, returning a failure of either as
  `HarnessDataRootCleanupFailed` or `HarnessModeCloseFailed` instead of `Nothing`. Test: a `HarnessSpec` case
  "a refused data-root acquisition closes its lease and releases the mode" that pre-creates `.test_data` as a
  regular file under `withTypedOwnership`, asserts `runWithOwnedRun` returns `Left` naming the data-root
  failure, and then asserts `withProductionRoot` on the same store is admitted rather than refused with
  `ModeHeldByAnother`, with no harness run in between.
- Keep the finalizer's verdict on the exception path. `runOwned` discards `releaseRun`'s
  `Maybe HarnessRunCleanupFailure` when the body throws a synchronous exception. Add an exception type
  `HarnessRunAborted` to `HostBootstrap.Harness` carrying the body's `SomeException` and that verdict; the
  owner rethrows the body's synchronous exception wrapped in it, asynchronous exceptions propagate unchanged,
  and the `HarnessRunOwnership` Haddock states this exception-path contract. Sprint 19.2 consumes it. Test: a
  `HarnessSpec` case whose typed-ownership body replaces its data-root generation (keeping the original alive
  at a sibling path, as the replaced-data-root fixture does) and then throws `userError "seeded failure"`;
  assert the caught exception is `HarnessRunAborted` whose cause is that `IOException` and whose verdict is
  `Just (HarnessDataRootCleanupFailed _)`.
- Cover the post-sweep Production-state refusal of the real bracket. No test makes the probe that
  `ownProjectRun` evaluates after the sweep return `Left`. Add a `HarnessSpec` case under
  `withAbandonedResourceOwnership False` that calls
  `runWithOwnedRunAfterRecovery ownership (pure (Left "production cluster seeded"))` and asserts: the
  exception is `SafetyRefusal "production cluster seeded"`; the recorded executor events are `["host"]`, so
  the sweep ran first; afterwards `.test_data` holds no generation, the sibling `<project>.dhall` is absent,
  and no `config.` or `dataroot.` record exists; and a following `runWithOwnedRun` returns
  `Right ((), Nothing)`. In the same group, assert `testSafetyPreconditions (pure True)` returns exactly
  `Left "a production cluster is already running; refusing to touch production state"` and
  `testSafetyPreconditions (pure False)` returns `Right ()`.
- Name the liveness lock neutrally. Reword `liveRunHoldsProject` in `Harness/Ownership.hs` to say that another
  hostbootstrap invocation (a test run or a production lifecycle command) holds this project's liveness lock.
  Sprint 19.9's racing-harness case asserts each loser's reason against this exact text.
- Type the ownership coordinates. `testDataGeneration` takes `RunId runId` instead of `Text`;
  `protectedProjectRunOwnership` and `protectedProjectRunOwnershipWithRecovery` take the sibling directory and
  the data parent as two distinct newtypes instead of two `FilePath`s; and the `ownedHarnessConfigPath`
  Haddock says the caller supplies the directory, which `HostBootstrap.Command` derives from the executable's
  own path. Test: a `CompileFailSpec` fixture passing the data-parent newtype where the sibling directory is
  expected fails to type-check, and the existing ownership cases compile against the new signatures.

### Sprint 19.2: The engine and per-variant isolation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/internal/harness-lifecycle/HostBootstrap/Harness/Lifecycle/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Run the matrix so one variant's failure does not hide another's result, while a declaratively restart-spanning
case retains one report row across two fresh lifecycle generations of the same run.

#### Deliverables

- Pure stable variant drafts are validated first; then a fresh generative run and lease open for each distinct
  config variant. Cases sharing a variant share its stack, and no later variant starts while the prior lease is
  unresolved.
- Each chosen case carries exactly one engine-classified outcome, so a bring-up failure and an assertion failure
  are distinct rows rather than one aggregate. `runMatrix` records a throwing case body as `LifecycleFailed`
  and a throwing teardown as that case's own `TeardownFailed` row, so neither aborts the remaining cases.
- Cleanup failures are their own rows: a data-root cleanup failure, a generated-config cleanup failure, and a
  mode-close failure are separately named, whether the variant body returned or threw. An exception that
  escapes an entered ownership bracket blocks every later variant exactly as a returned cleanup failure does,
  and the command's generated-config release conflict reaches the card as the `generated-config cleanup` row
  with the variant's assertion rows intact.
- The report card renders every case for every variant, including a suite with no cases. A post-sweep safety
  refusal stops the run before that variant acquires anything: that variant and every later one render as
  `REFUSED` rows naming the refusal, and the rows of variants that already ran are kept.
- The engine consumes one opaque lifecycle supplied by the command and orders forward, assertions, reverse,
  and post-reverse verification without constructing or reopening a project plan.
- Each case declares `AssertOnce` or `AssertAcrossRestart`. After all initial assertions pass, the latter class
  alone drives the opaque lifecycle's intermediate reverse/fresh-forward transition, reopens its assertion
  environment as `AfterRestart`, and merges that result into the case's existing row.
- The final reverse and post-reverse verification still run exactly once. A failed initial assertion never
  requests a restart, and a restart-spanning case whose after-restart assertion did not run carries no `PASS`
  row. A failed restart is classified as a forward failure is — `SafetyRefusal` to `REFUSED`, a marked cause
  to its own row, anything else to `BROKEN` `same-run restart failed: <cause>` — and stays isolated to its
  variant's restart-spanning rows.
- A project's `TestSuite` contains only the safety probe, assertion-environment opener, typed cases, case
  assertion, and post-reverse absence assertion. It receives neither lifecycle actions nor a Production plan.

#### Validation

`HarnessSpec` covers per-case classification, each returned cleanup-failure row, the empty suite, variant
sequencing, engine ordering around an opaque lifecycle, and one-row restart-spanning assertion across fresh
lifecycle generations for a single passing case. The public-signature/source guard proves that `TestSuite`
cannot invoke project lifecycle operations or obtain a Production plan.

The sprint closes when the `HarnessSpec` and `CLISpec` cases named in Remaining Work exist and pass under
`cabal test all` from `core/` and from `demo/`.

On 2026-08-24 the focused 45-case Harness gate and complete 2,454/2,454 core host-static gate passed;
the real command-level fixture separately passed both variants across two forward/reverse generations while
retaining one result row per restart-spanning case.

#### Remaining Work

- Report a generated-config release conflict as cleanup, not as a broken variant. `removeGeneratedConfig` in
  `HostBootstrap.Command` calls `die` when `releaseOwnedRunConfig` reports a conflict; the `ExitFailure 1`
  escapes the variant body, `safeRunVariant` overwrites every case row with
  `LifecycleFailed "variant failed: ExitFailure 1"`, and later variants start. Make it return without raising
  on a release conflict, leaving the origin record standing so the ownership finalizer's
  `reclaimAbandonedConfig` reports it as `HarnessGeneratedConfigCleanupFailed`. Test: a `CLISpec` command-level
  case over two variants whose first variant's assertion appends to the generated `<project>.dhall`; assert
  the card keeps the first variant's assertion rows, carries a `[v0] generated-config cleanup` `LEAKED?` row,
  renders every second-variant case `REFUSED` with "prior variant ownership cleanup is unresolved", and that
  the second variant's config is never generated.
- Treat an exception escaping an entered bracket as unresolved cleanup. `safeRunVariant` maps every
  non-`SafetyRefusal` exception to `(LifecycleFailed rows, Nothing)`, so `runVariants` starts the next
  variant. On `HarnessRunAborted` (Sprint 19.1) render the chosen cases `LifecycleFailed ("variant failed: "
  ++ displayException cause)`, add the verdict's cleanup row, and return the verdict so `runVariants` blocks
  later variants; for any other exception raised after the ownership callback was entered (recorded in an
  `IORef` set on entry) block later variants with a reason naming the escaped exception. Tests in `HarnessSpec`
  over two variants: a seam that enters the body and throws
  `HarnessRunAborted (toException (userError "x")) (Just (HarnessModeCloseFailed "seeded"))` yields a
  `[v0] mode close` row and `REFUSED` v1 rows with v1's lifecycle never entered; a seam that enters the body and
  throws a plain `userError` also leaves v1 unentered.
- Keep completed rows on a post-sweep safety refusal. `safeRunVariant` turns the probe's `SafetyRefusal` into
  `Left "test run refused: ..."`, which `runVariants` propagates and so drops every earlier variant's rows.
  Render that variant and every later one as `Refused ("test run refused: " ++ reason)` without entering their
  ownership, keep earlier rows, and let the command print the card and exit non-zero. Tests in `HarnessSpec`:
  a suite whose safety returns `Left "x"` over two variants renders both variants' cases
  `Refused "test run refused: x"` with no config or lifecycle entered; a seam whose probe admits v0 and refuses
  v1 over three variants keeps v0's `Pass` rows and renders v1 and v2 refused, with neither entered.
- Classify restart failures. A failed `runHarnessRestart` becomes `LifecycleFailed "same-run restart failed:
  ..."` even for the `SafetyRefusal` the command throws when a restart refusal acquired nothing, and
  `SafetyRefusal` has no `displayException`, so the row leaks `HOSTBOOTSTRAP_SAFETY_REFUSAL:`. Give
  `SafetyRefusal` a marker-free `displayException`, route restart failures through the forward
  classification with `same-run restart failed: ` as the `BROKEN` fallback, and when a sibling
  restart-spanning case fails before the restart replace the rows of restart cases that passed
  `BeforeRestart` with `LifecycleFailed "restart not exercised: a sibling restart-spanning case failed before
  the restart"`. Tests in `HarnessSpec`: an `AssertOnce` case beside an `AssertAcrossRestart` case is asserted
  only in `BeforeRestart`; two restart cases where one fails before the restart never run the restart action
  and render `Fail` and the "restart not exercised" row; a restart action throwing `userError "restart-boom"`
  renders the restart row `LifecycleFailed "same-run restart failed: user error (restart-boom)"`, keeps the
  `AssertOnce` row `Pass`, runs the final reverse once, and lets a second variant run; a restart action
  throwing `SafetyRefusal "foreign"` renders `Refused "foreign"`; and
  `runHarnessRestart (testingHarnessLifecycle (pure ()) (pure ()))` throws the `IOError`
  "this Harness lifecycle has no fresh same-run invocation".
- Isolate a throwing `runMatrix` teardown. `seamTeardown` runs under `finally`, so its exception aborts the
  whole `mapM` and drops collected rows. Run it under `trySynchronousIO` and record its failure as that case's
  `TeardownFailed` row when the body passed, keeping a non-pass body row otherwise; correct the `runMatrix`
  Haddock to say a throwing body is `LifecycleFailed`. Test: a `HarnessSpec` matrix case with three cases
  whose teardown throws for the second asserts three rows, the second `TeardownFailed`, the others `Pass`.

### Sprint 19.3: Exact Harness project-plan command adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/internal/harness-lifecycle/HostBootstrap/Harness/Lifecycle/Internal.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/run_models.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Retain one exact Harness project plan through generated-config ownership and drive the common lifecycle
interpreter through its closed command-owned entry.

#### Deliverables

- The Harness scope-finalized spec, lifecycle profile, and validated Harness config produce
  `ProjectPlan (Harness projectId runId) ...`.
- The generated `runId` remains in every draft, frame, snapshot, lease, journal, cursor, authority, and
  interpreted node index.
- The generated-config bracket retains that exact plan while the hidden fixed root-Up entry and exact reverse interpreter run.
- `TestSuite` owns the case matrix and assertions, while project lifecycle resides in the plan and command
  interpreter.
- Harness dispatch uses the common `forward`, `topology`, snapshot, resource, and Chain foundations through
  the Sprint 17.8 hidden root-Up entry; only that entry derives raw execute evidence.
- Test case selection remains outside project-plan construction.
- Production evidence cannot enter the Harness path, and an `OwnedHarnessRoot` that a body returns out of its
  ownership bracket cannot install a generated config: `acquireOwnedRunConfig` acquires only while that run's
  lease is open and the project is held in that run's Harness mode.
- A failure inside the command's `variantWithLifecycle` raises `LifecycleFailure` carrying its message, so the
  report card names the cause of a broken variant rather than `ExitFailure 1`.

#### Validation

`HarnessSpec`, `CLISpec`, and compile-fail fixtures cover exact run identity, direct shared interpretation,
generated-config lifetime, and Production/Harness separation. A source guard rejects lifecycle-owned
`project up` or `project destroy` self-invocation from `TestSuite`. The sprint closes when the escaped-root
`HarnessSpec` case and the assembly-refusal `CLISpec` case named in Remaining Work exist and pass under
`cabal test all` from `core/` and from `demo/`.

Dated host-static evidence: on 2026-08-09 (aarch64-osx, GHC 9.12.4), the focused `HarnessSpec`, `CLISpec`,
`ChainSpec`, and `ProviderAliasSpec` groups passed 41/41, 47/47, 39/39, and 16/16 respectively; all 234
public compile-fail boundaries passed; the changed demo consumer's `hostbootstrap-demo-test` suite passed
123/123; and `cabal test all --ghc-options=-Werror` from `core/` passed 1421/1421 cases in 67.44 seconds,
including 2/2 governed-documentation checks. This is the static half of this phase's gate; the realized
linux-cpu leg is recorded in Sprints 19.6 through 19.8 and in the header's gate evidence.

#### Remaining Work

- Refuse config acquisition through an escaped root. `OwnedHarnessRoot projectId` hides `runId` existentially
  and the body's `result` is caller-chosen, so a body can return the root; `acquireOwnedRunConfig` then opens a
  protected entry and installs `<project>.dhall` under `config.<project>.<runId>` for a run whose lease has
  closed, a record no `releaseRun` or sweep reaches again. Inside that protected entry, verify that the root's
  run lease is still open and the `mode.<project>` record holds that run's Harness mode before calling
  `acquireGeneratedConfig`, and return a `Left` naming the closed run otherwise. Test: a `HarnessSpec` case
  under `withTypedOwnership` whose body returns its `OwnedHarnessRoot`; after `runWithOwnedRun` returns, calling
  `acquireOwnedRunConfig` on the escaped root returns `Left`, the sibling `<project>.dhall` does not exist, and
  the store's records directory holds no `config.` record.
- Raise the variant's own failure instead of `die`. Inside `variantWithLifecycle` in `HostBootstrap.Command`,
  every failure path ends in `die` — plan drafts and plan construction (forward and restart), frame admission,
  snapshot persistence, the lifecycle profile, the project root, Harness config assembly, generated-config
  acquisition, and substrate detection through `hostConfig` — so `safeRunVariant` renders every case
  `LifecycleFailed "variant failed: ExitFailure 1"` and the cause exists only on stderr. Replace each with
  `throwIO . LifecycleFailure`, keeping the existing message text; for substrate detection call `detect` in the
  variant path and raise its `Left` the same way, leaving `hostConfig` unchanged for the other commands. The
  `removeGeneratedConfig` finalizer is Sprint 19.2's. Test: a `CLISpec` case whose Harness assembler returns
  `failConfigAssembly "seeded assembly refusal"` runs `test init` and `test run all` in a child copy of the test
  executable through the stdout capture `runSchemaFixture` uses, accepting `ExitFailure 1`; assert the captured
  card contains `variant failed:` followed by text containing `seeded assembly refusal`, and does not contain
  `ExitFailure 1`.

### Sprint 19.4: Reconciler-produced report rows [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/StepSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Let the report card carry what the reconcilers actually observed.

#### Deliverables

- An acquisition conflict, a safety refusal, and an unsupported backend are distinct structured rows —
  `CONFLICT`, `REFUSED`, `SKIPPED` — so a lane the substrate cannot run reads as skipped rather than broken,
  and state an operator must resolve reads as a conflict rather than a break.
- `classifyLifecycleReason` is what produces them, and it reads the cause the interpreted chain already
  reported. Only the marker that opens the failing node's observation counts — at the start of the cause, or
  directly after the `— <label>: ` separator of the node row the chain renders — so a marker word inside a
  free-form reason or a quoted tool error does not reclassify the row. A cause naming none of the three stays
  an ordinary `BROKEN` row rather than being guessed into one.
- The three markers live with the shared `HostBootstrap.Step` observation vocabulary. Harness imports and
  reexports those exact values, and `observationDetail` renders with them, so the row the chain interpreter
  printed and the row the report card classifies cannot drift apart. `HostBootstrap.Step` imports no
  `HostBootstrap.Harness` module in any form — plain, qualified, or `{-# SOURCE #-}`.
- None of the new rows is a pass: a skipped lane did not do what was asked, and `caseResultPassed` stays total
  so a later outcome cannot be silently counted as success.
- A `ManagedResult` retains its managed handle and teardown receipt while a `ForeignResult` exposes only an
  unmanaged handle, and the guest-alias release accepts only the managed one — that is the result algebra's,
  and `ForeignGuestAliasRelease.hs` pins that a foreign handle does not type-check at teardown.
- Independent variants continue when it is safe to do so, and a teardown failure turns its own variant red
  without aborting the others.

#### Validation

`HarnessSpec` covers each row's label and reason on the rendered card, that every non-passing outcome is
counted as a failure, that each of the three causes classifies to its own row while an unrelated cause does
not, and that `observationDetail`'s own rendering of each observation classifies back to the matching row.
`CompileFailSpec`'s `ForeignGuestAliasRelease.hs` pins the foreign-handle teardown refusal. The sprint closes
when the anchored-marker cases and the token-level `StepSpec` layering guard named in Remaining Work exist and
pass under `cabal test all` from `core/`.

#### Remaining Work

- Anchor the observation marker. `classifyLifecycleReason` searches the whole cause with `isInfixOf` in the
  fixed order conflict, unsupported, refused, so `"project up: [host] deploy-vm — launch: refused: existing
  volume conflict: owned by another project"` classifies as `Conflicted`, and a plain failure quoting
  `unsupported:` becomes `SKIPPED`. Match a marker only at the start of the cause or immediately after the
  first `— <label>: ` node-row separator, and classify by that one position. Tests in `HarnessSpec` beside
  "a bring-up failure carries the node's own outcome into its row": the cause above classifies as `Refused`;
  `"docker build failed: unsupported: --platform flag"` classifies as `Nothing`; the three existing node-row
  causes and the `observationDetail` round trip still classify as before.
- Make the layering guard token-level. The `StepSpec` case "the step algebra owns its observation markers below
  the harness" asserts only that the substring `import HostBootstrap.Harness` is absent from `Step.hs`, so
  `import qualified HostBootstrap.Harness.GeneratedConfig as G` or `import {-# SOURCE #-} HostBootstrap.Harness`
  compiles and passes it. Replace the infix check with `SourceGuard.haskellImports` over the `Step.hs` source and
  assert no imported module is `HostBootstrap.Harness` or starts with `HostBootstrap.Harness.`. In the same case,
  assert `haskellImports` yields `HostBootstrap.Harness.GeneratedConfig` for the literal
  `"import qualified HostBootstrap.Harness.GeneratedConfig as G\n"` and `HostBootstrap.Harness` for
  `"import {-# SOURCE #-} HostBootstrap.Harness\n"`, so the guard is shown to see both forms.

### Sprint 19.5: Harness root-scope capsule production [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/binary_context_config.md`

#### Objective

Supply the exact generative Harness run evidence to the authenticated root-scope capsule without making the
child reconstruct a `runId` or authority from text.

#### Deliverables

- `harnessHandoffScope ownedProject authority` combines the live `HarnessAuthority projectId runId` with the
  installed project identity to construct the matching `HandoffScope (Harness projectId runId)`. `Command.hs`
  builds it at each of the five Harness entries into the common lifecycle — forward, reverse, the restart's
  destroy and fresh forward, and the fresh reverse — and passes it to `runExactProjectUp` or
  `withExactHarnessDestroyGeneration`, which hand that scope and its live typed `RootBroker` to the generic
  capsule producer.
- Production and Harness capsule production remain closed branches; a Production identity cannot substitute
  for generative Harness run evidence.
- The capsule's exact seven frames carry only codec domain/version, installed project, closed Harness kind,
  canonical run text, installed-key digest, and signature; it does not bind store, broker generation, verb,
  Offer, edge, payload, or plan coordinates and never serializes `HarnessAuthority` or a signing key.
- A child obtains its existential Harness scope only through the lower authenticated scope-first receiver;
  verified run text introduces a fresh `runId` but never reconstructs `HarnessAuthority`, while `argv`, config
  text, and envelope-supplied keys introduce no phantom.
- The sprint changes at most two production modules, adds no named type, adopts the scope through one
  constructor, targets at most 300 production lines, and splits before exceeding 400.

#### Validation

`HarnessSpec`, `HandoffSpec`, and compile-fail fixtures cover Production/Harness separation, wrong-run,
cross-scope and mismatched-live-broker refusal, signature tampering, rank-2 scope non-escape, and absence of a
caller-supplied scope or key route. The capsule tests assert that store/generation/verb/edge coordinates remain
outside this scope-only value; the host-static full suite closes the sprint.

Dated host-static evidence: on 2026-08-22 (linux-cpu, GHC 9.12.4), `HarnessSpec` passed 44/44,
`HandoffSpec` passed 107/107, and all 506 public compile-fail boundaries passed. After the governed
documentation was reconciled, `cabal test all --ghc-options=-Werror
--test-options='--hide-successes' --test-show-details=direct` from `core/` passed all 2364 tests in
148.12 seconds.

#### Remaining Work

None.

### Sprint 19.6: Realized-Linux harness acceptance [Done]

**Status**: Done
**Implementation**: none — this sprint changes no source
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the realized-linux confirmation this phase's construction owes, as a sprint rather than as a
footnote nothing counts, without making an earlier phase depend on the worked demo's later provider,
workload, reverse-adopter, or same-run recreate work.

#### Deliverables

- Zero production lines. Every deliverable of Sprints 19.1 through 19.5 closes on the host static gate;
  what is left is running them where their effects are real.
- The recovery phase's deterministic interruption matrix is rerun inside a realized Linux substrate with
  `cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror
  --test-options='--pattern recovery-interruption'` from `core/`. That group is deterministic subprocess
  and sentinel fixtures, so it needs a Linux substrate and no provider, cluster, or Docker state.
- The complete core gate reruns on the same realized substrate, covering the exact Harness plan consumer,
  ownership bracket, process competitors, interruption fixtures, report engine, and governed-document validator.
- Provider, cluster, workload, exact reverse-adopter, and same-run destroy/up/readback acceptance remain the
  worked-demo phase's own Sprints 24.3, 24.27, and 24.30. This sprint does not make Phase 19 wait on Phase 24.
- Dated evidence records both results together, naming the substrate realization and the outer host.

#### Validation

The two runs. This sprint asserts nothing the suites do not already assert; it confirms that what they
assert holds where the phase says it holds.

Dated realized-host evidence: on 2026-08-22, inside a disposable Ubuntu 24.04 amd64 Incus VM on a Linux
outer host, the deterministic `recovery-interruption` group passed 5/5. On the same linux-cpu realization,
the complete `cabal test all --ghc-options=-Werror` core gate passed all 2366 tests in 151.83 seconds,
including the exact Harness consumer, POSIX ownership/process rows, public compile-fail boundaries, and both
governed-documentation checks.

#### Remaining Work

None.

### Sprint 19.7: The realized-host recovery-interruption run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated recovery-interruption selection on a realized linux-cpu host.

#### Deliverables

- one dated run of `cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror
  --test-options='--pattern recovery-interruption'` inside a realized linux-cpu host.

#### Validation

On 2026-09-06, the recovery-interruption selection passed `6/6` on a realized `linux-cpu` host: the
published `basecontainer-cpu-arm64` base at digest `sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`,
reporting `Linux aarch64` with GHC 9.12.4 and Cabal 3.16.1.0, the pinned toolchain the outer host also
carries. The five interruption cases — `owned-resource-settled`, `migration-frozen`,
`migration-committed`, `closing-persisted`, and `destroy-settled` — each survived a real process death
and converged, the last with a terminal lease and mode. The sixth is `CoverageManifest`'s declaration
for this family, which reported `5 cases, 1 exercising the row against this gate host's kernel`, so the
family's size was checked rather than assumed.

The realization is a container rather than metal, which § JJ admits as a Linux gate host in its own
right: the process, its kernel calls, and the deaths it survives are Linux's. The repository was mounted
read-only and the build directed to a container-local path, so the run observed the working tree without
writing to it.

#### Remaining Work

None.

### Sprint 19.8: The run-ownership gate against the current tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

This phase's evidence covers the harness modules and the run-ownership internals. The shared record
tape reaches two of them, so the covered tree changes and the phase's claim expires with it. The claim
is re-established by re-running the gate, not by assuming the change was harmless.

#### Deliverables

- The phase's declared gate is re-run in full — the static suite and the realized `linux-cpu` leg, not one of the two.
- A gate-evidence row records both legs, the gate host, and the command as run.
- The covers digest is re-measured over this phase's own paths and recorded.

#### Validation

The phase's own gate, both legs. Re-recording the digest without re-running is the one thing this
sprint may not do.

#### Remaining Work

None. On 2026-09-13 both legs ran against the current tree. The static leg is the complete
2,536/2,536 `cabal test all` from `core/` on the x86_64 Linux gate host. The realized `linux-cpu` leg is
the five-case `recovery-interruption` selection plus its manifest row, 6/6, built and run inside an
x86_64 Linux container from the published `basecontainer-cpu-amd64` base with no accelerator device
visible — the cases kill real processes and observe convergence under a real project root, so their
effects executed in that Linux rather than beside it. The covers digest was re-measured over this
phase's own paths and recorded as
`5a8bbee429919f037959e3874bfd897864a16efd867b4e4d9411919fb7087aae`.

The published `basecontainer-cpu-amd64` base carries the GHC that GHCup's `recommended` tag named on
its build date, which is 9.10.3, while `core/cabal.project` selects 9.12.4 as a workspace compatibility
choice — the split
[the Cabal layout page](../documents/engineering/cabal_layout.md) describes rather than a drift. The
realized leg therefore mounted the pinned toolchain into the container instead of using the base's own.

### Sprint 19.9: Harness specs pin the exact outcome they name [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/HarnessSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Each `HarnessSpec` case asserts the exact outcome, path, and mechanism its name claims, so a mutation of the
property under test turns it red instead of passing on an incidental route.

#### Deliverables

- Sweep cases abandon their predecessor by a hard kill and prove the predecessor's state is still present
  before the successor runs; in-process exception cases are named as finalizer cases.
- Precondition assertions run outside any `try` that would swallow an HUnit failure.
- Refusals and exceptions are matched by their exact constructor, key, or message, not by a common word.
- The racing-harness case synchronizes its competitors on a barrier and asserts each loser's stated exclusion.
- Identifier, empty-suite, bring-up-row, and Cabal-privacy guards exercise the rule they name.

#### Validation

Every case named in Remaining Work exists in its corrected form and passes under `cabal test all` from
`core/` and from `demo/`; no production module changes.

#### Remaining Work

- "an abandoned bound run that acquired nothing is closed by the next run's sweep" abandons its bound run with
  an in-process `throwIO`, so `generalBracket`'s finalizer closes the lease before the successor's sweep runs.
  Add a `--hostbootstrap-harness-bound-abandon-probe` subprocess that binds the lease as the case does now,
  writes its ready file, and sleeps; hard-kill it, assert its `.test_data/<runId>` generation still exists, then
  assert the successor returns `Right ("second run", Nothing)` and `.test_data` is empty.
- "a run interrupted mid-body does not block the next run" also exercises in-process finalizers, not the sweep.
  Rename it "an in-process body exception releases everything before a successor starts", correct its
  comments, and assert `listDirectory parent == []` before the successor runs.
- "a run that never releases its generated config settles both the file and the record" asserts the install
  inside a `try @SomeException`, so a failed acquisition is swallowed. Throw a dedicated seeded-kill exception
  type and catch only it, return the acquisition result out of the body, and assert the file existed at the
  same `configPath` checked afterwards.
- "the owned durable root is a per-run generation under .test_data" checks only the count and kind. Run it
  under typed ownership and assert `generations == [T.unpack (runIdText (harnessRootRunId root))]`.
- The racing-harness case holds the winner for a fixed `threadDelay 3000000` and counts any `Left` as an
  exclusion. Make the winner hold until every competitor has written its refusal file; make
  `runHarnessAcquireProbe` exit 3 only when its reason contains the `liveRunHoldsProject` text (Sprint 19.1) and
  exit 5 otherwise; assert each of the three loser reasons contains that text.
- "an incomplete migration that recorded an effect is still refused" matches only `"effect"`. Assert the reason
  contains the seeded record key `effect.<project>.<run>.seeded` that `ModeEffectsRecorded` renders.
- The two exception-propagation cases accept any exception. Match `fromException` to an `IOException` whose
  message is "seeded failure", and to the `AsyncException` `ThreadKilled`.
- Add `mkCaseId "-a" @?= Left (InvalidCaseId "-a")` and `mkVariantId ".v" @?= Left (InvalidVariantId ".v")`
  to "validated IDs reject empty, malformed, and reserved values".
- "emptySuite `all` renders 0/0 passed" passes an empty variant list. Drive
  `selectTestMatrix AllCases emptyTestMatrix`, assert it yields no variants, and render the 0/0 card from that.
- "a bring-up LifecycleFailure renders its cause, never a bare ExitFailure 1" uses infix checks. Assert
  `lookup "[v0] a" rs @?= Just (LifecycleFailed ("bring-up failed: " ++ cause))`.
- The Cabal privacy guard slices the main library only up to `other-modules:` and finds
  `visibility: private` anywhere in the file. Slice the `library harness-lifecycle-internal` stanza and assert it
  contains `visibility: private`; check the whole main-library stanza, including `reexported-modules`, for
  `HostBootstrap.Harness.Lifecycle.Internal` and `HostBootstrap.Harness.Ownership.Internal`; and assert both
  slices are non-empty before the negative checks.

### Sprint 19.10: Harness module contracts state what the code does [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/HarnessSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`, `core/hostbootstrap-core/test/ContextSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`,
`documents/architecture/harness_workflow.md`

#### Objective

The Haddock and module headers of the harness engine and its ownership bracket describe the behaviour the
code has, and the `Case` record carries no field that nothing reads.

#### Deliverables

- The `HostBootstrap.Harness.Ownership` module header lists every branch the sweep resolves.
- The config-existence comment in `Ownership.hs` describes the same division of labour between the recheck and
  the acquisition-time refusal that the `Harness.hs` and `Command.hs` comments describe.
- The `Refused` Haddock covers late refusals after acquisition.
- The `TestSuite` and `emptySuite` Haddocks name `bareClusterLiveSuite` in `HostBootstrap.CLI.Bare`, with its
  one cluster-live Kind case, as the suite the bare binary ships.
- `Case` carries an id and a `CaseLifecycle` only.

#### Validation

A `HarnessSpec` source guard asserts `caseWeight` and `caseIndivisible` are absent from `Harness.hs`, and
`cabal test all` from `core/` and from `demo/` passes with the bare suite, the core fixtures, and the demo's
case matrix rebuilt on the narrowed `Case`.

#### Remaining Work

- Rewrite step 1 and the closing paragraph of the `HostBootstrap.Harness.Ownership` module header, which say
  the sweep resolves only a bound run whose records prove it acquired nothing. List the resolved branches:
  pre-effect close, persisted `Closing` finalization, incomplete-migration discard, completed-migration
  activation, and recovered-forest teardown through the `RecoveredResourceExecutor`; say that only the
  executor's refusal or an unresolved ownership error blocks the new run.
- `acquireOwnedRunConfig`'s Haddock calls its refusal "the authoritative" production-config refusal, while the
  `testSafetyPreconditions` Haddock and the `HostBootstrap.Command` comment name `harnessPreconditions`.
  Rewrite the `acquireOwnedRunConfig` Haddock to name `harnessPreconditions` as the authoritative recheck
  inside the mode compare-and-swap and itself as the acquisition-time refusal that closes the window after it.
- The `Refused` Haddock says nothing was acquired, but late refusals (`lateRefusal` in `HostBootstrap.Command`)
  classify as `Refused` after acquisition and a reverse. State that a `REFUSED` row either preceded
  acquisition or followed it with the run's owned state reversed.
- The `TestSuite` Haddock says the bare binary ships `emptySuite` through its bare entrypoint, and the
  `emptySuite` Haddock calls it the suite the bare binary ships; the bare binary ships `bareClusterLiveSuite`
  (its explicit bare entrypoint in `HostBootstrap.CLI` passes `bareClusterLiveSuite progName` to `runCLI`),
  whose one case asserts a live harness-owned Kind cluster, and only `HarnessSpec` and `CLISpec` use
  `emptySuite`. Rewrite both to name `bareClusterLiveSuite`, and
  state that `emptySuite` is the zero-case suite the `0/0 passed` rendering is pinned against.
- Delete `caseWeight` and `caseIndivisible` from `Case` and the budget-slicing Haddock above `CaseLifecycle`;
  nothing reads either field. Update every `Case` construction in the same change — `bareClusterLiveSuite` in
  `HostBootstrap.CLI.Bare`, `HarnessSpec`, `CLISpec`, `ContextSpec`, `RecursiveLifecycleSpec`, and the demo's
  five cases in `demo/src/HostBootstrapDemo/Commands.hs` — and add the source guard.

### Sprint 19.11: A multi-frame Harness test run crosses the authenticated child boundary [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`
**Production modules**: `HostBootstrap.Handoff`, `HostBootstrap.Command.Child` (2; cap 3)
**Sprint budget**: one pure capsule-parse function moved behind an exposed name and no new behaviour; at most
80 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`,
`documents/architecture/harness_workflow.md`

#### Objective

A Harness test run whose plan places steps in VM and container frames crosses the same authenticated process
boundaries a Production `project up` does: each child admits the Harness root-scope capsule, interprets its
frame under the exact run, and the normal and recovery reverses unwind child-first. The child's capsule read is
a pure parse a unit test can reach.

#### Deliverables

- `HostBootstrap.Handoff` exports `harnessScopeCapsuleRun :: ByteString -> Either Text Text`, the seven-frame
  parse of a rendered Harness root-scope capsule. It accepts exactly seven frames whose kind field is `harness`
  and whose run field is UTF-8, and refuses with "the authenticated Harness scope run is not UTF-8", "the
  authenticated Harness scope capsule differs", or "the authenticated Harness scope capsule has trailing
  bytes". `harnessConfigAuthorityFromEdge` in `HostBootstrap.Command.Child` mints its authority from that
  result and holds no parse of its own.
- The recursive POSIX fixture in `RecursiveLifecycleSpec` runs a Harness `test run all` across the root, VM, and
  container frames, so `runHarness` admits each child frame and the reverse unwinds both child-first.
- A Harness test run hard-killed after its child frames came up is reversed by the next `test run`'s sweep
  through the recovery descent, so `runHarnessRecovery` admits each child frame of the abandoned run.

#### Validation

`HandoffSpec` carries the four capsule-parse cases and `RecursiveLifecycleSpec` the two Harness process cases
named in Remaining Work; they exist and pass under `cabal test all` from `core/` on a POSIX gate host, where
`withLocalGuestFrame` runs them rather than skipping.

#### Remaining Work

- Move the capsule parse. Lift the frame walk out of `harnessConfigAuthorityFromEdge` into
  `harnessScopeCapsuleRun` in `HostBootstrap.Handoff`, keeping the three refusal texts, and call it on
  `renderAuthenticatedRootScope (receivedEdgeAuthenticatedRootScope edge)`. Tests in `HandoffSpec`, building wire
  bytes with `authenticatedRootScopeOracleWire`: a `harness` capsule with run bytes `"run-1"` returns
  `Right "run-1"`; run bytes `"\xff"` return `Left "the authenticated Harness scope run is not UTF-8"`; kind
  `"production"` returns `Left "the authenticated Harness scope capsule differs"`; a valid capsule with one
  further handoff frame appended returns `Left "the authenticated Harness scope capsule has trailing bytes"`.
- Add the forward Harness process case. In `RecursiveLifecycleSpec`, add a root entry that runs
  `test init` then `test run all` against the existing recursive fixture spec (its `passingSuite` and
  `HarnessAssembly` already exist), and a case "a Harness test run crosses two real authenticated process
  boundaries and reverses them child-first" under `withLocalGuestFrame` and `withFixtureEnvironment False`: the
  process exits `ExitSuccess`, the fixture's `reverse-attempts` file reads `container`, `vm`, `root` in that
  order, and afterwards
  the root's protected store holds no `mode.` record and no incomplete `lease.` record.
- Add the recovery Harness process case. Give the fixture a switch that makes the container step write a ready
  file and block; spawn the Harness `test run all`, wait for the ready file, hard-kill the root process, then run
  `test run all` again with the switch off. Assert the second run exits `ExitSuccess`, the `reverse-attempts` file
  shows the abandoned run's `vm` reversed before its `root`, both ahead of the second run's own reverse entries,
  and no `mode.` or incomplete `lease.` record remains.

### Sprint 19.12: The harness precondition recheck holds both halves it names [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Mode`, `HostBootstrap.Harness.Ownership` (2; cap 3)
**Sprint budget**: no new named type, one export narrowed, and one call-site probe adoption; at most 60
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

`withHarnessRoot` rechecks both hard safety preconditions — no sibling production config and no running
production cluster — inside the protected entry that takes the Harness mode, using the project's real
Production-state probe; no caller outside `HostBootstrap.Lifecycle.Mode` can replace the assembled probe; and
the `HarnessPreconditions` Haddock names which inputs the caller supplies.

#### Deliverables

- `HostBootstrap.Lifecycle.Mode` exports `HarnessPreconditions` abstractly: the `harnessPreconditionProbe` field
  label leaves the export list, so record update cannot replace the assembled probe outside the module.
- The `HarnessPreconditions` and `harnessPreconditions` Haddocks say the sibling directory and the
  production-cluster liveness probe are caller-supplied inputs — the command derives the directory from the
  executable's own path and the project supplies the probe — and that the producer assembles both checks into
  one probe the mode entry runs.
- `ownProjectRun` in `HostBootstrap.Harness.Ownership` passes the suite's Production-state probe into
  `harnessPreconditions` as `isLeft <$> safety` instead of `pure False`, so the in-entry recheck covers the
  cluster half as well as the sibling config; the comment at that call states this.
- A live production cluster observed inside the entry refuses with `ModeHarnessRefused ProductionClusterRunning`
  and writes no mode or lease record.

#### Validation

The `AuthoritySpec` case and the `CompileFailSpec` fixture named in Remaining Work exist and pass, the existing
`HarnessSpec` ownership cases still pass with the real probe threaded through, and `cabal test all` from
`core/` and from `demo/` passes.

#### Remaining Work

- Narrow the export and correct the Haddocks. Remove `harnessPreconditionProbe` from the
  `HostBootstrap.Lifecycle.Mode` export list (only `withHarnessRoot`, inside the module, reads it) and rewrite
  the two Haddocks as the Deliverables state. Test: a `CompileFailSpec` fixture
  `test/compile-fail/ReplaceHarnessPreconditionProbe.hs` that applies the record update
  `(harnessPreconditions project dir (pure True)) {harnessPreconditionProbe = pure (Right ())}` is registered
  with `rejectsWith` and a diagnostic naming `harnessPreconditionProbe` as not in scope.
- Thread the real probe. In `ownProjectRun`, replace `(pure False)` with `(isLeft <$> safety)`. Test: the
  existing `HarnessSpec` case for the post-sweep Production-state refusal (Sprint 19.1) still observes
  `SafetyRefusal` from the outer probe, and a `HarnessSpec` case calls `runWithOwnedRunAfterRecovery ownership
  probe` with an `IORef`-counted probe that returns `Right ()` on its first call and `Left "cluster appeared"` on
  its second: it returns a `Left` containing "a production cluster is already running; refusing to touch
  production state", the body never runs, and no `.test_data` generation, sibling `<project>.dhall`, `mode.`,
  `config.`, or `dataroot.` record is left behind.
- Produce the cluster refusal. Add an `AuthoritySpec` case "a running production cluster refuses the harness
  mode inside the entry": after `sweep`, take `protectedStoreImage`, call `withHarnessRoot` with
  `harnessPreconditions project "/nonexistent-hostbootstrap-dir" (pure True)`, assert the result is exactly
  `Left (ModeHarnessRefused ProductionClusterRunning)` and the body never ran, and assert `protectedStoreImage`
  afterwards equals the image before.

### Sprint 19.13: Harness run closure is recoverable at every crash point [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Mode` (1; cap 3)
**Sprint budget**: no new named type and one sweep branch; at most 80 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

A Harness close records the run's lease `Closed` and then releases the `mode.<project>` record as two separate
protected writes, and `closeHarnessRun`'s Haddock promises that a crash between them leaves the run
recoverable. The abandoned-run sweep enumerates only incomplete leases, so it never reaches a Harness mode whose
run's lease is already closed, and every later Harness or Production opener is refused with
`ModeHeldByAnother`. This sprint makes the sweep release such a stranded mode and makes the `AuthoritySpec`
harness close and sweep cases assert the state their names claim.

#### Deliverables

- After its incomplete-lease recheck comes back empty, `recoverAbandonedHarnessRuns` reads `mode.<project>`;
  when it holds `WireHarness run` and that run's lease record is `LeaseClosed` or absent, it releases the mode
  through `releaseModeIfRunKey` before minting `ClosedAbandonedHarnessRuns`. The sweep runs under the project
  liveness lock, so no live run can be in that state. A Production mode and a Harness mode whose lease is still
  incomplete are untouched.
- The abandoned-unbound sweep case proves the mode is released and the project admits a fresh Harness run.
- The refused settled-close authorization is proven to leave the protected store unchanged.
- The short-close case is named for the end state it checks, and a separate case constructs the interrupted
  lease-closed, mode-held state and proves the sweep recovers it.

#### Validation

The four `AuthoritySpec` cases named in Remaining Work exist in their stated form and pass under
`cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- Release the stranded Harness mode in the sweep, as the Deliverables state. Test: an `AuthoritySpec` case "a
  Harness mode stranded behind a closed lease is released by the next sweep": inside `withHarnessRoot`, read the
  `mode.<project>` record bytes before a pre-effect `closeHarnessRun` (built as the short-close case builds it),
  let the close complete, then rewrite those bytes with `compareAndSwapProtectedRecord session modeKey
  ExpectAbsent`. Afterwards `recoverAbandonedHarnessRuns store project neverResolves neverResolves` returns
  `Right`, `mode.<project>` reads `Right Nothing`, and `withHarnessRoot` with the returned proof acquires a run
  whose `runIdText` differs from the closed run's. A second case does the same and also deletes the run's
  `lease.` record with `compareAndDeleteProtectedRecord`, asserting the same three outcomes.
- "an abandoned unbound lease is swept and its mode released" asserts only the swept count. After the sweep,
  read `mode.<project>` through `withProtectedEntry'` and assert `Right Nothing`, then call `withHarnessRoot`
  with the returned proof and assert it returns `Right` with a run id different from the one
  `abandonHarnessRun` returned.
- "a pre-effect proof cannot authorize settled close, and its short close releases mode last" takes no store
  image around the refused `authorizeHarnessClose`. Inside the open session, collect every record's key, version,
  and bytes through `listProtectedRecords session` and `readProtectedRecord session` (the projection
  `protectedStoreImage` takes) before and after the refused call, and assert the two are equal, so no `Closing`
  epoch is written before the closure-kind guard.
- Rename that case "a pre-effect proof cannot authorize settled close, and its short close frees the project
  for the next run"; the release-last ordering is proven by the stranded-mode case above.

### Sprint 19.14: Project assertions return a pass/fail verdict [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI/Bare.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Production modules**: `HostBootstrap.Harness`, `HostBootstrap.CLI.Bare`, `HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: one new named type and one engine mapping, with every assertion call site retyped; at most
120 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

A project assertion can say only pass or fail. `REFUSED`, `CONFLICT`, `SKIPPED`, `BROKEN`, and `LEAKED?` rows
are the engine's classification of lifecycle and cleanup outcomes, so the type of a `TestSuite` assertion
cannot produce them. Today `CaseResult` exports all seven constructors, the assertion has type
`env -> Case -> IO CaseResult`, and `assertSeams` hands its value to the card unchanged, so the `CaseResult`
Haddock's claim that "a project assertion cannot label itself a refusal or a teardown failure" does not hold.

#### Deliverables

- `HostBootstrap.Harness` exports `AssertionVerdict` with exactly two constructors, `AssertionPass` and
  `AssertionFail String`.
- The `TestSuite` per-case assertion has type `env -> Case -> IO AssertionVerdict`, and `assertSeams` maps
  `AssertionPass` to `Pass` and `AssertionFail reason` to `Fail reason`; no other `CaseResult` constructor is
  reachable from a project assertion.
- `emptySuite`, `bareClusterLiveSuite`, `demoAssert` and the demo assertion helpers it calls, and every core
  test suite fixture return `AssertionVerdict`.
- The `CaseResult` Haddock states that the assertion's type is what keeps the engine-classified constructors
  out of a project's reach.

#### Validation

The `CompileFailSpec` fixture and the `HarnessSpec` cases named in Remaining Work exist and pass, and
`cabal test all` from `core/` and from `demo/` passes with every suite retyped.

#### Remaining Work

- Add `AssertionVerdict`, retype the `TestSuite` assertion field, and map the verdict in `assertSeams`. Retype
  `emptySuite`, `bareClusterLiveSuite`'s `assertLive`, `demoAssert`, `assertReachable`, `assertE2EInVM`,
  `assertRegistrySurvivesRestart`, `assertDurableReadback`, and the suite fixtures in `HarnessSpec`, `CLISpec`,
  `ContextSpec`, and `RecursiveLifecycleSpec`, and rewrite the `CaseResult` Haddock as the Deliverables state.
- Test: a `CompileFailSpec` fixture `test/compile-fail/AssertionReturnsRefused.hs` builds a `TestSuite` whose
  assertion is `\_ _ -> pure (Refused "self-labelled")`, registered with `rejectsWith` and a diagnostic naming
  `AssertionVerdict`.
- Test: a `HarnessSpec` case over one variant whose assertion returns `AssertionPass` for case `a` and
  `AssertionFail "no"` for case `b` asserts the rows `[v0] a` `Pass` and `[v0] b` `Fail "no"`.

### Sprint 19.15: A Harness run trips on changed production state [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Production modules**: `HostBootstrap.Harness`, `HostBootstrap.Command` (2; cap 3)
**Sprint budget**: one new named type and one engine argument; at most 150 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

Safety-contract item 6 — a Harness run neither opens, mounts, reconciles, nor deletes `.data` or the production
cluster — rests on profile derivation alone: `profileDataSegments` gives a Harness profile `.test_data/<run>`
and the run-scoped cluster name, so no Harness plan names a production target, but nothing observes a run that
changes one anyway. This sprint adds a runtime tripwire that fails the run when production state changed
across a variant. Read access stays excluded by profile derivation; the tripwire observes changes.

#### Deliverables

- `HostBootstrap.Harness` exports `ProductionStateObservation` and
  `observeProductionState :: FilePath -> IO Bool -> IO ProductionStateObservation`, which records the recursive
  listing of the given `.data` path (relative path, entry kind, size, and modification time, with an absent
  directory as its own value) together with the production-cluster liveness probe's answer.
- `runSuiteSelection` takes the project's production `.data` path. Around each variant's ownership bracket the
  engine observes production state, with the suite's own safety probe as the cluster half, before the bracket
  is entered and after it returns.
- A changed observation appends a `[vN] production-state tripwire` `TeardownFailed` row naming the first
  changed path or "a production cluster started", and every later variant renders `REFUSED` with "a prior
  variant changed production state" without entering its ownership.
- The `test run` command passes `durableDataPath` over the canonical project root, the same derivation
  Production uses, so the tripwire watches the directory a Production run owns.

#### Validation

The three `HarnessSpec` cases and the `CLISpec` case named in Remaining Work exist and pass under
`cabal test all` from `core/` and from `demo/`.

#### Remaining Work

- Add `ProductionStateObservation` and `observeProductionState`, thread the `.data` path through
  `runSuiteSelection`, observe before and after each variant's ownership bracket, and pass `durableDataPath`
  over the canonical project root from the `test run` command.
- Test: a `HarnessSpec` case over two variants whose first variant's forward lifecycle writes `.data/leak`
  under a temporary project root asserts a `[v0] production-state tripwire` `TeardownFailed` row whose reason
  names `leak`, renders every v1 case `REFUSED` with "a prior variant changed production state", and observes
  through an `IORef` that v1's lifecycle is never entered.
- Test: a `HarnessSpec` case whose safety probe returns `Right ()` until v0's forward lifecycle flips an
  `IORef`, then `Left`, asserts the `[v0] production-state tripwire` row names "a production cluster started".
- Test: a `HarnessSpec` case over two passing variants with an untouched `.data` asserts no row label
  contains `production-state tripwire`.
- Test: a `CLISpec` command-level case whose Harness assertion writes a file under the project root's `.data`
  asserts the printed card carries the `production-state tripwire` row and the command exits non-zero.

## Remaining Work

- Sprint 19.1: close a refused data-root acquisition, keep the finalizer verdict on the exception path, cover
  the post-sweep safety refusal, name the liveness lock neutrally, and type the ownership coordinates.
- Sprint 19.2: report a generated-config release conflict as cleanup, block later variants after an escaped
  exception, keep completed rows on a safety refusal, classify restart failures, and isolate a throwing
  `runMatrix` teardown.
- Sprint 19.3: refuse config acquisition through an `OwnedHarnessRoot` that escaped its bracket, and raise
  `LifecycleFailure` instead of `die` inside `variantWithLifecycle`.
- Sprint 19.4: anchor the observation marker `classifyLifecycleReason` reads, and make the `StepSpec` layering
  guard token-level.
- Sprint 19.9: make each `HarnessSpec` case assert the exact outcome and mechanism it names.
- Sprint 19.10: align the harness module contracts, including the bare-suite Haddocks, with the code and delete
  the unread `Case` fields.
- Sprint 19.11: expose the Harness capsule parse and run a multi-frame Harness test run, forward and recovered.
- Sprint 19.12: recheck both harness preconditions inside the mode entry and stop exporting the probe field.
- Sprint 19.13: release a Harness mode stranded behind a closed lease, and tighten the harness close and sweep
  cases in `AuthoritySpec`.
- Sprint 19.14: narrow the `TestSuite` assertion result to `AssertionVerdict` so a project cannot return an
  engine classification.
- Sprint 19.15: add the runtime tripwire that fails a Harness run whose variant changed `.data` or started a
  production cluster.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — the surface this phase changes in it.
- `documents/architecture/harness_workflow.md` — the ownership bracket, the sweep, and the engine.
- `documents/architecture/run_models.md` — execution shape is the lifecycle plan.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the report card, per-variant isolation, and what the static suites cannot
  cover.

**Cross-references to add:**
- `development_plan_standards.md` §§ W, Y, and Z name this phase as the owner of the Harness command consumer
  and assertion engine.
