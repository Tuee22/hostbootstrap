# Phase 5 — Installed identity, operator verification, and authority kernels

**Status**: Done
**Depends on**: Phase 4 (protected store)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`, including the compile-fail fixtures,
host-native on the gate host that runs it
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-27 ; native Windows 11 10.0.26300.9457 x86_64, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` from core and all four canonical host-static legs (§ JJ) ; pass ; covers in-gate
**Gate evidence**: 2026-10-27 ; x86_64 Ubuntu 24.04.4 Linux CPU container, GHC 9.12.4, Cabal 3.16.1.0 ; complete `cabal test all` core gate ; pass ; covers in-gate

> **Purpose**: Turn independently verified executable, operating-system, store, and generation facts into
> opaque authority inputs, while leaving lifecycle-specific command admission to the phases that possess
> the complete plan, lease, frame, cursor, and context package.

## Phase Objective

An invocation cannot establish authority by choosing a phantom type, replaying a recorded integer, or
presenting descriptive configuration. This phase supplies the lower authority vocabulary and the sealed
compare-and-swap kernels later lifecycle gates consume. The safe facade verifies installed identity and
the current OS principal, exposes opaque inspection, and parses the closed verb vocabulary; only the
allow-listed package implementation can allocate a fresh epoch, select a root scope, or reserve a command
invocation. Recorded recovery evidence reopens an epoch only through the allow-listed package-private
reifier, which accepts exactly the currently allocated nonzero generation and never advances the counter.

## Sprints

### Sprint 5.1: Closed verb and phase vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make lifecycle verbs and phases closed type-indexed vocabularies.

#### Deliverables

- `ProjectVerb` is a GADT over `VerbUp`, `VerbDown`, and `VerbDestroy`; a value for one verb cannot inhabit
  another.
- `LifecyclePhase` distinguishes `PreparePhase`, `ExecutePhase`, and `TeardownPhase` at the type level.
- Parsing yields one existential member of the closed verb set or a typed refusal; there is no text-backed
  extension constructor.

#### Validation

`AuthoritySpec` covers every accepted verb, unknown-verb refusal, and exact rendering.

#### Remaining Work

None.

### Sprint 5.2: Generative installed project identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Bind project identity before any plan, run, or authority identity exists.

#### Deliverables

- `InstalledProjectIdentity projectId` has a hidden constructor and exists only inside a rank-2 continuation.
- `withInstalledProjectIdentity` validates an ASCII stable project name against the normalized leaf of
  `getExecutablePath`, including the Windows `.exe` spelling, before minting `projectId`.
- The safe facade cannot fix project identity to a caller-chosen phantom or reconstruct it from its rendered
  name; Phase 7 threads this opener through the configuration and CLI surfaces.
- Stable record keys derive their project component only from `InstalledProjectIdentity`.
- The kernel opener `withInstalledProjectKernel` refuses an empty name, a name longer than 64 characters, and
  any character outside ASCII alphanumerics, `-`, and `_`, each with its own `AuthorityInvalidIdentity` reason.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` covers matching/mismatching executable identities, Windows suffix normalization, and invalid
  ASCII stable names (dotted and non-ASCII).
- `AuthoritySpec` asserts `withInstalledProjectIdentity ""` returns
  `Left (AuthorityInvalidIdentity "the installed project name must not be empty")`; a 65-character name
  returns `Left (AuthorityInvalidIdentity "the installed project name must be at most 64 characters")`; and a
  64-character name passes the length bound, so its refusal is the executable-mismatch reason
  ("does not match the invoked executable"), not the length reason.
- Pinned compile-fail fixtures cover constructor forgery, rank-2 escape, and nominal-index coercion; Phase 7
  covers propagation across distinct runtime invocations.

2026-10-26: the native Windows AuthoritySpec selection passed 153/153 cases in 17.37 seconds,
including all three exact boundary refusals. The complete phase gate remains owed after its other
sprints; the unchanged constructor/coercion fixtures passed in the preceding complete core gate.

#### Remaining Work

None.

### Sprint 5.2a: Source guards follow declared module homes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`, `core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Keep the existing authority boundaries checked when their implementation moves between library units.
This preparation is split before the extraction: maintaining the production documentation validator
beside the three-module type-home extraction would exceed § G's source-module ceiling.

#### Deliverables

- Architecture forbidden-boundary checks find every matching module under production source homes,
  including private units. A missing old main-library path cannot silently stop checking a relocated
  kernel. Explicit obsolete-module paths keep their own deletion meaning.
- Test source readers resolve actual module homes through Cabal library roots, deduplicate shared
  source directories and preserve normalized module identities in importer/producer inventories.
- Synthetic current, private and simultaneous homes prove the architecture refusal and its actual
  path; missing or ambiguous unique-home lookups refuse instead of guessing.

#### Validation

`DocValidatorSpec` checks relocated and duplicate-home forbidden shapes; `AuthoritySpec` and
`ProjectPlanSpec` retain their existing importer, producer and export assertions before the move.
The same readers must remain valid after Sprint 5.2b's extraction.

2026-10-27 UTC: focused native Windows checks passed DocValidatorSpec 17/17 in 6.71 seconds,
AuthoritySpec 157/157 in 21.40 seconds, and the actual project-plan group 92/92 in 37.00 seconds.
The identical Linux CPU snapshot passed 17/17 in 5.41 seconds, 157/157 in 12.64 seconds, and
92/92 in 33.36 seconds. Both builds retained warning-as-error policy. The complete phase gate
remains owed after its other sprints.

#### Remaining Work

None.

### Sprint 5.2b: One private authority type home and test seam [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/ProjectScope.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Testing.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/engineering/cabal_layout.md`

#### Objective

Give the suite access to real private authority values without duplicating their type definitions or
opening a downstream construction route. This foundation is split before implementation: the foreign
installed-project case in Sprint 5.2d needs the private fixture route originally scheduled in Sprint 5.3.

#### Deliverables

- One private authority sublibrary owns the existing kernel and shared project-scope types plus a narrow
  test seam. Main-library consumers and the suite use those same definitions; the public project-scope
  module is re-exported without exposing authority producers.
- The seam supplies the private installed-identity fixture needed to represent a genuinely different
  project name. Two public executable-verified openers cannot provide that evidence.
- A downstream compile-fail fixture and a private-stanza guard pin the seam's isolation. Source readers
  follow the actual source homes; no compatibility copy of the kernel is retained.

#### Validation

The component build, downstream import refusal and existing authority/compile-fail suites pass. The
private seam adds no CLI entry or exported main-library producer.

2026-10-27 UTC: complete Linux CPU core gate passed 2,714/2,714 in 396.99 seconds; native Windows
core passed 2,707/2,707 in 510.20 seconds. The demo workspace passed 164/164 demo cases in 5.84
seconds and 2,707/2,707 core cases in 516.75 seconds. Python checks passed with 376 tests in 9.07
seconds and 100% line/branch coverage. These complete runs include the exact private-unit/source-home
guard, both downstream authority import refusals, all registered compile-fail fixtures, and the
source-discovery checks after relocation. Kernel and scope source bytes were preserved during the move.

#### Remaining Work

None.

### Sprint 5.2c: Verified identity reaches the root command gate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Transport the independently verified identity through the root command path and consume it at the
root gate before reservation. The Command call sites make the original end-to-end adoption four
modules, so this three-module step precedes the two-module protected-entry adoption in Sprint 5.2d.

#### Deliverables

- Original Production and Harness installed identities pass from Command through the private Entry
  brackets into `authorizeRootProject`; no identity is reconstructed from recorded or rendered text.
- The root gate compares the verified name with the retained root name, returning exact
  `AuthorityStoreNotOurs` on disagreement, and uses that verified name for its existing project checks.
- Existing generic scope, plan, frame, broker, verb and phase relationships remain linked. The new
  identity argument is independently quantified and immediately consumed, with no unused carrier.

#### Validation

Root-gate cases exercise matching identity and exact foreign-identity refusal before invocation
consumption. CLI, Chain and project-plan source/call-shape checks cover all entry routes; existing
Production and Harness behaviour and compile-fail fixtures pass.

`AuthoritySpec` passed "the root gate reserves with the matching independently verified executable
identity" and "the root gate refuses a foreign root against the independently verified executable
identity without writes" using real canonical-root, store, profile, plan, snapshot, journal, Execute
cursor and lifecycle-context values. The two public frame openers select the same real frame; only
the cursor's fresh phantom is aligned in the fixture. Matching admission writes exactly one
invocation; foreign-root refusal preserves the full record image.

2026-10-27 UTC: both native Windows and Linux CPU selections passed authority 160, CLI 64, Chain 48,
project-plan 92, compile-fail 539 and documentation 17 cases. Windows group durations were 24.09,
27.31, 23.75, 36.51, 126.56 and 11.06 seconds; Linux durations were 13.31, 18.19, 19.93, 34.95,
88.74 and 5.39 seconds. The initial Prepare/Execute fixture mismatch was corrected by the real
`withExecuteLifecycleCursor` transition before these runs. Production changes are 57 changed lines
across three modules; the protected reservation bridge remains the next sprint's adoption.

#### Remaining Work

None.

### Sprint 5.2d: Verified identity reaches the protected reservation kernel [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/ProjectPlan.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Compare reservation evidence with the identity independently verified by root admission, rather than
reconstructing the comparator from that evidence's own recorded project name.

#### Deliverables

- Forward the executable-verified `InstalledProjectIdentity` already held by `authorizeRootProject`
  into `reserveCurrentLifecycleCommandKernel`; remove its recorded-name re-mint.
- The only production caller of `withInstalledProjectKernel` is the facade opener. A source guard
  derives all package source roots and compares normalized paths, accounting separately for the
  kernel's own definition and the private seam's re-export.
- A foreign-project journal/cursor pair reaches the real reservation kernel, returns
  `AuthorityStoreNotOurs`, and writes no invocation record.

#### Validation

`AuthoritySpec` pins the caller set. `SessionSpec` uses the existing drift pattern and the private
fixture seam to pair a journal/cursor from a genuinely different raw installed name, then asserts the
exact refusal and unchanged invocation inventory. Existing lifecycle callers compile and pass.

`SessionSpec` passed "the reservation bridge refuses a foreign journal against the independently
verified executable identity". Its default fixture keeps the public executable opener; the supplied
opener creates a genuine different project with internally matching root, reservation, journal and
current Execute cursor. The actual executable identity refuses at the direct Session bridge with
exact `AuthorityStoreNotOurs`, preserving all records and invocation rows. Retrying identical evidence
with its matching identity succeeds and adds exactly one invocation. The independent project index
requires no phantom coercion in this case. `AuthoritySpec` pins all-library caller sites and the
single protected-entry/live-source/current-cursor ordering.

2026-10-27 UTC: complete Linux CPU core gate passed 2,718/2,718 in 409.00 seconds; native Windows
core passed 2,711/2,711 in 520.03 seconds. The demo workspace passed 164/164 in 5.77 seconds and
2,711/2,711 core cases in 513.92 seconds. Both Python legs passed, with 376 tests in 6.89 seconds
and 100% line/branch coverage. The production adoption changes only ProjectPlan and Session; all
existing live/journal/source/current-cursor checks remain inside the same protected entry.

#### Remaining Work

None.

### Sprint 5.3: Verified OS principal [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Testing.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Represent the OS decision separately from lifecycle authority.

#### Deliverables

- `verifyOsPrincipal` asks the operating system to create and remove a probe in the exact protected records
  directory and yields opaque `VerifiedOsPrincipal` only on success.
- The evidence retains the protected-store identity and is refused by a kernel operating on another store.
- `VerifiedOsPrincipal` grants no verb, scope, plan, epoch, or command authority by itself.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` covers OS refusal ("OS-principal verification refuses an unavailable records directory") and
  matching-store evidence ("OS-principal evidence names the exact protected store").
- A kernel-level case opens two fixture stores A and B, verifies a principal in store A, presents it to
  `withVerifiedRootInvocationKernel` and to `withExistingVerifiedRootInvocationKernel` in a session of store B,
  and asserts `Left (AuthorityOperatorRefused "the operator authorization was issued for a different protected store")`
  with store B's protected image unchanged.

`AuthoritySpec` passed "fresh root admission refuses an OS principal issued by another store" and
"existing root admission refuses an OS principal issued by another store". Each uses a genuine
principal from A and a valid public Production root/epoch in B. A matching B principal first reaches
the callback exactly once without changing B's image; A's principal then returns the exact refusal,
never enters the callback, and preserves every B key, version and byte. Snapshots are taken outside
the protected entries. The seam adds only the Production scope witness and both existing root kernels;
production kernel behavior is unchanged.

2026-10-27 UTC: native Windows selections passed authority 163/163 in 22.61 seconds, the downstream
ImportAuthorityTesting fixture 1/1 in 0.51 seconds, and documentation 17/17 in 6.78 seconds. Linux CPU
passed the same selections in 14.23, 0.15 and 5.31 seconds. Exact private seam import/export guards
pass with the extended surface; the complete phase gate remains owed after its remaining sprints.

#### Remaining Work

None.

### Sprint 5.4: Broker epochs [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/LifecycleSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/OpenRecordedBrokerEpoch.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make a broker generation evidence of a protected transition, not an integer claim.

#### Deliverables

- `BrokerEpoch brokerGeneration` is opaque and generative.
- The package-private fresh opener advances the installed project's protected monotonic counter before yielding
  the new epoch and retains its exact project and store origin.
- Root admission rechecks that origin.
- The package-private recorded-value reifier `withReifiedAllocatedBrokerEpochKernel` takes a recorded `Word64`
  and yields a fresh-phantom `BrokerEpoch` only when that value is nonzero and equals the installed project's
  current protected allocation counter; it never advances the counter. It refuses a zero value ("a recorded
  broker generation must be positive"), an absent counter ("the recorded broker generation has no allocation
  counter"), a malformed counter ("the broker generation counter is malformed"), and any other value ("the
  recorded broker generation does not match the allocated counter").
- Its callers are allow-listed: `Lifecycle/Mode.hs` alone, at the committed-generation convergence and at
  `withRecordedEpoch` for existing-bound reverse-root recovery.
- The exposed modules offer no `Word64 -> BrokerEpoch` route, and nominal roles prevent coercing one generation
  index into another.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` covers monotonic allocation, malformed/exhausted counter refusal, and project/store separation.
- `LifecycleSpec`'s `existingBoundRefusalCases` carries a "broker counter deleted" row and a "broker counter
  malformed" row: each corrupts `broker.<project>.generation` under an existing bound Production run, drives the
  existing-bound recovery that reaches `withRecordedEpoch`, and asserts the exact `ModeAuthorityFailure`
  reason ("the recorded broker generation has no allocation counter", and "the broker generation counter is
  malformed") with no authority minted.
- A source guard pins the caller set of `withReifiedAllocatedBrokerEpochKernel` across
  `core/hostbootstrap-core/src` to `HostBootstrap/Authority/Kernel.hs` and `HostBootstrap/Lifecycle/Mode.hs`.
- Pinned compile-fail fixtures cover constructor opacity and nominal coercion. `OpenRecordedBrokerEpoch.hs`
  imports `withReifiedAllocatedBrokerEpochKernel` from `HostBootstrap.Authority` and from
  `HostBootstrap.Lifecycle.Mode` and pins "does not export 'withReifiedAllocatedBrokerEpochKernel'" for each.

The two `LifecycleSpec` rows reach existing-bound recovery through `withBoundPlanSnapshot`, not fresh
root allocation. They assert the complete exact `SnapshotVerificationError`, zero terminal/open
callbacks, and identical complete key/version/payload images after intentional counter deletion or
replacement. `AuthoritySpec` pins the Kernel export/signature/definition and Mode import/two genuine
applications across all library roots, with no seam re-export. The repaired fixture's two separate
module-specific diagnostics were also observed directly with pinned GHC 9.12.4.

2026-10-27 UTC: native Windows selections passed lifecycle 158/158 in 17.85 seconds, authority
164/164 in 24.77 seconds, repaired fixture 1/1 in 0.55 seconds, and documentation 17/17 in 6.88
seconds. Linux CPU passed lifecycle 160/160 in 25.36 seconds, authority 164/164 in 13.90 seconds,
fixture 1/1 in 0.23 seconds and documentation 17/17 in 5.54 seconds. Counts describe those named
pattern selections, including related lifecycle groups and their platform branches. Production
behavior is unchanged; the complete phase gate remains owed after the remaining sprints.

#### Remaining Work

None.

### Sprint 5.5: Scoped root invocation authority [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/ProjectScope.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Testing.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Verify one exact root invocation without letting a public caller select its lifecycle scope.

#### Deliverables

- `HostBootstrap.ProjectScope` defines the constructorless phantom scope indices `Production projectId` and
  `Harness projectId runId` that `scope` ranges over, shared by the authority kernel and the configuration
  vocabulary.
- `RootInvocationAuthority scope brokerGeneration verb` is opaque and retains the installed project, durable
  protected-store identity, project/store-bound broker epoch, and exact closed verb.
- Its package-private producer consumes the exact installed identity, verified OS principal, epoch, verb, and a
  scope selected by the composite lifecycle transaction.
- The verifier binds an unclaimed authority store to the installed identity with compare-and-swap and refuses a
  store already bound to another project.
- The exposed module offers no standalone root opener and no scope-selection witness.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` reaches the kernel through the composite Production/Harness brackets and covers project/store
  binding ("a store already bound to another project refuses this one" asserts `AuthorityStoreNotOurs`) and the
  retained project name. The verb and scope are type indices (`ProjectVerb VerbUp` has one inhabitant), so the
  compile-fail fixtures below are their proof. The runtime case "the root gate retains the installed project
  name" asserts that value; scope projection field mapping is Sprint 5.6's separate case.
- A kernel-level case allocates a `BrokerEpoch` in store A and presents it, with a principal verified in store B,
  to `withVerifiedRootInvocationKernel` and to `withExistingVerifiedRootInvocationKernel` in a session of store B,
  asserting `Left (AuthorityEpochOriginMismatch <project> <store B identity>)` with store B's protected image
  unchanged; a second case does the same with an epoch allocated for another installed project in store B.
- Pinned compile-fail fixtures cover constructor, scope-substitution, nominal-role, and public-opener absence.

`AuthoritySpec` passed fresh/existing variants of "root admission refuses an epoch allocated in
another store" and "root admission refuses an epoch allocated for another project in the same store".
All four compare equal generation words and matching-B callback controls, then assert exact
`AuthorityEpochOriginMismatch`, zero callbacks and an unchanged complete B record image. Foreign
stores use public roots; the other-project epoch is genuinely allocated in B, and the assertion action
runs after that protected entry unlocks. The project-name case is renamed and its ineffective `seq`
removed. Testing's added fresh producer is forwarding-only; the Kernel and Mode remain the only
production allocation sites.

2026-10-27 UTC: native Windows selections passed authority 168/168 in 26.04 seconds, project-plan
92/92 in 37.11 seconds, private-import fixture 1/1 in 0.53 seconds and documentation 17/17 in 6.44
seconds. Linux CPU passed the same selections in 15.64, 33.81, 0.15 and 5.55 seconds. The production
kernel is unchanged; the complete phase gate remains owed after its remaining sprints.

#### Remaining Work

None.

### Sprint 5.6: Root-scope narrowing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Testing.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Expose the root's established scope without exposing a scope constructor.

#### Deliverables

- `RootScopeAuthority scope` is opaque.
- `rootScopeAuthority` projects it only from `RootInvocationAuthority scope brokerGeneration verb`.
- No function converts one `RootScopeAuthority` to another scope or constructs one from configuration/context.
- The projection copies the root's project name, store identity, and epoch word into the matching fields; the
  project and store are both `Text`, so their order is a runtime property, not a type one.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`): compile-fail fixtures cover
construction and cross-scope substitution, and an `AuthoritySpec` case, through the private test seam Sprint 5.3
adds, opens a root in a fixture store and asserts `rootScopeProjectName (rootScopeAuthority root)` equals the
installed project name, `rootScopeStoreIdentity` equals that store's identity, and `rootScopeEpochWord` equals
`brokerEpochWord (rootAuthorityEpoch root)`.

Dated validation (2026-10-26, GHC 9.12.4/Cabal 3.16.1.0): the native Windows authority
selection passed 169 cases (26.30s), project-plan 92 (37.36s), private-import fixture 1 (0.45s),
and documentation 17 (6.52s). The identical working-tree snapshot on Linux CPU passed the same
169/92/1/17 cases (15.18/33.05/0.16/5.42s). The genuine second allocation proves all three
projection fields, including epoch word 2. Kernel behavior is unchanged. The phase closure
re-runs the complete declared gate.

#### Remaining Work

None.

### Sprint 5.7: Command authority vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Testing.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeCommandAuthority.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Define the opaque result shared by proof-complete lifecycle command gates.

#### Deliverables

- `CommandAuthority scope planId frame authorityEpoch verb phase` carries the exact scope, plan, frame,
  authority epoch, verb, and phase indices.
- Its constructor is package-private; the safe authority facade exposes inspection but no producer. The later
  proof-complete plan, child, and teardown gates own production: the root producer is the root-refined generic
  `authorizeRootProject` (Sprint 17.8) with a Cabal-private root-Up `LifecycleEntry` consumer, and this phase
  keeps the constructor and kernel ownership.
- `commandAuthorityEpoch` returns the indexed epoch value rather than erasing it to an unrelated word.
- `commandAuthorityMatchesStore` answers `True` only for the protected store the authority's retained broker
  epoch originated in; every effectful boundary that receives a store separately calls it.
- The private test seam forwards the two reservation kernels so this sprint can create a genuine
  command authority without depending on a future sprint; Sprint 5.8 extends this fixture foundation.
- `AuthorityError` carries only refusals some kernel or gate produces.
- The safe authority facade exports no generic lifecycle command-authority producer; the reservation producer
  remains package-private and proof-complete gates own its use.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- Pinned construction/coercion fixtures cover scope, plan, frame, and epoch indices, and the exported-surface
  guard (`authorityFacadeExports` in `AuthoritySpec`) pins the safe facade's absence of a generic producer.
- An `AuthoritySpec` case authorizes a root `CommandAuthority` in store A through this sprint's minimal reservation
  fixture and asserts `commandAuthorityMatchesStore authority storeA == True` and
  `commandAuthorityMatchesStore authority storeB == False` for a second opened fixture store B.
- A source guard asserts every `AuthorityError` constructor named in `Authority/Kernel.hs` is constructed at
  least once across every library source root outside `authorityErrorMessage`, excluding declarations,
  imports, strings, comments, and pattern-only occurrences. Closed construction witnesses fail on
  unsupported forms; positive and negative source fixtures prove the distinction.

Dated validation (2026-10-26, GHC 9.12.4/Cabal 3.16.1.0): native Windows passed the
197-case authority selection (25.26s), project-plan 92 (37.69s), compile-fail 539 (128.66s),
and documentation 17 (6.47s). The identical working-tree snapshot on Linux CPU passed the
same 197/92/539/17 selections (16.53/33.89/88.57/5.55s). The authority selection includes the
genuine two-store reservation case and 27 construction-witness cases covering full arity,
balanced expressions, the closed verb parser, declaration/rendering/pattern-only occurrences,
imports/comments/strings, and missing or ambiguous declarations. The phase closure re-runs
the complete declared gate.

#### Remaining Work

None.

### Sprint 5.8: One-use command reservation kernel [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Testing.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/engineering/testing.md`

#### Objective

Give later complete authorization gates one atomic reservation primitive.

#### Deliverables

- Package-private `CommandReservation` contains the stable installed-project, protected-store, plan-digest,
  frame-key, epoch, verb, and phase identity already verified by its caller.
- `reserveCommandInvocationKernel` refuses a reservation whose project differs from the supplied installed
  identity (`AuthorityStoreNotOurs`) or whose store differs from the session's store (`AuthorityWrongStore`),
  then compare-and-swaps the exact absent reservation record into place and reads it back before yielding
  `CommandAuthority`.
- The record key is SHA-256 over one canonical length-prefixed encoding; the complete encoding is retained in
  the record so a digest collision or any foreign record under that key refuses with
  `AuthorityReservationConflict` rather than consuming another invocation, and a read-back that does not return
  the written version and bytes refuses the same way.
- Reverse-root Teardown replay: the reservation carries a private replay flag, set by
  `reverseRootReplayEligible` exactly for `ProjectDown` and `ProjectDestroy` with `Teardown`. A byte-identical
  existing record for a replay-eligible reservation re-delivers `CommandAuthority` at that record's version, so
  a crashed root teardown resumes; every other byte-identical existing record refuses with
  `AuthorityInvocationConsumed`. The flag is not part of the canonical identity and `CommandAuthority` does not
  carry it. `reverseRootReplayEligible` enumerates every verb/phase pair with no wildcard, so a new verb or phase
  constructor forces a replay decision at compile time.
- For every reservation that is not replay-eligible, concurrent identical reservations have exactly one winner;
  changing any stable member names a distinct reservation.
- The kernel performs no plan, lease, frame, cursor, or context validation and is not an authorization gate.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`). The behavioural cases drive the
kernel directly through the private reservation fixture established by Sprint 5.7. This sprint extends
the forwarding seam with `reservationIdentity`, `invocationKey`, and
`withReifiedAllocatedBrokerEpochKernel`; its installed-identity, fresh-epoch and reservation producers
remain the same kernel definitions. No case depends on a later phase's plan, journal, cursor, or lifecycle lease. The shared setup opens a fixture
protected store, admits the test executable's identity (`Fixture.withFixtureInstalledProject`), verifies an OS
principal in that store, allocates one broker epoch `e` with `withFreshBrokerEpochKernel`, opens the root with
`withVerifiedRootInvocationKernel ProductionRootScope ... e ProjectUp`, and builds the base reservation
`R = commandReservationKernel root "plan-d" Execute "frame-f"`. Store reads and rewrites in the cases use
`HostBootstrap.Protected` (`readProtectedRecord`, `listProtectedRecords`, `compareAndSwapProtectedRecord`), which
the test suite already depends on through `ownership-internal`.

- The races use one rebuild-and-reserve routine, because the store's exclusive entry is held per session and a
  thread cannot re-enter it: the setup binds the store and allocates `e` in one session, records
  `brokerEpochWord e`, and leaves the session. The routine then enters its own session, admits the executable
  identity, verifies a principal, reifies `e` from its word with `withReifiedAllocatedBrokerEpochKernel`, reopens
  the root with `withExistingVerifiedRootInvocationKernel ProductionRootScope ... ProjectUp`, rebuilds `R`
  byte-identically, and calls `reserveCommandInvocationKernel`.
- One-winner race, threads: two `forkFinally` workers each run the routine; exactly one returns `CommandAuthority`,
  the other returns `AuthorityInvocationConsumed`, and `listProtectedRecords` shows exactly one `invocation.`
  record.
- One-winner race, processes: the parent starts the test executable with
  `--hostbootstrap-command-reservation-probe <store root> <epoch word> plan-d frame-f` (dispatched in `Spec.hs`
  in the form of AuthoritySpec's protected-entry probe) and runs the routine itself while the probe runs it;
  the probe prints and flushes a readiness line immediately before entering the shared routine. The
  parent holds the store entry until both contenders signal readiness, then releases it so both contend.
  The probe exits 0 on `CommandAuthority`, 3 on `AuthorityInvocationConsumed`, and 4 on invalid input or
  unexpected refusal. Exactly one of parent and probe wins, the other observes `AuthorityInvocationConsumed`, and the store holds exactly one `invocation.`
  record.
- Key distinctness, behavioural: after reserving `R`, each of these reservations changes exactly one member,
  returns `CommandAuthority` with a `commandAuthorityInvocation` different from `R`'s, and writes a second
  `invocation.` record: plan digest (`"plan-d2"`), frame (`"frame-f2"`), phase (`Prepare`, same root), verb (a
  second root opened over the same `e` with `ProjectDown`, phase `Execute`), epoch (a second fresh epoch, root
  `ProjectUp`), and store (a second fresh fixture store whose first allocated epoch carries the same word as `e`;
  the record is written in that store).
- Key distinctness, project: one store binds one project (`withVerifiedRootInvocationKernel` refuses a second
  with `AuthorityStoreNotOurs`), so the project member cannot change alone behaviourally. The case calls
  `reservationIdentity` twice with every argument equal except the project text and asserts the two encodings
  differ and `invocationKey` yields two different record keys.
- Project mismatch: `R` presented with an identity minted by `withInstalledProjectKernel "other-project"`
  returns `AuthorityStoreNotOurs "other-project" <executable name>` and writes no `invocation.` record.
- Conflict: for each of up `Execute`, down `Teardown`, and destroy `Teardown`, the case reserves once, rewrites
  that reservation's own record (key `invocationKey (reservationIdentity ...)`) with different bytes by
  `compareAndSwapProtectedRecord` at its current version, re-runs the same reservation, and asserts
  `AuthorityReservationConflict` with the record's version unchanged since the rewrite.
- Replay: a second identical `down` `Teardown` reservation and a second identical `destroy` `Teardown`
  reservation each return `CommandAuthority` with the same invocation id; a second identical `up` `Execute`
  reservation returns `AuthorityInvocationConsumed`.
- Wrong store: `R` (root opened in store A) presented in a session of a second fixture store B under the same
  installed identity returns `AuthorityWrongStore <store A identity> <store B identity>` and writes no
  `invocation.` record in B.
- Import guards restrict the kernel to its allow-listed package implementation: the ten package importers plus
  the private seam introduced in Sprint 5.2b and extended in Sprint 5.3. `SourceGuard.readLibrarySources`
  enumerates every library's declared roots, deduplicates physical paths and retains module identities;
  `SourceGuard.repoRelativePath` supplies separator-neutral paths for reports, so the allow-list names the
  same modules on every supported outer host realization (§ JJ). The
  configuration/reconciliation guard parses the kernel's imports with `SourceGuard.haskellImports` and asserts no
  imported module — qualified or not, and none in the transitive closure of its `HostBootstrap` imports —
  starts with `HostBootstrap.Config` or `HostBootstrap.Reconcile`. The closure walker resolves each
  `HostBootstrap` import against the `hs-source-dirs` of every `library` stanza in `hostbootstrap-core.cabal`
  (the kernel imports `HostBootstrap.Protected` from `internal/ownership`), and fails on a `HostBootstrap`
  import it cannot resolve rather than stopping there.

On 2026-08-17 the gate passed host-native on Windows 11 Home 10.0.26200 x86_64 (GHC 9.12.4, Cabal 3.16.1.0)
at 1,877/1,877, the first run to exercise the separator-neutral allow-list from a native-separator gate host.

Dated validation (2026-10-26, GHC 9.12.4/Cabal 3.16.1.0): native Windows passed the
224-case authority selection (24.74s), project-plan 92 (37.17s), compile-fail 539 (131.05s),
and documentation 17 (6.51s). The identical Linux CPU working-tree snapshot passed the same
224/92/539/17 selections (16.60/33.46/90.64/5.40s). The authority selection includes 17 direct
reservation/race cases and ten import-closure fixtures. Contenders announce readiness before
entry, acquisition/ownership handoffs are masked under cleanup, and each worker body runs with
its original masking state. The canonical wire/key golden uses a genuine first epoch. Both
private-seam guards allow only matching import/export tokens with no forwarding function body.
The phase closure re-runs the complete declared gate.

#### Remaining Work

None.

### Sprint 5.9: The identity decision reads the role it parsed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Writing the root config at the binary's own sibling path is what provisions the installed handoff and
build identities, and that decision is about the **role**, not about the spelling the role arrived in.
`--role` accepts aliases and normalises case and separators, so the decision is taken on the parsed
value the same function already produced.

#### Deliverables

- The initializer's default-role parameter is the parsed role kind, not its rendered text.
- The provisioning guard compares parsed role kinds.
- The parser default and help text render that value rather than carrying a second literal.
- Cases cover the canonical spelling, an accepted alias, and a case- and separator-normalised spelling, each asserting that identity is provisioned, and one non-default role asserting that it is not.
- The cases restore whatever the executable's siblings held: a sibling that existed beforehand is rewritten with
  its original bytes, and a sibling that was absent beforehand (the sibling `.dhall` and the five identity
  files) is deleted, so no case's expectation depends on the order it ran in and no signing seed is left beside
  the test executable.

#### Validation

The host static gate; the command suite is where the cases land. Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed
with the four `project init` cases green, including `--role host` and `--role "  HOST_Orchestrator  "`
each provisioning the five root identity files. Closure adds a `ContextSpec` case that runs
`withRestoredFiles` over a path absent beforehand, creates it inside the action, and asserts the path is
absent afterwards; and one over a path present beforehand, rewritten inside the action, asserting its
original bytes afterwards.

Dated validation (2026-10-26, GHC 9.12.4/Cabal 3.16.1.0): native Windows passed all 90
ContextSpec cases (1.92s) and 17 documentation cases (6.91s). The identical Linux CPU snapshot
passed the same 90 and 17 cases (2.17/5.17s). Both new six-sibling cases prove the action ran;
one verifies creation then deletion of all originally absent files, and the other restores distinct
binary bytes exactly. The role/alias provisioning cases remain green. Driver-owned executable
identities are preserved. The complete declared phase gate remains due at phase closure.

#### Remaining Work

None.

### Sprint 5.10: Every registered fixture pins the diagnostic it expects [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`,
`documents/engineering/testing.md`

#### Objective

§ HH requires a compile-fail fixture to fail *for its named reason*, because a fixture that merely
fails to compile is satisfied by a typo. Every registered fixture therefore states the phrase it
expects, and the registration takes no other shape — including the two the architecture page cites as
the proof for its readiness and capability boundaries.

The step-algebra phase owns removal of the unused reverse acquisition reopen kernel and its fixture.
This sprint pins that fixture's existing rejection with the same diagnostic-block rule as every other
registration; it changes no acquisition API.

#### Deliverables

- Every registered fixture carries one contiguous expected phrase, read from the diagnostic it actually produces.
- The capability and readiness fixtures the boundary table cites — `ForgePreparedGate.hs` and `RawReadiness.hs` — are among them.
- Expectations split across separately-matched fragments are re-joined into one phrase, because fragments can be satisfied independently by an unrelated error on the same line. The matcher enforces it: `rejectsWithUsing` splits stderr into per-diagnostic blocks, each expected phrase must match inside one block, and two expected phrases satisfied only by the same block fail the case. Fixtures compile with `-fno-diagnostics-show-caret`, so a block holds diagnostic text only and an echoed source line cannot satisfy a phrase.
- A phrase names the rejected slot or the boundary, not only one side of a mismatch or an echoed source line.
- The registration combinator takes `NonEmpty String`, so an unpinned fixture is not expressible rather than merely absent.
- Fixtures whose diagnostic is an arity or kind error rather than the boundary they are registered under are repaired to ask their own question, not re-pinned to what they happened to say: their signatures fully apply every type they name. `RawRegistryPlan.hs` supplies all six indices and an `Exposure`; `ForgeReadyBlobRoute.hs` supplies all six indices.
- Independent sealed values have independent required rejections: the session constructor forgeries use one file per value; ten recovery signing kernels use one capability-coercion file each; 34 role-lifecycle indices have distinct marker pairs, and both production-closure indices are checked. `RawReadiness.hs` requires separate `PollPolicy`, `Micros`, and `Ready` errors.
- Fixtures use live library consumers with correct argument positions: the Harness secret enters `productionSecretRefWire`, fresh snapshot evidence follows both valid callbacks as an extra argument, and provider capability escape starts from `ManagedProviderHandle`. Raw-admission cases also have constructor-import siblings.

#### Validation

The host static gate (`cabal test all` from `core/`). The compile-fail suite is the subject and the long pole.
Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, the public
boundary suite passed 522 cases in 83.11 seconds with every case stating its expected phrase.

Closure criteria: every fixture named in Remaining Work carries the repaired phrase below, copied from the
fixture's actual stderr; the per-block matcher is in place, fixtures compile with
`-fno-diagnostics-show-caret`, and every registration passes under both; and `rejectsWith` has type
`FilePath -> NonEmpty String -> TestTree`.

Dated validation (2026-10-26, GHC 9.12.4/Cabal 3.16.1.0): native Windows passed all 569
compile-fail/matcher cases (134.48s) and 17 documentation cases (6.66s). The identical Linux CPU
snapshot passed the same 569 and 17 cases (92.52/5.69s). These are 554 real, uniquely registered
fixtures plus 15 matcher cases. A separate public-only pinned-GHC audit matched all 554 fixtures'
required distinct diagnostic blocks, with no missing or unregistered files. The native matcher-only
selection passed 15 cases (0.30s). The PreparedGate constructor fixture makes only the boundary it
proves; the confirmed public record-update gap is tracked by its owning prepared-operations phase.
The full declared phase gate remains due at phase closure.

#### Remaining Work

None.

### Sprint 5.11: The session testing seam leaves the public surface [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/compile-fail/ForgeTransactionPermitFromDescriptor.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The direct-provider testing seam is private precisely so downstream code cannot use it to mint a value
in the sealed column, and the session seam is private for the same reason. Its types mint no authority;
the bytes it renders are the coordinator's own, and a consumer that could write them could put the
store into a state no run produced.

#### Deliverables

- `HostBootstrap.Lifecycle.Session.Testing` and the transaction vocabulary it re-exports live in a private sublibrary, the pattern the package already uses five times.
- A compile-fail fixture pins that a downstream consumer cannot import it, naming the sublibrary that holds it.
- The suite that legitimately uses it depends on the private sublibrary directly.

#### Validation

The host static gate (`cabal test all` from `core/`), plus the fixture. Dated evidence: on 2026-09-12, x86_64
Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal build all` and `cabal test all` from `core/`
passed, with the fixture reporting the seam as a member of the hidden `lifecycle-transaction-internal`
sublibrary.

#### Remaining Work

None. Which modules the `lifecycle-transaction-internal` stanza exposes beside the seam is the session phase's
(phase 10).

### Sprint 5.12: Coordinate types at the prepared-gate boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

§ HH states that a coordinate carried across a sealed boundary is a type. The prepared gate is the
smallest complete instance and the one the architecture page leads with: its producer takes three text
coordinates then three numeric ones, and the canonical renderer beside it has the same shape, so a
transposition would be invisible from mint to wire. This sprint is the pilot — one boundary, done
fully, so the cost of the remaining ones is judged from something real rather than estimated.

#### Deliverables

- Each coordinate role at this boundary is a newtype: the plan digest, the operation key, the session, the fence, the attempt, and the journal version.
- The rooted renderer's three further roles — the catalog identity, the frame, and the supersession generation — are newtypes too, so the generation that stands where a fence stands cannot be written in its place.
- The producer and the canonical renderer both take them, so the two cannot disagree about order.
- The fields, the accessors, and the framing are unchanged: no runtime representation changes and no durable byte changes. This is an argument-order proof, not a format change.

#### Objective boundary

What it cost: nine newtypes and one exported constructor each, four call sites wrapped, one round-trip
check inside the module wrapped, and two source guards re-stated against the new call shape. No
consumer of a gate changed, because the accessors still answer in the underlying types. That is the
price for one boundary of six-plus-three coordinates; the remaining sealed producers are not in this
sprint's scope.

#### Validation

The host static gate. The existing cases pin the canonical bytes, and they pass unchanged — which is
the evidence that the newtypes are a compile-time property only. Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed
2,517 tests.

#### Remaining Work

None.

### Sprint 5.13: Sealed export surfaces and fixture probes are pinned against the tree [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`

#### Objective

A compile-fail fixture that imports a name the tree never defines passes because that name is absent, not
because a live boundary holds. An exposed module that re-exports a sealed producer is caught only if some
fixture happens to probe that exact name, and an unregistered fixture is never compiled at all. This sprint
pins all three against the tree: every exposed module that imports a sealed witness's producer has its export
list pinned, every fixture file is registered once, and every registered fixture probes identifiers that exist.

#### Deliverables

- An export-surface guard pins the exact export list (`SourceGuard.moduleExportTokens`) of every exposed module
  in the main library stanza that imports a module listed in `other-modules` or a private sublibrary. The guard
  enumerates that set from `hostbootstrap-core.cabal` (`SourceGuard.mainLibraryStanza`,
  `SourceGuard.fieldModules`), unions an explicit supplemental set for locally sealed constructors
  (`HostBootstrap.RegistryPlan`), and fails on missing, duplicate, stale, or changed pinned lists.
  The set includes at least `HostBootstrap.Lifecycle.Context`, `HostBootstrap.Harness.Ownership`,
  `HostBootstrap.ProjectPlan.Construct`, `HostBootstrap.RegistryPlan`, `HostBootstrap.Lifecycle.Mode`, and
  `HostBootstrap.Lifecycle.Session`; the existing `authorityFacadeExports` and HandoffSpec guards count toward it.
- A registration-completeness check in `CompileFailSpec` asserts that every `.hs` file under `test/compile-fail`
  is registered exactly once (no unregistered file, no duplicate registration), that every registration names an
  existing file, and that every identifier and module named in a fixture's import lists is defined somewhere
  under `core/hostbootstrap-core/src` or `core/hostbootstrap-core/internal`.
- A stanza guard asserts that every `library <name>` stanza other than the main library carries
  `visibility: private`, because the compile-fail harness hides every non-main unit and so cannot see a
  sublibrary turned public.
- Each fixture the check flags is repointed at the live identifiers guarding the same boundary, or deleted when
  another registered fixture already holds that boundary.
- `OpenValidatedLifecycleContextAuthority.hs` imports `mintValidatedLifecycleContext` and
  `withValidatedRootLifecycleContext` from `HostBootstrap.Lifecycle.Context` and pins
  "Module 'HostBootstrap.Lifecycle.Context' does not export '<name>'" for each.
- `ImportRawHarnessCloseAction.hs` imports `newOwnedHarnessCloseControl` and `consumeOwnedHarnessClose` from
  `HostBootstrap.Harness.Ownership` and pins the does-not-export phrase for each; a new
  `ImportHarnessOwnershipInternal.hs` pins that `HostBootstrap.Harness.Ownership.Internal` is a hidden module.
- `OpenAuthenticatedChildCursorEvidence.hs` imports `mintChildPlanAuthorityKernel` and
  `childPlanAuthorityBindingKernel` from `HostBootstrap.ProjectPlan.Construct`, pins the does-not-export phrase
  for each, and its comment names `ChildPlanAuthority`.
- Root-scope and installed-identity probes use the live `EscapeAuthenticatedRootScopeRun.hs`,
  `ForgeInstalledProjectIdentity.hs`, and `ImportAuthorityKernel.hs` boundaries.
  `OpenRecoveryChildPackageDecoder.hs` imports `recoveryChildPackageFromWireKernel` from `HostBootstrap.Handoff`
  and pins its does-not-export phrase; `ImportDirectTeardownAdvance.hs` probes `authorizationPointKey`.
  Constructor fixtures name actual constructors, including independent RootUp/Down/Destroy entry imports;
  empty phantom tags and a type name with no same-name constructor supply no capability proof.

#### Validation

The host static gate (`cabal test all` from `core/`). The export-surface guard, the registration-completeness
check, and the stanza guard exist and pass. Each repointed fixture passes with its new phrase copied from actual
stderr. Re-exporting `mintValidatedLifecycleContext` from `HostBootstrap.Lifecycle.Context` turns both the
export guard and the fixture red (checked once by hand when the sprint closes, then reverted). On 2026-10-25, 39
of the 524 registered fixtures named identifiers absent from the tree (33 of them only absent identifiers);
closure requires that count to be zero.

Dated validation (2026-10-26, GHC 9.12.4/Cabal 3.16.1.0): native Windows passed authority
243 (26.97s), project-plan 92 (37.58s), compile-fail/inventory 602 (131.47s), and documentation
17 (6.54s). The identical Linux CPU snapshot passed the same 243/92/602/17 selections
(17.85/33.74/90.55/5.57s). The 602 cases contain 536 uniquely registered fixture files,
15 diagnostic-matcher cases and 51 parser/inventory cases. The actual source import audit has
zero missing first-party modules/names. Export/visibility coverage includes 64 exact module
inventories and 19 real-tree/synthetic cases. A constructor-namespace audit also removes empty
phantom-tag probes and replaces type names with their actual root-entry/settlement constructors.

The declared manual negative proof ran natively on Windows: temporarily exporting
mintValidatedLifecycleContext made the real export guard and OpenValidatedLifecycleContextAuthority
fixture each fail, with both Cabal selections exiting 1. The finally restoration reproduced the
original source SHA-256 exactly. Rebuilding the restored interface passed the sealed selection
60 cases (33.91s), the targeted fixture 1 (0.47s), and documentation 17 (6.57s). No temporary
public export remains. The complete phase gate remains due at phase closure.

#### Remaining Work

None.

### Sprint 5.14: The authority kernel hashes through Digest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`, and the authority kernel derives its command
invocation names and `invocationKey` store keys with that export rather than with a byte-identical local copy,
so an invocation key recomputed elsewhere cannot drift from the one the kernel reserved.

#### Deliverables

- `Authority.Kernel` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its own.
- Every invocation name and `invocationKey` the kernel derives keeps the bytes `AuthoritySpec` pins.
- The authority unit depends on the existing ownership unit for Digest and carries no unused direct
  crypton or memory dependency.

#### Validation

`AuthoritySpec` passes unchanged inside the complete declared `cabal test all` gate from `core/`,
with `-Werror` inherited from the package's common warnings stanza. All four canonical host static
gate legs (§ JJ) pass; no extra command-line warning flag is needed.

Dated closure validation (2026-10-27, GHC 9.12.4/Cabal 3.16.1.0): the complete native
Windows core gate passed 2,860 cases (518.14s), and the Linux CPU core gate passed 2,867
(405.42s). The native Windows demo gate passed its 164 cases (5.91s) and its core dependency's
2,860 cases (519.94s). Every declared Cabal suite passed. These commands used only the
hide-successes output option; the package warning policy supplies -Werror. The existing canonical
reservation byte/key golden and complete authority/import/export/compile-fail guards passed unchanged.

Both canonical Python legs passed: ruff, Black and mypy were clean, and the full supported runner
passed 376 cases (9.11s) with 100% coverage over 1,585 statements and 460 branches. All four
host-static legs therefore passed natively on Windows; the Linux run independently passed the
phase's complete declared gate. No base-image input changed.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — installed identity, OS evidence, root scope, and the
  reservation kernel beneath proof-complete command gates.
- `documents/architecture/lifecycle_state_model.md` — the composite lifecycle transaction that alone scopes a
  root and the later consumers of `CommandAuthority`.
- `documents/architecture/unrepresentable_state.md` — compile-fail fixture discipline, the export-surface and
  registration guards, and the coordinate types at the prepared-gate boundary.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — compile-fail/export/import guards and the cross-process reservation race.

**Cross-references to add:**
- `development_plan_standards.md` § X and § EE name this phase as the owner of the lower authority vocabulary;
  Phases 9, 12, 13, 17, and 18 own its proof-complete lifecycle consumers.
