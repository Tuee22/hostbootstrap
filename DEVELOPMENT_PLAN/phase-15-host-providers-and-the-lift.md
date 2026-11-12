# Phase 15 — Host providers and the self-reference lift

**Status**: Active
**Depends on**: Phase 8 (ensure reconcilers), Phase 12 (step algebra and plan-owned resource
projections), Phase 13 (authenticated handoff and the frame-child entry), Phase 14 (the four ownership
clauses and host-local reservations)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/` on the gate host that runs it (§ C;
cross-family confirmation belongs to the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md)),
and
`HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all
--test-show-details=direct` from `core/` on native Linux/x86_64 with KVM and
Incus — the suite is built by the ordinary gate on every host and decides at runtime whether its
subject is present
**Gate kind**: deferred
**Gate evidence**: 2026-11-09 ; hostbootstrap-linux-d, Ubuntu 24.04.5 x86_64 under WSL2, Linux 6.18.54.1-microsoft-standard-WSL2, UID 1000, KVM API 12, Incus 6.0.0, GHC 9.12.4 and Cabal 3.16.1.0 ; `cabal test all` and `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` from `core/` ; pass ; covers 5e418496d4448417780495331bbcceed6e0c3fbaf24b9490b689c5db2810dec4
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider`
`core/hostbootstrap-core/provider-live`

> **Purpose**: Add one prepared provider boundary over the lower pure target vocabulary and generic
> self-reference Lift, with Incus and Direct as the baseline realizations.

## Phase Objective

Every frame operation names one closed provider operation. The selected provider descriptor, raw
discovery plan, managed provider authority, durable share, provider-bound execution, and guest
alias remain indexed to the same plan resource and backend realization. Incus holds the four ownership
clauses over VM and share mutation; Direct admits an already-local frame without claiming authority over
the host. Lima and WSL2 consume the same lower target and rendering contracts here and receive native
confirmation in their terminal substrate acceptance phases.

The frame table's rows (`HostBootstrap.Substrate.Frame`) and the repository-wide guard that holds § LL's
one crossing renderer are this phase's. The fold itself — `foldLeaf` in `HostBootstrap.Lift`, the one
place a frame-crossing argument vector is rendered — is the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md)'s, and this phase consumes it. The seam the
rows plug into is the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)'s.
Which drivers hold their clauses through the table is decided by whose objects they own: the cluster and
Colima drivers belong to the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md), and the
guest alias driver to the [worked-demo phase](phase-24-worked-demo.md), because replacing it needs the
project binary established inside the guest and § N forbids copying one in.

## Sprints

### Sprint 15.1: Opaque provider descriptor [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Expose one descriptive, non-constructible provider value selected from a closed provider kind.

#### Deliverables

- `ProviderKind` is closed over Incus, Lima, WSL2, and Direct.
- `SubstrateProvider` is abstract outside its defining module.
- Total selection covers every supported substrate/provider pair.
- Narrow accessors expose only provider kind, VM identity, Lift context, and pure descriptive plans.
- Construction, record update, selector escape, and representational coercion are rejected statically.

#### Validation

`ProviderSpec` covers total selection and descriptive projections; compile-fail fixtures cover the opaque
boundary. The phase static gate validates the complete module graph.

#### Remaining Work

None.

### Sprint 15.2: Uniform provider operation planning [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`, `documents/engineering/wsl2.md`,
`documents/architecture/durable_state.md`, `documents/architecture/readiness.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Represent each provider operation once as pure, total planning data.

#### Deliverables

- `ProviderOperation` names provision, ready, stop, delete, share, alias, and guest routing.
- Provision, readiness, stop, delete, and share planners have one signature across providers. The guest
  alias is planned and classified only by the prepared alias route in `Provider/Alias.hs`, so this module
  carries no alias classifier and no alias planner.
- Provider selection is data consumed by total folds rather than a consumer-side branch.
- A provider that cannot implement an operation returns a structured `Unsupported` result.
- Direct stop, delete, alias, and guest routes never appear successful.
- WSL2 delete is the guarded unregister, the global wall release, then `wsl --shutdown` — the same
  release-then-shutdown order stop uses — so the shared utility VM re-reads the restored `.wslconfig`
  instead of keeping the cordoned settings it booted with.
- The WSL2 cordon reconcile learns which distros run from `wsl --list --running --quiet`, which prints names
  only, so a localized `STATE` column on a non-English Windows cannot make a running distro read as stopped
  and trigger the global `wsl --shutdown`.
- The Incus share reconcile names its disk device from the declared host source and guest path, so a device
  attached for a different source reads as missing rather than as already reconciled. The name is
  `"hb-share-"` followed by the first 12 lowercase hex digits of the SHA-256 of the UTF-8 bytes of
  `sized source <> sized guestPath`, where `sized v` is the decimal character length of `v`, `":"`, then `v`
  (the framing `preparedShareBinding` in `Provider/Backend.hs` uses). For source and guest path
  `/srv/demo/.data` the name is `hb-share-82a329e0f07a`; for `/srv/other/.data` it is `hb-share-a017dbabc79b`.

#### Validation

ProviderSpec's "reboot-to-ready has one result shape" asserts the complete literal plan for all four
providers, including the WSL2 quiet running-name probe and the Lima start/shell argv. "stop and guarded
delete are explicit" asserts WSL2's guarded unregister, global-wall release and shutdown in that order.
"Direct stop and delete are structured refusals" retains the Direct refusals.

ProviderSpec's "Incus plans one idempotent disk device" asserts both specified SHA-256 names and literal
add-device argv. Exact membership returns no effects; another source's device, no device, or a suffixed
name returns the exact add effect. An independent Python hashlib calculation also matched both declared
vectors. "membership parsers are total" checks NUL-interleaved quiet WSL names, and Wsl2Spec's
"quiet WSL name lists strip UTF-16 NUL padding" retains the corresponding parser behavior.
"provider planning keeps aliases in the prepared route" rejects all ten deleted alias API identifiers;
AuthoritySpec's sealed-export inventory holds the reduced Provider/Wsl2 surfaces.

The native Windows regression selected 735 cases: 734 passed and one documentation check found a
remaining reference to the deleted AliasAbsent diagnostic. After that wording was corrected, all
17 DocValidatorSpec cases passed. The final complete Linux gates below re-executed the corrected
documentation and every core case. No passing 735-case run is claimed. Initial compiles also caught
an adjacent path helper accidentally removed with the alias block and an overloaded string fixture;
the helper was restored byte-for-byte and the fixture explicitly typed before the successful builds.

| Build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core main | 2026-11-03T22:39:09.443542+00:00 to 2026-11-03T22:39:26.924576+00:00 | 17.481128 | PASS; parent 0 |
| Native Windows demo main | 2026-11-03T22:39:09.443808+00:00 to 2026-11-03T22:39:29.989581+00:00 | 20.545888 | PASS; parent 0 |
| Native Windows core test | 2026-11-03T22:40:39.771330+00:00 to 2026-11-03T22:40:49.071757+00:00 | 9.300478 | PASS; parent 0 |
| Native Windows demo test | 2026-11-03T22:39:44.116102+00:00 to 2026-11-03T22:40:09.530336+00:00 | 25.414373 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T22:40:39.796388+00:00 to 2026-11-03T22:40:49.794246+00:00 | 9.997896 | PASS; parent 0 |
| Native Windows corrected documentation | 2026-11-03T22:47:54.805236+00:00 to 2026-11-03T22:48:00.860658+00:00 | 6.055438 | 17 cases pass; parent 0 |
| Native Windows complete demo | 2026-11-03T22:40:57.704879+00:00 to 2026-11-03T22:41:02.841010+00:00 | 5.136140 | 167 cases pass; parent 0 |

Native main/test build stderr is empty and both native test binaries use rts_thr. Native demo stderr
contains expected negative-fixture output. Existing permission fixtures describe their Windows/root
limitation and direct-Colima remains unsupported without Apple Silicon/opt-in; no new case is skipped.

The final source audit at 2026-11-03T22:48:05.545697+00:00 to
2026-11-03T22:48:05.555659+00:00 measures 170/182 nonempty/physical changed production lines across
two modules, 83/86 test lines across three files, and 72/77 canonical-document/ledger lines. Complete
reversals match the captured baseline. Preservation at 2026-11-03T22:48:05.996733+00:00 confirms all
985 other Haskell files, all 695 compiler fixtures and 1,104 other prior snapshot subjects unchanged.
The Windows path helper is exact; the prepared alias route, provider backend, ownership primitives,
Cabal/Python/demo source and base/warm inputs are unchanged. The four canonical documents describe the
prepared alias route and the corrected provider plans; the completed alias-state-machine ledger entry
is removed. LF and diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T22:48:15.657428+00:00 to 2026-11-03T22:54:16.629417+00:00 | 360.973957 | 4213 cases pass, 355.33 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T22:48:15.657272+00:00 to 2026-11-03T22:54:14.254996+00:00 | 358.599676 | 167 cases pass, 1.50 reported seconds; 4213 cases pass, 354.10 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T22:48:15.659178+00:00 to 2026-11-03T22:48:16.516352+00:00 | 0.857163 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T22:48:15.658111+00:00 to 2026-11-03T22:48:22.703878+00:00 | 7.045791 | 376 pass, 6.00 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: e317ffc43f0a8ac447da48023dcc4d668622fa5f623c1c2586b8ca2c63215f96
- owned965: 38353103a6b5887d7d679a7c4dc5aee7c0c806fcfba390a3e9d8f65658e9472c
- docs95: a8e26f6e785e8389755729a4152e778e470f4c66106939c7c28a7bec926d941e

The separate native live Incus gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T22:54:28.567315+00:00 to 2026-11-03T22:54:34.879865+00:00,
6.312543 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.3: Incus realization adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`,
`core/hostbootstrap-core/test/IncusSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Make the Incus lifecycle realization consume the lower Incus target and renderer.

#### Deliverables

- `HostBootstrap.Incus` reexports `IncusVM` and `execVMArgs` from the lower Lift context.
- The module owns lifecycle probes and builders only.
- Launch arguments apply declared CPU, memory, storage, image, and VM identity.
- Share and readiness builders preserve the exact target declaration.
- A source guard keeps the dependency direction from Lift context to provider realization downward.

#### Validation

`IncusSpec` covers lifecycle argument shapes; `LiftContextSpec` remains the owner of target and inner
transport rendering.

#### Remaining Work

None.

### Sprint 15.4: Lima realization adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
`core/hostbootstrap-core/test/LimaSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`

#### Objective

Make the Lima lifecycle realization consume the lower Lima target and renderer.

#### Deliverables

- `HostBootstrap.Lima` reexports `LimaVM` and `shellVMArgs` from the lower Lift context.
- The module owns lifecycle builders only.
- Sizing, copy, stop, and delete builders retain the exact VM identity.
- The provider layer consumes these builders without a second dispatch fold.
- A source guard keeps generic Lift independent of the realization.

#### Validation

`LimaSpec` covers lifecycle shapes; native Apple Silicon confirmation belongs to the Apple Silicon
acceptance phase.

#### Remaining Work

None.

### Sprint 15.5: WSL2 realization adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

Make the WSL2 lifecycle realization consume the lower WSL2 target, renderer, and prerequisite helpers.

#### Deliverables

- `HostBootstrap.Wsl2` reexports `Wsl2VM` and `wslExecArgs` from the lower Lift context.
- The module owns distro and lifecycle builders only.
- Prerequisite compatibility exports delegate to `Ensure.Wsl2`.
- Wall, shutdown, distro, and lifecycle shapes preserve the exact selected target.
- Every exported lifecycle builder has a production consumer. The provider stops by releasing the global
  wall and then shutting down the shared WSL2 utility VM.
- A source guard keeps generic Lift independent of the realization.

#### Validation

`Wsl2Spec` covers lifecycle shapes, and `ProviderSpec`'s "stop and guarded delete are explicit" case
holds the wall-release-before-shutdown order. The Python packaging guard
`test_provider_surface_has_one_dispatch_and_no_definition_only_builders` requires a production consumer
for each named lifecycle builder and enforces the supported provider surface. Native Windows confirmation
belongs to the Windows and WSL2 acceptance phase.

#### Remaining Work

None.

### Sprint 15.6: Closed raw provider discovery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ConstructProviderProbeRequest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/architecture/durable_state.md`, `documents/engineering/incus.md`

#### Objective

Turn raw process results into provider discovery only through a closed provider-owned request plan.

#### Deliverables

- `ProviderProbeRequest` is abstract and has a read-only interpreter view; its constructor lives in the
  package-private `Provider.Internal`.
- A guest provider's plan is three closed requests in order: the provider's own listing, which answers daemon
  reachability and the caller's permission to use the daemon as one observation; `true` inside the guest (VM
  capability); and provisioning egress. Direct's plan is its canonical-root permission probe and provisioning
  egress.
- The injected interpreter returns only exit status, stdout, stderr, or transport failure.
- Total parsers in the provider module classify a zero exit as Ready without reading stdout; a non-zero exit whose output
  begins with "not ready", "starting", "connection refused", or "daemon is not running" as NotReady, and with
  "not found", "unsupported", or "no such file" as Unavailable; a transport failure whose text is exactly the
  one line `HB_PROVIDER_CONFLICT <expected> <observed> <reason>` over bounded tokens as Conflict; anything
  else as Failure.
- Only NotReady enters the module-owned bounded poll (60 attempts, one second apart).
- Guest discovery short-circuits in plan order. A probe that ran keeps its own observation; only the slots
  that never ran take the blocking observation.
- A bound route that does not name the selected provider's instance is refused as
  `ProviderOperationFailure` with `ProviderGuestRoute` before any probe runs.

#### Validation

ProviderSpec's "unit probe classifier preserves each readiness and availability prefix" applies the public
classifier to every declared NotReady/Unavailable prefix. "unit probes use exit status and retain
unclassified failure details" checks arbitrary successful streams and the exact non-zero failure.
"provider conflict markers require one bounded token line" checks the exact conflict and rejects a second
line, forbidden token character, 241-character token and extra fifth token, including their raw-failure
classification. The reflexive discovery equality case is removed.

ProviderBackendSpec's "discovery keeps all three successful guest observations" asserts the three Ready
slots and the exact ordered listing/guest/egress commands. "discovery retains a ready daemon when the guest
is unavailable" retains the daemon answer and blocks only VM/egress. "discovery stops after an unavailable
provider listing" records only that listing. "discovery retries only a not-ready guest probe" records
exactly two guest commands. "discovery never retries an unclassified guest failure" records exactly one
and retains its failure in the blocked suffix. "discovery refuses a different instance before any probe"
asserts ProviderOperationFailure/ProviderGuestRoute with an entirely empty client history.

Those cases reach discoverProvider through withRunningProvider and withProviderBoundExec, the production
protected store/interpreter and a real FakeProvider client process with durable raw fixture answers.
They are portable client-contract evidence, not a live Incus/KVM claim. CompileFailSpec's registered
ConstructProviderProbeRequest.hs rejects construction through the public import. The sealed export
inventory pins the two descriptive classifiers. All new cases and the documentation/export guards pass
in the identical 141-case Windows and Linux selections.

| Build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core main | 2026-11-03T22:55:28.823594+00:00 to 2026-11-03T22:55:43.410972+00:00 | 14.587462 | PASS; parent 0 |
| Native Windows demo main | 2026-11-03T22:55:28.835253+00:00 to 2026-11-03T22:55:48.744753+00:00 | 19.909603 | PASS; parent 0 |
| Native Windows core test | 2026-11-03T22:56:58.260604+00:00 to 2026-11-03T22:57:09.215516+00:00 | 10.954968 | PASS; parent 0 |
| Native Windows demo test | 2026-11-03T22:55:59.631549+00:00 to 2026-11-03T22:56:13.366147+00:00 | 13.734676 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T22:56:58.271703+00:00 to 2026-11-03T22:57:11.305555+00:00 | 13.033907 | PASS; parent 0 |
| Native Windows provider/discovery/alias/public boundary selection | 2026-11-03T22:57:47.838046+00:00 to 2026-11-03T22:58:17.428064+00:00 | 29.590160 | 141 cases pass; parent 0 |
| Linux provider/discovery/alias/public boundary selection | 2026-11-03T22:57:47.522914+00:00 to 2026-11-03T22:58:02.275227+00:00 | 14.752377 | 141 cases pass; parent 0 |
| Native Windows complete demo | 2026-11-03T22:57:47.653804+00:00 to 2026-11-03T22:57:52.821761+00:00 | 5.167959 | 167 cases pass; parent 0 |

Final native main/test build stderr is empty and both native test binaries use rts_thr. The initial
test compile found colliding ProbeFailure/Reconcile record selectors; importing only the ProbeFailure
constructor resolved it without production changes. Native demo stderr contains expected negative-fixture
output. No case is newly skipped.

The final source audit at 2026-11-03T22:57:57.579725+00:00 to
2026-11-03T22:57:57.646510+00:00 measures 132/133 nonempty/physical changed production lines across
three modules, 200/210 test lines across five existing files and one new compiler fixture, and 35/36
canonical-document lines. Complete reversals match the captured baseline. Preservation at
2026-11-03T22:57:39.789587+00:00 confirms all 982 other Haskell files, all 695 prior compiler fixtures
and 1,103 other snapshot subjects unchanged. Provider operations from classifyRawFailure onward are
exact; Provider.Internal changes only its DirectProbe comment and Provider/Alias removes only the
collapsed permission requirement. The provider backend, ownership primitives, Cabal/Python/demo source
and base/warm inputs are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T22:58:17.174577+00:00 to 2026-11-03T23:05:02.829251+00:00 | 405.656887 | 4222 cases pass, 366.71 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T22:58:17.185069+00:00 to 2026-11-03T23:05:28.543496+00:00 | 431.360785 | 167 cases pass, 1.85 reported seconds; 4222 cases pass, 381.44 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T22:58:17.223139+00:00 to 2026-11-03T22:58:18.159670+00:00 | 0.936511 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T22:58:17.201731+00:00 to 2026-11-03T22:58:24.545029+00:00 | 7.343318 | 376 pass, 6.11 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,117-file matched Windows/Linux tree. Dated aggregate digests:

- all991: b14c108d1e4d77b6157c2ad628d32ac74b3ac97799bc57d3a4484eeb757e0f1f
- owned966: b27eebb233b863a7ec478a383aa95a5204aac5cab2bdb4de8bdde5058d7aa837
- docs95: bc2d778b47a20fe8e764ae2623a9f910c520087ea83e3ac2f905290df3ec9756

The final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T23:05:48.433932+00:00 to 2026-11-03T23:05:55.409862+00:00,
6.975953 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.7: Managed provider capability [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveAliasFixture.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`, `documents/engineering/incus.md`

#### Objective

Retain the exact managed provider generation and discovered facts in one generative capability.

#### Deliverables

- `ProviderCapability` is minted only by `discoverProvider`, from a matching managed Running provider and its
  `ProviderBoundExec`.
- The capability retains the managed handle, the selected provider, and the complete discovery report; its
  accessors expose provider kind, discovery report, generation, and lift context.
- The capability carries no guest executor. Guest work reaches a provider frame only through the narrower
  strong alias backend, which takes the capability's lift context.
- Scope, plan, provider, backend, and capability indices are nominal, and the capability index is rank-2
  scoped. The generation is a runtime `Word64` read from the managed handle and compared where it is used.

#### Validation

ProviderBackendSpec's "discovery keeps all three successful guest observations" now enters the actual
discovery continuation and asserts ProviderIncus, the running handle's managed generation, retained lift
context and exact three-observation guest report. "Direct capability retains its managed generation and
complete discovery" establishes a real admissible Direct root, readies its managed handle, enters bound
discovery, and asserts ProviderDirectHost, the managed generation, local lift context and both exact Ready
observations. Its real recording egress client receives exactly the readiness and discovery commands.

ProviderSpec's "provider capabilities expose no independent guest executor" scans every production source
under src/ and rejects ProviderGuestExecutor, bindProviderGuestExecutor, runProviderGuestExecutor and
providerCapabilityGuestExecutor. The sealed export inventory reflects the reduced surface.
ForgeProviderCapability.hs, CoerceProviderCapabilityIdentity.hs, EscapeProviderCapabilityIdentity.hs and
CrossPlanBudgetProviderCapability.hs retain their independent forgery/coercion/escape/substitution
diagnostics. All these cases, provider/alias regressions and documentation/export guards pass in the same
147-case selection on native Windows and Linux.

The provider-live component compiles on both hosts. Its Direct route retains the strong-alias Unsupported
check and stop refusal; only the redundant unused executor check is removed. No live VM run is claimed.

| Build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core main | 2026-11-03T23:06:39.482099+00:00 to 2026-11-03T23:06:58.543770+00:00 | 19.061774 | PASS; parent 0 |
| Native Windows demo main | 2026-11-03T23:06:39.486733+00:00 to 2026-11-03T23:07:05.224587+00:00 | 25.737992 | PASS; parent 0 |
| Native Windows core test | 2026-11-03T23:08:31.633833+00:00 to 2026-11-03T23:08:45.844751+00:00 | 14.210990 | PASS; parent 0 |
| Native Windows demo test | 2026-11-03T23:07:39.703707+00:00 to 2026-11-03T23:07:50.996782+00:00 | 11.293131 | PASS; parent 0 |
| Native Windows provider-live component build | 2026-11-03T23:09:13.718503+00:00 to 2026-11-03T23:09:21.407195+00:00 | 7.688738 | PASS; parent 0 |
| Linux complete build including both test components | 2026-11-03T23:08:31.638776+00:00 to 2026-11-03T23:08:46.421351+00:00 | 14.782636 | PASS; parent 0 |
| Native Windows provider/capability/alias/compiler/public boundary selection | 2026-11-03T23:09:27.526318+00:00 to 2026-11-03T23:10:06.137053+00:00 | 38.610923 | 147 cases pass; parent 0 |
| Linux provider/capability/alias/compiler/public boundary selection | 2026-11-03T23:09:13.716507+00:00 to 2026-11-03T23:09:37.140663+00:00 | 23.424264 | 147 cases pass; parent 0 |
| Native Windows complete demo | 2026-11-03T23:09:13.889401+00:00 to 2026-11-03T23:09:19.090595+00:00 | 5.201201 | 167 cases pass; parent 0 |

Final native main/test/live build stderr is empty and both native core/demo test binaries use rts_thr.
An initial test compile caught a missing DirectProviderDiscovery import; that fixture import was added
before the successful builds. Native demo stderr contains expected negative-fixture output. No case is
newly skipped.

The final source audit at 2026-11-03T23:09:37.328959+00:00 to
2026-11-03T23:09:37.344984+00:00 measures 77/84 nonempty/physical changed production lines across
two library modules and the live fixture, 42/42 test lines across three files, and 11/13 canonical-document
lines. Complete reversals match the captured baseline. Preservation at
2026-11-03T23:10:13.444927+00:00 confirms all 985 other Haskell files, all 696 compiler fixtures and
1,107 other snapshot subjects unchanged. Discovery, all provider operation planners and the bound
executor are exact. The live fixture differs only by the unused guest check/import removal. The backend,
ownership primitives, Cabal/Python/demo source and base/warm inputs are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T23:10:24.306436+00:00 to 2026-11-03T23:18:31.869983+00:00 | 487.566210 | 4224 cases pass, 441.91 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T23:10:24.307283+00:00 to 2026-11-03T23:18:32.636370+00:00 | 488.331751 | 167 cases pass, 2.26 reported seconds; 4224 cases pass, 435.38 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T23:10:24.265086+00:00 to 2026-11-03T23:10:25.167130+00:00 | 0.902028 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T23:10:24.277591+00:00 to 2026-11-03T23:10:32.198618+00:00 | 7.921046 | 376 pass, 6.73 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,117-file matched Windows/Linux tree. Dated aggregate digests:

- all991: 3b7705521ba91f630686425c905539f5c0527a7e893bbf3cff82c90ce2fd4cef
- owned966: 7e8c87c9e97f2db4c7da69fb27bc74372d2180831175c580584bd1c9529ef18f
- docs95: cb8400d6f056b6a6dbf1a69e5bf2e4774736713b63aec8456c634735b2be93a9

Final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T23:19:16.399109+00:00 to 2026-11-03T23:19:26.902545+00:00,
10.503458 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.8: Validated backend description [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Admit only complete, bounded Incus and Direct backend descriptions.

#### Deliverables

- `ProviderBackendSpec` is abstract; its total Incus constructor retains the instance name, image,
  destructive-delete guard prefix, resolved `incus` executable, absolute state directory, and CPU, memory,
  and storage sizing.
- Direct retains an absolute local root, the resolved `docker` executable, and the egress image.
- Backend execution receives an opaque request with a read-only process view.
- Invalid substrate, unresolved tool, unbounded value, and ambiguous path inputs fail closed.
- Admission bounds the Incus instance name by what the provider's per-device control-socket pathname
  admits, counted in UTF-8 bytes as the `sun_path` budget is, so a declaration whose share device could not
  attach is refused before discovery.
- The Incus instance name and the guard prefix obey the ASCII hostname grammar Incus enforces: `[a-z0-9-]`,
  no leading digit or hyphen, and no trailing hyphen on the name. Memory and storage are ASCII digits with an optional Incus
  unit suffix within the signed 64-bit byte range.
- The executable folded into the realization fingerprint is the one every provider call runs: runtime
  resolves the tool from the stored spec, or refuses a host configuration whose resolved tool differs from it.
- A non-zero backend call folds its provider diagnostic into the bounded single-line token vocabulary
  rather than discarding it, so a refusal names the condition it observed.

#### Validation

ProviderBackendSpec's backendAdmissionCases contributes 39 separate cases. Each invalid declaration
asserts Failure, the exact operation/reason, and DoNotRetry: instance/prefix grammar, UTF-8 and ASCII
socket limits, empty/NUL images, relative/NUL state paths, zero CPUs, malformed/non-ASCII/empty/overflowing
memory and storage, and Direct root/egress guards. "Incus admits the exact socket byte budget and a
trailing-hyphen guard" checks the accepted boundaries; "Incus admits its documented byte suffixes and exact
integer ceiling" checks all supported suffixes, the signed byte ceiling and scaled values just below it.
The units and range follow the upstream Incus byte parser/reference linked in the engineering document.

The Incus, Direct, Lima and WSL2 "strong admission holds its retained executable" cases prove that
changing the client changes the realization fingerprint, a matching configuration admits without
probes, and missing or substituted clients refuse before a real provisioning continuation can run.
They assert no store metadata, client command or mutation. The canonical guest-VM rows supply their
client tools rather than a second realization vocabulary. Existing raw case/dot/underscore record
identity cases remain; the invalid public instance-address case now asserts the earlier hostname
Failure/DoNotRetry before any store or provider work.

Both host selections pass all 271 provider/admission/alias/cluster/settlement, export/documentation and
compiler-boundary cases. These are public-constructor and real client-contract checks; no live Incus
VM run is claimed. Strong admission checks an immutable configuration, so subsequent calls use the same
retained client path without adding a process probe or second interpreter.

| Build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core main | 2026-11-03T23:26:57.223121+00:00 to 2026-11-03T23:27:05.122679+00:00 | 7.899595 | PASS; parent 0 |
| Native Windows demo main | 2026-11-03T23:26:57.227982+00:00 to 2026-11-03T23:27:14.204732+00:00 | 16.976842 | PASS; parent 0 |
| Native Windows core test | 2026-11-03T23:27:47.104450+00:00 to 2026-11-03T23:28:00.243422+00:00 | 13.139039 | PASS; parent 0 |
| Native Windows demo test | 2026-11-03T23:28:36.654102+00:00 to 2026-11-03T23:28:56.858774+00:00 | 20.204775 | PASS; parent 0 |
| Native Windows provider-live component build | 2026-11-03T23:28:55.282458+00:00 to 2026-11-03T23:29:09.677077+00:00 | 14.394693 | PASS; parent 0 |
| Linux complete build including both test components | 2026-11-03T23:26:57.299688+00:00 to 2026-11-03T23:27:25.145649+00:00 | 27.846098 | PASS; parent 0 |
| Native Windows provider/capability/alias/compiler/public boundary selection | 2026-11-03T23:29:35.179637+00:00 to 2026-11-03T23:31:02.445054+00:00 | 87.265871 | 271 cases pass; parent 0 |
| Linux provider/capability/alias/compiler/public boundary selection | 2026-11-03T23:28:26.310442+00:00 to 2026-11-03T23:28:55.500135+00:00 | 29.189831 | 271 cases pass; parent 0 |
| Native Windows complete demo | 2026-11-03T23:29:19.657017+00:00 to 2026-11-03T23:29:24.879901+00:00 | 5.222873 | 167 cases pass; parent 0 |

Final native main/test/live build stderr is empty and both native core/demo test binaries use rts_thr.
The initial compile caught an isAlphaNum import removed while its existing conflict-token helper still
used it; the import was restored unchanged before the successful builds. Test-local resource names were
also made distinct from imported field selectors. Native demo stderr contains expected negative-fixture
output. No case is newly skipped.

The final source audit at 2026-11-03T23:29:45.064933+00:00 to
2026-11-03T23:29:45.076244+00:00 measures 73/76 nonempty/physical changed production lines in one
module, 163/167 test lines in one module and 30/30 Incus engineering lines. Complete reversals match the
captured baseline. Preservation at 2026-11-03T23:30:15.571603+00:00 confirms all 989 other Haskell files,
all 696 compiler fixtures and 1,112 other snapshot subjects exact. All provider call drivers and semantic/
realization fingerprint formats are unchanged; below providerBackendBinding only the socket-budget
Haddock changes. Canonical guest-VM rows and Direct construction are exact. Ownership/protected
primitives, observation and command protocols, Cabal/Python/demo source and base/warm inputs are
unchanged. The sprint's deliverables are consolidated to eight bullets. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T23:29:19.402359+00:00 to 2026-11-03T23:38:25.815233+00:00 | 546.415965 | 4267 cases pass, 477.22 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T23:29:19.402818+00:00 to 2026-11-03T23:38:02.270641+00:00 | 522.870775 | 167 cases pass, 3.84 reported seconds; 4267 cases pass, 490.39 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T23:29:19.402601+00:00 to 2026-11-03T23:29:21.093707+00:00 | 1.691085 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T23:29:19.402155+00:00 to 2026-11-03T23:29:29.153520+00:00 | 9.751378 | 376 pass, 7.65 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,117-file matched Windows/Linux tree. Dated aggregate digests:

- all991: 9dd0f44bb1108271d2aadf6edc50883647657af30f5b26069971d7e6c8e03cdd
- owned966: c4cea80faaeed192bf5d6faca05a727e1ad2b12b1aa60da55c27f46f147bc746
- docs95: 092d7ef658c07c6fefa708f658a00bcf95a6cc0f8531a4d3c00810166674e6b9

Final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T23:38:32.666734+00:00 to 2026-11-03T23:38:42.213934+00:00,
9.547234 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.9: Strong backend admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Mint a generative backend from a validated declaration, and leave the host to answer for the ownership
prerequisites when a transaction enters the protected store.

#### Deliverables

- `StrongProviderBackend backendId` is introduced only inside a rank-2 continuation.
- Admission is declaration-only: `discoverStrongProviderBackend` probes nothing and admits every validated
  `ProviderBackendSpec`. The state directory and clause 1 are the protected store's to establish when the
  first transaction enters it, through the clause-holding driver of Sprints 15.31 through 15.33.
- Stable semantic and per-realization fingerprints remain distinct and retained.
- One provider origin binds plan digest, resource key, generation, and semantic backend identity.
- Direct is a plan-local reservation and never a physical-host ownership claim.
- Forging and cross-backend use are statically rejected.

#### Validation

Compile-fail fixtures (`ForgeProviderBackendBinding.hs`, `CrossBackendProviderCall.hs`,
`CrossBackendProviderResult.hs`) cover backend identity. `ProviderBackendSpec`'s lifecycle family admits its
backends through `discoverStrongProviderBackend` and reaches the protected store through the first prepared
call, and its Lima fingerprint case pins the retained binding.

#### Remaining Work

None.

### Sprint 15.10: Prepared provider provision [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/ProviderCommandSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Make initial provider mutation reachable only through the exact prepared provision call.

#### Deliverables

- `PreparedProviderProvision` retains execution, backend, resource, operation, digest, attempt, and journal indices.
- Incus durably publishes an explicit-absence fresh-nonce origin before launch.
- The launched VM is bound to its stable provider UUID and owner nonce before settlement.
- A retry repairs the exact prepared/managed origin and never adopts a same-shaped foreign VM.
- Direct settles only the plan-local reservation.
- Settlement yields an opaque backend-indexed managed provider or descriptive foreign observation.

#### Validation

ProviderReconcileSpec's "a foreign provider remains descriptive and grants no wrapper" reads the final
settlement callback, asserting resource key, exact ForeignObservation identity/detail, and generation
9743538103680144570 for the canonical rendering 666f726569676e2d70726f7669646572 of the raw foreign-provider
fixture. The literal generation was independently calculated; no production hash helper is called by
the assertion. The callback still rejects the managed branch for this foreign result.

The original raw-text expectation was corrected because objectIdentityText reports identity bytes as
lowercase hexadecimal, the vocabulary's existing journal/report format. The initial strengthened test
failed on both hosts while looking for raw text; the final check asserts the entire canonical detail
and the generation derived from that same rendering. Production identity formatting is unchanged.

"a prepared provider creation returns its exact backend-indexed wrapper" labels the owner prefix as a
prepared-binding fact, while its key/generation/observation-version remain read from the managed wrapper.
"Direct admission owns only its plan-local journal reservation" likewise labels its prepared owner and
now returns the resource key from the settled managed handle. No opaque origin projection was added.

| Build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core test build | 2026-11-03T23:43:33.485928+00:00 to 2026-11-03T23:43:46.982184+00:00 | 13.496317 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T23:43:33.509692+00:00 to 2026-11-03T23:43:45.680036+00:00 | 12.170389 | PASS; parent 0 |
| Native Windows provider/settlement/command/documentation selection | 2026-11-03T23:44:21.199808+00:00 to 2026-11-03T23:45:54.027803+00:00 | 92.828512 | 132 cases pass; parent 0 |
| Linux provider/settlement/command/documentation selection | 2026-11-03T23:44:20.617403+00:00 to 2026-11-03T23:44:35.738045+00:00 | 15.120709 | 132 cases pass; parent 0 |

Final build and focused stderr is empty; the native test binary uses rts_thr. No case was added or
skipped. Both final 132-case selections include the three strengthened cases, existing provision/
readiness/share/stop/delete settlements, real-process concurrent provision/crash recovery, command
builders and documentation guards.

The final source audit at 2026-11-03T23:44:04.532384+00:00 to
2026-11-03T23:44:04.541180+00:00 measures zero production changes, 21/21 nonempty/physical test lines
in one module and 9/11 architecture-document lines. Complete reversals match the baseline. Preservation
at 2026-11-03T23:44:04.744216+00:00 confirms all 990 other Haskell files, all 696 compiler fixtures and
1,112 other snapshot subjects exact, including every production Haskell source. Cabal/Python/demo,
observation/command protocols, base/warm inputs and all public APIs are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T23:46:33.473311+00:00 to 2026-11-03T23:53:28.637432+00:00 | 415.166509 | 4267 cases pass, 372.60 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T23:46:33.473433+00:00 to 2026-11-03T23:52:41.069492+00:00 | 367.598173 | 167 cases pass, 1.91 reported seconds; 4267 cases pass, 353.26 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T23:46:33.473663+00:00 to 2026-11-03T23:46:38.096964+00:00 | 4.623311 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T23:46:37.559625+00:00 to 2026-11-03T23:46:45.243729+00:00 | 7.684120 | 376 pass, 6.53 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,117-file matched Windows/Linux tree. Dated aggregate digests:

- all991: 98ec162fc75282952b04c21628007759f08fc0c7789c762d0cbe639306b4b068
- owned966: 6b3745bca61b0c7427fe0a3cddf4c3248e59d2c1052b0737dd93b2a49701278b
- docs95: c20e1d94a3da60cf4bc3de51a7ec8084a6c7c131a5d32e0aa4a5f7b46b8c89ed

Final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T23:55:25.015105+00:00 to 2026-11-03T23:55:34.631921+00:00,
9.616846 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.11: Prepared provider readiness [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Advance only the exact provisioned or stopped provider to Running after fresh identity-bound readiness.

#### Deliverables

- `ProviderStartable` has producers only for Provisioned and Stopped managed providers.
- `PreparedProviderReady` retains the matching start transition and backend origin.
- Incus starts only an exact owned STOPPED VM and polls guest readiness with a bounded policy.
- An unexpected provider state is Conflict and is left untouched.
- Direct validates its canonical root permissions and egress before advancing.
- Settlement returns only the same backend-indexed Running provider, and the advance retains the source
  phase it left, so carrying its settlement names the predecessor the transition really had: a boot carries
  from Provisioned, a restart from Stopped, and only a Provisioned-origin advance can be carried as a
  provider created in the same step.
#### Validation

ProviderPhaseAdvance retains nominal source and target indices. Its private Running constructor carries
the exact validated ProviderStartable retained by PreparedProviderReady, deriving the carry predecessor
as provisioned or stopped. Stop and delete advances retain Running/Stopped and Stopped/Destroyed
respectively. Backend runtime-package registration ties the Running advance's source to the prepared
ready value. No extra authority projection or caller-selected phase text was introduced.

CarryCreatedRestartedProvider.hs admits a Provisioned-origin positive control and rejects its
Stopped-origin counterpart with the independently matched Stopped/Provisioned diagnostic.
CoerceProviderPhaseAdvanceRoles.hs independently checks scope, plan, backend, provider, source and target
indices. ForgeProviderPhaseAdvance.hs, CrossPreparedProviderResult.hs, CrossBackendProviderResult.hs and
ProvisionedProviderClusterDependency.hs retain their exact forgery/substitution/wrong-phase refusals.
ProviderBackendSpec uses the derived-predecessor carry in its runtime-package case. Both existing demo
created-provider calls compile against the restricted Provisioned-origin API without textual changes.

| Build or selection, 2026-11-04/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core main | 2026-11-04T00:18:19.632804+00:00 to 2026-11-04T00:18:39.328689+00:00 | 19.695999 | PASS; parent 0 |
| Native Windows demo main | 2026-11-04T00:18:19.641203+00:00 to 2026-11-04T00:18:41.163371+00:00 | 21.522293 | PASS; parent 0 |
| Native Windows core test | 2026-11-04T00:19:02.207251+00:00 to 2026-11-04T00:19:20.893489+00:00 | 18.686344 | PASS; parent 0 |
| Native Windows demo test | 2026-11-04T00:19:02.221589+00:00 to 2026-11-04T00:19:14.489848+00:00 | 12.268328 | PASS; parent 0 |
| Native Windows provider-live component | 2026-11-04T00:20:06.813305+00:00 to 2026-11-04T00:20:11.553358+00:00 | 4.740079 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-04T00:18:19.708296+00:00 to 2026-11-04T00:19:12.573815+00:00 | 52.865802 | PASS; parent 0 |
| Native Windows provider/source-phase/compiler/documentation selection | 2026-11-04T00:27:47.912331+00:00 to 2026-11-04T00:28:18.404629+00:00 | 30.492457 | 139 cases pass; parent 0 |
| Linux provider/source-phase/compiler/documentation selection | 2026-11-04T00:27:47.714034+00:00 to 2026-11-04T00:28:03.748332+00:00 | 16.034371 | 139 cases pass; parent 0 |
| Native Windows complete demo | 2026-11-04T00:20:06.936895+00:00 to 2026-11-04T00:20:12.087290+00:00 | 5.150391 | 167 cases pass; parent 0 |

The first complete core and demo runs each failed only the existing first-party import-probe guard:
the new fixture used an unrestricted qualified Execution import. Its explicit StepExecution import
now passes that guard, the new type rejection, and the complete rerun. The final focused selection
includes the guard and passes 139 cases on each host.

Native build/focused stderr is empty; both native test binaries use rts_thr. The Linux build emits only
the existing package-index age warning; the Linux focused run has empty stderr. Native demo stderr is
expected negative-fixture output. The new compiler case increases the full core total by one; no case
is newly skipped. Provider transitions, runtime packages and the six compiler fixtures pass on both hosts.

The final source audit at 2026-11-04T00:27:31.700721+00:00 to 2026-11-04T00:27:31.766865+00:00 measures
87/87 nonempty/physical changed production lines across two modules, 62/65 test lines across nine files,
and 6/7 readiness-document lines. Complete reversals match the captured baseline. Preservation at
2026-11-04T00:27:47.791519+00:00 confirms all 981 other Haskell files, 691 unchanged compiler fixtures and
1,104 other snapshot subjects byte exact. Cabal/Python/demo source, command/observation protocols,
base/warm inputs and ownership primitives are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-04T00:28:27.514317+00:00 to 2026-11-04T00:34:07.650311+00:00 | 340.137972 | 4268 cases pass, 323.98 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-04T00:28:27.514082+00:00 to 2026-11-04T00:34:01.826886+00:00 | 334.314746 | 167 cases pass, 1.42 reported seconds; 4268 cases pass, 324.17 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-04T00:28:27.514200+00:00 to 2026-11-04T00:28:28.322385+00:00 | 0.808171 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-04T00:28:27.515958+00:00 to 2026-11-04T00:28:34.331033+00:00 | 6.815092 | 376 pass, 5.75 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,118-file matched Windows/Linux tree. Dated aggregate digests:

- all992: a57be11bf67a83b9a5588a2deaa0dcad05fccecd6487fe58da6cdef6cc7b3f60
- owned967: f0f721bf4d9fce8b0342d3211d7a1099c3a8028e02b4b1c15db2fd635775efad
- docs95: 345cf6b278289384ac3345d13ead862bc305660cd00c4371e75e4422a698ab4e

Final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T00:34:21.898574+00:00 to 2026-11-04T00:34:28.884701+00:00,
6.986151 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.12: Prepared durable share [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`, `documents/engineering/testing.md`

#### Objective

Attach one declared durable share through the exact Running provider authority.

#### Deliverables

- `ProviderShareSpec` validates an absolute host path in the host's grammar and an absolute POSIX guest path.
- `PreparedProviderShare` seals the exact provider dependency and fresh probe, and preparation refuses a
  provider the share node's plan descriptor does not declare among its dependencies.
- The share device is named `hb-share-` plus 12 hex digits of its binding digest, inside the bound its
  provider control-socket pathname admits.
- Incus holds the share as an owned object of its own: its origin is a protected-store record under its own
  key, recorded before the device is attached, and its identity is bound from the device the provider
  reports.
- The restart that activates an Incus share polls the exact owned guest under the canonical bounded VM-boot
  policy before the share is bound or any dependent guest mutation can begin.
- Direct admits only the already-local canonical root identity projection.
- Share settlement returns an opaque provider-indexed managed share or descriptive foreign observation.
- A crash between the record, the attachment, and the binding resumes from the durable record without
  adopting a device it did not record; the record's own write windows are the protected store's (Sprint 15.36).

#### Validation

The exact provider key must belong to the share operation descriptor's dependency set before any
dependency probe or prepared continuation. The share-observation Haddock belongs to its actual
datatype; the bounded device-name documentation describes collision refusal through the owned
transaction's exact device readback.

CompileFailSpec's "a share without its provider dependency refuses before probing" compiles and runs a
temporary executable against the actual ProviderReconcileSpec helper and production library. Its valid
descriptor probes and prepares exactly once. An otherwise retained descriptor with an empty dependency
set returns the entire ConflictDetail on core:deploy-vm and runs neither probe nor continuation.
Only this temporary executable selects Lifecycle.Execution.Internal for its private descriptor producer,
using the existing scoped compiler mechanism; normal test mixins, public exports, Cabal and -Werror are
unchanged. Its five declared home modules are explicit compiler inputs. The first compile rejected
missing home inputs; listing them explicitly fixed the probe without weakening warnings.

The normal ImportExecutionInternalFromHandoffTest.hs refusal passes separately in the same two-case
selection. ForgeStepExecution.hs, ForgePlanExecutionPackage.hs and
AssembleStepExecutionWithPublicRuntime.hs also retain their ordinary construction refusals. The runtime
case proves the production membership guard directly; those static refusals do not stand in for it.

ProviderBackendSpec's two real Incus/Direct refusal cases obtain the backend reprobe through
registerRunningProviderDependencyPackage and withFreshRunningProviderHandle. After successful Ready and
initial service observation, the Incus daemon refuses its exact listing; the Direct client's third real
egress invocation exits 1. Both assert the complete public-service Failure, exact retained backend
diagnostic and retry policy, and forbid the prepared-share continuation. Incus also asserts exactly one
listing, zero device-add mutations and unchanged empty devices. Existing share/lifecycle fixtures use
the same production service. Earlier fixture compile issues and raw-versus-wrapped failure expectations
were corrected before the final passing selections.

| Final build or selection, GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core test build | 2026-11-04T02:30:51.907734+00:00 to 2026-11-04T02:31:57.229699+00:00 | 65.322356 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-04T02:30:51.927563+00:00 to 2026-11-04T02:31:48.126908+00:00 | 56.199661 | PASS; parent 0 |
| Native Windows runtime descriptor/default-import controls | 2026-11-04T02:32:30.618304+00:00 to 2026-11-04T02:32:39.622848+00:00 | 9.004575 | 2 cases pass; parent 0 |
| Linux runtime descriptor/default-import controls | 2026-11-04T02:32:30.414242+00:00 to 2026-11-04T02:32:39.669148+00:00 | 9.254926 | 2 cases pass; parent 0 |
| Native Windows provider/share/alias/cluster/compiler/documentation selection | 2026-11-04T02:35:36.986095+00:00 to 2026-11-04T02:36:39.507037+00:00 | 62.521292 | 176 cases pass; parent 0 |
| Linux provider/share/alias/cluster/compiler/documentation selection | 2026-11-04T02:35:36.755905+00:00 to 2026-11-04T02:36:06.082165+00:00 | 29.326415 | 176 cases pass; parent 0 |

Final build and focused stderr is empty; the native test binary uses rts_thr. The runtime case adds one
core test beyond the two backend refusal cases; no case is newly skipped. Native main/demo/live builds
also passed for the unchanged production implementation, and the final demo workspace gate below
validates its consumer against the completed tree.

The production implementation audit at 2026-11-04T00:46:01.713754+00:00 to 2026-11-04T00:46:01.745317+00:00
measures 77/80 nonempty/physical changed lines across three modules, 136/139 backend-test lines and
6/6 architecture-document lines. All three current production hashes match that audit. The runtime
proof audit at 2026-11-04T02:34:39.467149+00:00 to 2026-11-04T02:34:39.528578+00:00 adds zero production changes,
140/144 test lines across two files and 6/7 testing-document lines. Complete reversals match their
captured baselines. Preservation at 2026-11-04T02:39:16.249909+00:00 proves every production source,
990 other Haskell files, all 697 compiler fixtures and 1,113 other snapshot subjects exact across the
runtime-proof addition. The closed stop-replacement assertion is separately byte exact. Command and
observation protocols, public exports, Python/demo/Cabal and base/warm inputs are unchanged. LF/diff
checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-04T02:37:45.287328+00:00 to 2026-11-04T02:45:10.651523+00:00 | 445.366889 | 4271 cases pass, 396.52 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-04T02:37:45.287485+00:00 to 2026-11-04T02:45:16.875215+00:00 | 451.590463 | 167 cases pass, 2.25 reported seconds; 4271 cases pass, 392.42 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-04T02:37:45.287163+00:00 to 2026-11-04T02:37:46.345164+00:00 | 1.057987 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-04T02:37:45.287580+00:00 to 2026-11-04T02:37:53.947146+00:00 | 8.659602 | 376 pass, 7.34 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,118-file matched Windows/Linux tree. Dated aggregate digests:

- all992: 4b63060f1b2e88efdd3f13cff4022636f30f105b24ceafc77275af73d1ab37e6
- owned967: 3d03805c3fb03d8d71c235227096c0a20d15898cecee2f7c25259cd8f7994e47
- docs95: 7789a1682079b54a6c11f17e02f532b812a37a8373ea48bb7546c17efaa2d452

Final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T02:45:42.186066+00:00 to 2026-11-04T02:45:50.264458+00:00,
8.078417 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.13: Prepared provider stop [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Stop only the exact managed Running provider generation.

#### Deliverables

- `PreparedProviderStop` accepts only a managed Running provider.
- Incus revalidates the durable origin, UUID, and nonce before and after stop.
- Incus forces the provider stop, so an unresponsive guest agent cannot hold the prepared transaction
  indefinitely.
- Already-stopped success remains bound to the same exact identity.
- A still-running result retains retryable typed failure rather than advancing phase.
- A replacement is Conflict and remains untouched.
- Direct returns `Unsupported` and produces no Stopped authority.

#### Validation

"a replacement cannot settle a prepared stop" now asserts the entire ConflictDetail:
core:deploy-vm, owned generation 17, replacement generation 17435237075782472532, the exact canonical
identity 7265706c6163656d656e742d766d, and "stop provider must leave the replacement untouched and require
operator resolution". An unrelated Conflict cannot satisfy it.

The raw replacement-vm identity is rendered in lowercase hexadecimal by the existing objectIdentityText
vocabulary. The criterion names that actual canonical rendering. An independent calculation over its
bytes produced the literal replacement generation and checked foreign-provider's known generation as a
control; no production helper computes expected assertion values. Initial 134-case selections on both
hosts matched the identity/generation fields but caught an expected remedy using reconcile provider stop
instead of stop provider. The literal was corrected before the successful final selections.

| Build or selection, 2026-11-04/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native Windows core test build | 2026-11-04T02:16:53.270741+00:00 to 2026-11-04T02:17:01.864254+00:00 | 8.593560 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-04T02:16:53.289172+00:00 to 2026-11-04T02:17:00.766383+00:00 | 7.477236 | PASS; parent 0 |
| Native Windows provider/stop/command/documentation selection | 2026-11-04T02:17:07.029687+00:00 to 2026-11-04T02:17:39.237176+00:00 | 32.207664 | 134 cases pass; parent 0 |
| Linux provider/stop/command/documentation selection | 2026-11-04T02:17:06.806814+00:00 to 2026-11-04T02:17:21.500554+00:00 | 14.693809 | 134 cases pass; parent 0 |

Final build/focused stderr is empty and the native test binary uses rts_thr. The existing replacement,
stop/idempotence/retry/Direct/malformed-report and real-client cases pass; no case is added or skipped.

The source audit at 2026-11-04T02:16:45.047062+00:00 to 2026-11-04T02:16:45.061073+00:00 measures zero production changes,
8/8 nonempty/physical test lines in one module, and 5/5 engineering-document lines. Complete reversals
match the baseline. Preservation at 2026-11-04T02:17:06.889516+00:00 confirms all 991 other Haskell files,
all 697 compiler fixtures and 1,114 other snapshot subjects exact, including every production source.
Public APIs, identity formatting, command/observation protocols, Python/demo/Cabal and base/warm inputs
are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-04T02:17:48.684195+00:00 to 2026-11-04T02:23:26.628857+00:00 | 337.946671 | 4270 cases pass, 307.03 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-04T02:17:48.683976+00:00 to 2026-11-04T02:22:57.947963+00:00 | 309.265827 | 167 cases pass, 1.46 reported seconds; 4270 cases pass, 300.50 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-04T02:17:48.683885+00:00 to 2026-11-04T02:17:49.475206+00:00 | 0.791307 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-04T02:17:48.687951+00:00 to 2026-11-04T02:17:55.939211+00:00 | 7.251286 | 376 pass, 6.23 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,118-file matched Windows/Linux tree. Dated aggregate digests:

- all992: 4b3906c86dca66ee182d28ae1b4ec8a52f471099a3d6440074f17577e0a4ff76
- owned967: 6f51a7d5f503f80cc1560104b33adca1303dd1a6c54d58405352111583bd4b81
- docs95: 5e9bc74815400fed6be2b23e4b3376093ca88684f09372eca12c0dee12c47108

Final native live Incus confirmation remains owned by Sprint 15.50.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T02:25:11.120884+00:00 to 2026-11-04T02:25:21.351028+00:00,
10.230184 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 15.14: Prepared provider delete [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/engineering/incus.md`

#### Objective

Conditionally delete only an exact stopped provider and its exact durable ownership records.

#### Deliverables

- `PreparedProviderDelete` accepts only the matching managed Stopped provider.
- Incus re-enters from the durable instance record, re-observes the instance's reported identity and stopped
  state, and deletes through the frame table's guarded delete.
- The instance record and its share records are forgotten only over a reported absence of the instance, so
  the object goes first and the records second.
- Missing, replaced, or reappearing state is preserved as Conflict or retryable Failure; a same-named
  replacement is left standing and forgets no record.
- Direct returns `Unsupported` and produces no Destroyed authority.

#### Validation

`ProviderBackendSpec` covers conditional delete in its full lifecycle case, the retained reverse that deletes
and retires the provider record, an exact restarted VM before delete as retryable, a replacement between
transactions, and a same-named replacement left standing. `ProviderReconcileSpec`'s Direct stop refusal mints
no Stopped authority, so no Direct delete is reachable. The record write, flush, and unlink windows are the
protected store's contract, inherited through the source guard of Sprint 15.36.

#### Remaining Work

None. Resuming a delete interrupted after the instance is gone, and releasing a record whose instance was
created but never bound, are the clause-holding delete driver's and are owed in Sprint 15.33.

### Sprint 15.15: Provider-bound execution [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/testing.md`

#### Objective

Derive discovery and guest execution only from one exact strong backend and managed Running provider.

#### Deliverables

- `ProviderBoundExec` is abstract and indexed by scope, plan, provider, phase, and backend.
- Its sole producer validates the retained origin, receipt, generation, semantic fingerprint, and realization.
- Closed provider requests lower to the exact retained route and resolved tools.
- Guest execution revalidates Incus UUID and nonce before and after the guest command.
- Provider conflict and replacement remain structured across the raw transport boundary.
- Direct exposes no guest route.

#### Validation

The existing Incus discovery case already obtains ProviderBoundExec through withProviderBoundExec
for its real managed Running provider, runs the bound request, and checks exact daemon/guest/egress
vectors, retained kind, generation, lift context, and guest invocations. It remains part of the
provider regression selection; no duplicate happy-path case was added.

Three new runtime controls construct ManagedProviderHandle with the private observation constructor
while retaining the real public-route handle and receipt. Resource-key and generation cases change
only that origin coordinate. The realization case uses binding coordinates from a second admitted
backend: its semantic fingerprint is equal and its actual resolved client realization differs.
Every case asserts the complete ConflictDetail, zero provider commands and zero continuations.
The temporary producer compiles in the actual Main unit with the current declared home interfaces
only, byte-checks the copies, compiles its seven test helpers in that same unit, and links against
the actual production library. Ordinary module visibility, public exports, Cabal and -Werror remain
unchanged. Each compiler child has a separate temporary environment.

The first native build correctly rejected private fingerprint projections in the ordinary helper;
those projections moved into the private producer. The final native test build and Linux all/test
build both pass. All 990 other Haskell files and all 697 compile-fail fixtures are byte-preserved
against the sprint baseline. Production delta is zero; the two test-module diffs add 46 and 173
physical lines while removing 1 and 5 respectively. The lifecycle, core-library and testing guides
describe the retained authority and scoped controls.

Windows origin controls: 2026-11-04T03:19:36.134487+00:00 to 2026-11-04T03:19:48.763444+00:00; 12.629015 wall seconds; all 3 cases pass, exit 0/empty stderr, frozen source exact.

Linux origin controls: 2026-11-04T03:20:05.425035+00:00 to 2026-11-04T03:20:17.225505+00:00; 11.800522 wall seconds; all 3 cases pass, exit 0/empty stderr, frozen source exact.

Windows provider regression: 2026-11-04T03:20:05.638355+00:00 to 2026-11-04T03:21:11.693017+00:00; 66.055047 wall seconds; all 179 cases pass, exit 0/empty stderr, frozen source exact.

Linux provider regression: 2026-11-04T03:20:36.878610+00:00 to 2026-11-04T03:21:12.608756+00:00; 35.730345 wall seconds; all 179 cases pass, exit 0/empty stderr, frozen source exact.

All four host-static commands pass on the exact synchronized Linux CPU source tree (GHC 9.12.4,
Cabal 3.16.1.0); these are ordinary static runs, not the final live Incus/KVM confirmation:

- core: `cabal test all`, 2026-11-04T03:21:28.573499+00:00 to 2026-11-04T03:27:33.263375+00:00; 364.692081 wall seconds; 4274 cases/331.82 reported seconds; exit 0, frozen source exact.
- demo: `cabal test all`, 2026-11-04T03:21:28.574259+00:00 to 2026-11-04T03:27:14.990576+00:00; 346.418414 wall seconds; 167 cases/1.69 reported seconds, 4274 cases/330.42 reported seconds; exit 0, frozen source exact.
- check_code: `poetry run python -m hostbootstrap.check_code`, 2026-11-04T03:21:28.574141+00:00 to 2026-11-04T03:21:29.830536+00:00; 1.256384 wall seconds; ruff, black and mypy pass; exit 0, frozen source exact.
- test_all: `poetry run python -m hostbootstrap.test_all`, 2026-11-04T03:21:28.574380+00:00 to 2026-11-04T03:21:36.324474+00:00; 7.750125 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, frozen source exact.

The synchronized audit matched all 992 Haskell files, 967 core-owned Haskell files and 95 governed
Markdown documents, across 1118 checked source/build/document subjects. The final live phase gate
remains owned by Sprint 15.50 after all lower implementation work.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T03:28:02.281446+00:00 to 2026-11-04T03:28:08.981451+00:00,
6.700031 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 15.16: Prepared guest-alias call [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`, `documents/engineering/testing.md`

#### Objective

Seal provider, share, alias, operation, and gate identity into one prepared guest-alias call.

#### Deliverables

- `GuestAliasSpec` accepts one canonical absolute POSIX alias and target declaration whose alias is neither the
  target, a segment-wise ancestor of it (a link there could never be created), nor a path inside
  `<target>/.hostbootstrap-alias-authority-v1`.
- `PreparedGuestAliasCall` retains matching provider, backend, capability, share, alias, and operation indices.
- The managed share retains the exact provider origin that authorized it.
- Preparation refuses, as `Conflict` and before sealing, a strong alias backend minted from another provider
  generation, a share derived from another provider origin, and a provider origin from another plan digest.
- Preparation seals the exact share dependency and runs its fresh probe.
- Indexed call results cannot settle another call.
- Settlement exposes an opaque managed alias or descriptive foreign observation.

#### Validation

The descriptor now compares path segments. It refuses an alias that is an ancestor of its target
and one at or beneath the target's alias authority directory, including a root target. Seven added
descriptor cases cover NUL in either coordinate, the ancestor, authority directory, authority child,
root authority, and an admitted shared character prefix. Every rejected case asserts the complete
FailureDetail with the exact guard reason and DoNotRetry. The existing admitted case uses unrelated
paths, so it no longer accepts an alias above its own target.

Four public-route cases use the actual ProviderBackendSpec FakeProvider lifecycle and its declared
guest-alias projection. Successful preparation probes once and enters once; a failing fresh share
probe returns that complete Failure unchanged and enters no continuation. The generation and
share-origin cases stop/delete provider generation 17 and publicly provision/readiness generation
18, retaining respectively the prior strong alias backend or managed share. They assert the entire
ConflictDetail and zero probes, continuations and provider commands after setup.

The fifth preparation case compiles a temporary producer against the actual Main and plan-resource
units. It changes only the planned alias digest after obtaining its observed handle, and asserts
the complete plan ConflictDetail before any probe, continuation or provider command. Its own
FakeProvider subprocess dispatch uses the normal backend fixture handler. Ordinary test mixins,
public exports, Cabal and -Werror remain unchanged; the hidden-import refusal is still independent.
The three earlier bound-origin controls remain passing with that producer.

The first build caught a local helper's generative capability mismatch; the final helper carries
each index in its polymorphic signature. A later focused run caught an incorrect locale-encoding
import in the temporary producer; it now uses the main suite's GHC.IO.Encoding import. Both final
native and Linux builds pass. Production delta is seven added lines in Alias.hs alone, within the
sprint bound. All other 988 Haskell files and all 697 compile-fail fixtures are byte-preserved against
the sprint baseline; LF and the scoped diff checks pass. The lifecycle and testing guides describe
the checks and runtime controls.

Windows alias preparation/descriptor controls: 2026-11-04T03:35:32.916790+00:00 to 2026-11-04T03:36:33.758654+00:00; 60.842216 wall seconds; all 27 cases pass, exit 0/empty stderr, frozen source exact.

Linux alias preparation/descriptor controls: 2026-11-04T03:36:30.184056+00:00 to 2026-11-04T03:36:59.380676+00:00; 29.196779 wall seconds; all 27 cases pass, exit 0/empty stderr, frozen source exact.

Windows provider/compiler regression: 2026-11-04T03:37:01.946830+00:00 to 2026-11-04T03:38:25.410792+00:00; 83.464451 wall seconds; all 196 cases pass, exit 0/empty stderr, frozen source exact.

Linux provider/compiler regression: 2026-11-04T03:37:37.143228+00:00 to 2026-11-04T03:38:28.031583+00:00; 50.888647 wall seconds; all 196 cases pass, exit 0/empty stderr, frozen source exact.

All four host-static commands pass on the exact synchronized Linux CPU source tree (GHC 9.12.4,
Cabal 3.16.1.0); these are ordinary static runs, not the final live Incus/KVM confirmation:

- core: `cabal test all`, 2026-11-04T03:39:06.103734+00:00 to 2026-11-04T03:45:35.342000+00:00; 389.240625 wall seconds; 4286 cases/355.85 reported seconds; exit 0, frozen source exact.
- demo: `cabal test all`, 2026-11-04T03:39:06.103647+00:00 to 2026-11-04T03:45:18.815055+00:00; 372.713664 wall seconds; 167 cases/1.43 reported seconds, 4286 cases/352.69 reported seconds; exit 0, frozen source exact.
- check_code: `poetry run python -m hostbootstrap.check_code`, 2026-11-04T03:39:06.103219+00:00 to 2026-11-04T03:39:06.876641+00:00; 0.773408 wall seconds; ruff, black and mypy pass; exit 0, frozen source exact.
- test_all: `poetry run python -m hostbootstrap.test_all`, 2026-11-04T03:39:06.103387+00:00 to 2026-11-04T03:39:13.184291+00:00; 7.080927 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, frozen source exact.

The synchronized audit matched all 992 Haskell files, 967 core-owned Haskell files and 95 governed
Markdown documents, across 1118 checked source/build/document subjects. The final live phase gate
remains owned by Sprint 15.50 after all lower implementation work.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T03:45:49.471879+00:00 to 2026-11-04T03:45:56.136084+00:00,
6.664230 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 15.17: Strong alias backend admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Narrow one matching provider capability to the exact clause-holding alias backend.

#### Deliverables

- `StrongAliasBackend` is abstract and retains the capability's provider generation, the host
  configuration, the project binary's self reference, and the capability's lift context — the frame the
  shipped ownership transaction is carried to.
- Admission performs no probe of its own: it requires the retained guest discovery's daemon and VM
  observations Ready and its egress observation not Conflict or Failure. Clause 1 is the protected store's
  exclusive entry, taken by the project binary in the guest, so no guest lock, stat, or interpreter front end
  is discovered.
- A Direct capability is `Unsupported`; a NotReady observation is a `ReprobeBeforeRetry` failure and an
  Unavailable one is `Unsupported`, each naming the probe that blocked and returned before any mutation.
- Backend, provider, generation, and capability identity remain nominally linked.
- The backend accepts no injected guest runner; its only route to the guest is the shipped transaction.

#### Validation

Five added ProviderBackendSpec cases obtain real capabilities through discoverProvider on the
FakeProvider or Direct route. Each checks the complete retained discovery and generation 17 before
applying discoverStrongAliasBackend. All-Ready guest discovery is admitted. A guest true returning
not found is Unsupported under provider VM capability, preserving the ready daemon prefix.
Unavailable provisioning egress is admitted; an unclassified permission-denied egress failure
returns the full provider provisioning egress FailureDetail and DoNotRetry. A fully ready Direct
capability returns the complete Unsupported detail for its absent guest alias frame. The guest
cases assert identical provider command history before and after admission and zero mutations;
Direct records exactly its readiness and discovery Docker invocations.

The passing prior-generation preparation case from Sprint 15.16 independently checks that the
strong backend retained generation 17 when the managed provider has become generation 18.
The selected compiler controls retain constructor and cross-backend refusals. Existing source
guards hold the absence of guest interpreter, stat and lock discovery.

The runPreparedGuestAliasCall Haddock now describes the shared shipped transaction, its retained
configuration/self/context, indexed result and separate settlement. Its only production-source
delta is that Haddock: seven physical lines added and eight removed in Alias.hs, with no runtime
production change. FakeProvider adds one explicit raw unclassified-egress behaviour and preserves
its default; the test module adds the five cases and a parameterized fixture entry. Both builds
pass without a warning-policy change. All other 989 Haskell files and all 697 compile-fail fixtures
are byte-preserved against the sprint baseline. The ownership invariant describes retained-prefix
admission and the shipped route.

Windows strong alias admission: 2026-11-04T03:47:20.228864+00:00 to 2026-11-04T03:47:22.863855+00:00; 2.634987 wall seconds; all 5 cases pass, exit 0/empty stderr, frozen source exact.

Linux strong alias admission: 2026-11-04T03:48:38.322088+00:00 to 2026-11-04T03:48:39.167288+00:00; 0.845186 wall seconds; all 5 cases pass, exit 0/empty stderr, frozen source exact.

Windows provider/compiler regression: 2026-11-04T03:47:55.121394+00:00 to 2026-11-04T03:49:32.046328+00:00; 96.925495 wall seconds; all 202 cases pass, exit 0/empty stderr, frozen source exact.

Linux provider/compiler regression: 2026-11-04T03:48:39.683283+00:00 to 2026-11-04T03:49:31.707011+00:00; 52.024026 wall seconds; all 202 cases pass, exit 0/empty stderr, frozen source exact.

All four host-static commands pass on the exact synchronized Linux CPU source tree (GHC 9.12.4,
Cabal 3.16.1.0); these are ordinary static runs, not the final live Incus/KVM confirmation:

- core: `cabal test all`, 2026-11-04T03:49:43.321449+00:00 to 2026-11-04T03:58:17.292802+00:00; 513.974471 wall seconds; 4291 cases/468.16 reported seconds; exit 0, frozen source exact.
- demo: `cabal test all`, 2026-11-04T03:49:43.313942+00:00 to 2026-11-04T03:57:48.994267+00:00; 485.683266 wall seconds; 167 cases/1.93 reported seconds, 4291 cases/465.96 reported seconds; exit 0, frozen source exact.
- check_code: `poetry run python -m hostbootstrap.check_code`, 2026-11-04T03:49:43.321159+00:00 to 2026-11-04T03:49:44.165529+00:00; 0.844356 wall seconds; ruff, black and mypy pass; exit 0, frozen source exact.
- test_all: `poetry run python -m hostbootstrap.test_all`, 2026-11-04T03:49:43.328132+00:00 to 2026-11-04T03:49:51.013294+00:00; 7.685191 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, frozen source exact.

The synchronized audit matched all 992 Haskell files, 967 core-owned Haskell files and 95 governed
Markdown documents, across 1118 checked source/build/document subjects. The final live phase gate
remains owned by Sprint 15.50 after all lower implementation work.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T03:58:46.988585+00:00 to 2026-11-04T03:58:56.087000+00:00,
9.098443 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 15.18: Guest-alias origin and identity protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Hold locked-origin identity ownership over guest alias acquisition.

#### Deliverables

- The alias acquisition is one shipped symbolic-link transaction: the project binary in the guest takes the
  protected store's exclusive entry at `<target>/.hostbootstrap-alias-authority-v1`, and that entry spans
  origin observation, mutation, identity binding, and readback (clause 1).
- The origin record is keyed by a digest of the alias path and target, records explicit absence before any
  mutation, and claims the link target through the shared origin-record codec (clause 2).
- The authority directory lives inside the durable share, so the frame that owns the share reads the same
  ownership records the guest writes.
- The staging symlink is named from the record key beside the alias; its own device/inode identity is bound
  into the record before it is published at the alias path without replacement (clause 3).
- An interruption after origin publication, or after the pre-publication identity binding, resumes the same
  transaction and finishes publishing that exact inode; an exact-looking link with no record is foreign.

#### Validation

`ProviderAliasSpec`'s shipped-ownership cases run the production row against the real kernel: create, exact
retry, and release over one durable identity; an exact-looking unrecorded alias left foreign; resumption
after origin publication; and resumption after the pre-publication identity binding, which also removes the
staging link. `OwnershipShippedSpec` covers the same row's symbolic-link publication and retry, the foreign
exact-looking link, and a replacement refused on release and left intact.

#### Remaining Work

None.

### Sprint 15.19: Prepared alias acquisition adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/engineering/testing.md`

#### Objective

Make the prepared alias call and strong alias backend the sole acquisition route.

#### Deliverables

- Only a matching prepared call and strong backend can run the shipped acquisition.
- The durable record identifies the alias by its path and target and binds the link's own device/inode. The
  alias resource's plan, generation, and provider origin are checked at preparation (Sprint 15.16) and are not
  stored in the record, so a later prepared call for the same alias path and target finds the recorded link
  and settles it Repaired, or Unchanged when it holds the prior commit proof — never by pathname shape alone.
- The shipped answer maps totally to indexed observations: a created link is Created; a retained link is
  Repaired without and Unchanged with a matching prior proof; an occupied path is Foreign; an ownership
  conflict is Conflict; an unsupported row is Unsupported; a failed probe is a `ReprobeBeforeRetry` failure;
  a malformed record or an inapplicable outcome is a `DoNotRetry` failure.
- A foreign alias is left in place and settles as a descriptive foreign observation.
- A settled alias exposes its descriptive committed operation key for journal verification while its generic handle and receipt remain private.

#### Validation

The unused alias owner binding and its Text field in all three prepared/managed representations
are deleted. The managed-handle and release Haddocks describe the retained alias/target specification
and exact receipt/version checks. The legacy tracking row is removed. A settled alias exposes only
its descriptive committed operation key, which the journal verifier consumes without exposing the
receipt or generic managed handle; the reviewed export inventory includes it. The 27 native sealed
export-surface checks pass independently.

Six counted acquisition cases run the prepared strong backend and settlement route. On Linux the
FakeProvider guest handler launches the shipped argv as a real local child with inherited protocol
pipes; the suite's frame interpreter performs ownership against the kernel. The actual target is
the managed share's declared guest target. Created and subsequent Repaired are checked through both
the indexed result view and managed settlement. Unchanged uses the first actual settlement's
operation key and verifies a committed journal record against its admitted plan, exact alias and
generation before obtaining PriorCommitProof.

The unrecorded exact link settles the complete Foreign observation and stays in place. A valid
record with a different target claim returns the entire read-provider-guest-alias-ownership
DoNotRetry failure and creates no alias. The replacement case renames the old link aside to retain
its inode, creates a different link, measures both identities, and asserts the entire ConflictDetail
through both result and settlement while preserving the replacement.

The shared guest handler and support predicate live in FakeProvider; ProviderAliasSpec reexports
them. The new manifest family counts all six kernel branches on Linux and all six declared
unsupported-row refusals on Windows. Both seven-case focused selections also pass the declared-size
check. Existing private compiler controls compile their ConditionalCase helper in the owner unit;
ordinary mixins and warning policy stay intact.

Initial builds caught a moved redundant import, an effectful preparation join, a codec bytes/type
mismatch, a shadowing local name and a redundant pattern. All were corrected; both final builds
pass under unchanged -Werror. Production delta is one module: 27 physical lines added/47 removed,
26 non-empty lines added/46 removed, within the sprint bound. The other 985 Haskell files and all
697 compile-fail fixtures are byte-preserved against the sprint baseline; LF and scoped diff checks
pass. The ownership invariant and testing guide describe the journal metadata and real guest child.

Windows acquisition/refusal and manifest checks: 2026-11-04T04:07:52.216897+00:00 to 2026-11-04T04:07:52.514257+00:00; 0.297325 wall seconds; all 7 cases pass, exit 0/empty stderr, frozen source exact.

Linux acquisition and manifest checks: 2026-11-04T04:10:13.993398+00:00 to 2026-11-04T04:10:17.264863+00:00; 3.271451 wall seconds; all 7 cases pass, exit 0/empty stderr, frozen source exact.

Windows provider/compiler regression: 2026-11-04T04:09:53.970005+00:00 to 2026-11-04T04:12:07.913538+00:00; 133.944323 wall seconds; all 209 cases pass, exit 0/empty stderr, frozen source exact.

Linux provider/compiler regression: 2026-11-04T04:10:40.657601+00:00 to 2026-11-04T04:12:01.404912+00:00; 80.747777 wall seconds; all 209 cases pass, exit 0/empty stderr, frozen source exact.

All four host-static commands pass on the exact synchronized Linux CPU source tree (GHC 9.12.4,
Cabal 3.16.1.0); these are ordinary static runs, not the final live Incus/KVM confirmation:

- core: `cabal test all`, 2026-11-04T04:12:41.193974+00:00 to 2026-11-04T04:22:18.403396+00:00; 577.212921 wall seconds; 4298 cases/528.43 reported seconds; exit 0, frozen source exact.
- demo: `cabal test all`, 2026-11-04T04:12:41.194188+00:00 to 2026-11-04T04:22:28.578910+00:00; 587.388284 wall seconds; 167 cases/2.32 reported seconds, 4298 cases/527.42 reported seconds; exit 0, frozen source exact.
- check_code: `poetry run python -m hostbootstrap.check_code`, 2026-11-04T04:12:41.200263+00:00 to 2026-11-04T04:12:42.013912+00:00; 0.813626 wall seconds; ruff, black and mypy pass; exit 0, frozen source exact.
- test_all: `poetry run python -m hostbootstrap.test_all`, 2026-11-04T04:12:41.200036+00:00 to 2026-11-04T04:12:48.599672+00:00; 7.399656 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, frozen source exact.

The synchronized audit matched all 992 Haskell files, 967 core-owned Haskell files and 95 governed
Markdown documents, across 1118 checked source/build/document subjects. The final live phase gate
remains owned by Sprint 15.50 after all lower implementation work.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T04:23:19.172986+00:00 to 2026-11-04T04:23:30.299147+00:00,
11.126209 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 15.20: Conditional alias release [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Release an alias only against its exact observation version and a re-observation of the exact bound
identity.

#### Deliverables

- `PreparedGuestAliasRelease` accepts only the exact opaque managed alias and a positive observation version
  equal to the handle's; a zero version is a `DoNotRetry` failure and a different version is `Conflict`, both
  before any guest call.
- The shipped give-back re-enters the alias record under the protected store's exclusive entry, re-observes
  the link's device/inode against the bound identity, unlinks only that identity, and forgets the record only
  over the absence it then observes (clause 4: object first, record second).
- A managed record whose alias is already absent converges: the record is forgotten and the release is given
  back, so an interrupted release and an external unlink end in the same settled state.
- A replacement leaves the alias and its record untouched as `Conflict`; an unrecorded occupant is a
  `Conflict` naming the foreign occupant; no record and no link is an already-released success.
- The record's own write and unlink windows are the protected store's contract (Sprint 15.36).
- The authority directory `<target>/.hostbootstrap-alias-authority-v1` is the protected store's own and stays
  in the durable share after its last record is forgotten.

#### Validation

Four added controls reuse the real prepared-acquisition fixture and its strong alias backend.
Zero version returns the complete prepare-guest-alias-release FailureDetail with DoNotRetry.
Version 14 against the retained observation version 13 returns the entire ConflictDetail.
Both cases assert the retained version, zero entered continuations and zero provider commands
after acquisition; an accidentally admitted continuation is executed before those assertions.

The replacement control retains the original inode beside a new link, prepares release at version
13, and runs the actual shipped give-back. It compares the full conflict with independently measured
old/new identities, unchanged ownership-record bytes and the surviving replacement link target.
The positive control prepares and runs exact release, then checks that the alias and its record
are gone while the durable target and authority directory still exist.

The manifest declares four cases on every host. Linux runs all four against the real symbolic-link
row through the FakeProvider guest child; Windows completes all four declared unsupported-row
refusals. Both five-case focused selections include the declared-size check. The retained-inode
fixture is shared with acquisition without changing its assertions; the broader selection reruns
those cases and the ForeignGuestAliasRelease compiler refusal.

Both final builds pass under unchanged -Werror. Production delta is zero. Only ProviderBackendSpec
and CoverageManifest change: 92/10 and 7/0 physical lines added/removed respectively. The other
990 Haskell files and all 697 compile-fail fixtures are byte-preserved against the sprint baseline;
LF and scoped diff checks pass. The ownership and durable-state guides describe the release fence,
replacement preservation and record/directory lifetime.

Windows release/refusal and manifest checks: 2026-11-04T04:25:14.954099+00:00 to 2026-11-04T04:25:15.098099+00:00; 0.143978 wall seconds; all 5 cases pass, exit 0/empty stderr, frozen source exact.

Linux release and manifest checks: 2026-11-04T04:26:44.808429+00:00 to 2026-11-04T04:26:46.993785+00:00; 2.185338 wall seconds; all 5 cases pass, exit 0/empty stderr, frozen source exact.

Windows provider/compiler regression: 2026-11-04T04:26:05.009180+00:00 to 2026-11-04T04:28:13.568017+00:00; 128.559595 wall seconds; all 215 cases pass, exit 0/empty stderr, frozen source exact.

Linux provider/compiler regression: 2026-11-04T04:26:48.310632+00:00 to 2026-11-04T04:28:11.673974+00:00; 83.363821 wall seconds; all 215 cases pass, exit 0/empty stderr, frozen source exact.

All four host-static commands pass on the exact synchronized Linux CPU source tree (GHC 9.12.4,
Cabal 3.16.1.0); these are ordinary static runs, not the final live Incus/KVM confirmation:

- core: `cabal test all`, 2026-11-04T04:31:55.596126+00:00 to 2026-11-04T04:39:50.392428+00:00; 474.799164 wall seconds; 4303 cases/424.60 reported seconds; exit 0, frozen source exact.
- demo: `cabal test all`, 2026-11-04T04:31:55.585077+00:00 to 2026-11-04T04:39:30.251993+00:00; 454.669667 wall seconds; 167 cases/2.66 reported seconds, 4303 cases/435.25 reported seconds; exit 0, frozen source exact.
- check_code: `poetry run python -m hostbootstrap.check_code`, 2026-11-04T04:31:55.484816+00:00 to 2026-11-04T04:31:56.442350+00:00; 0.957512 wall seconds; ruff, black and mypy pass; exit 0, frozen source exact.
- test_all: `poetry run python -m hostbootstrap.test_all`, 2026-11-04T04:31:55.598430+00:00 to 2026-11-04T04:32:04.622487+00:00; 9.024083 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, frozen source exact.

The synchronized audit matched all 992 Haskell files, 967 core-owned Haskell files and 95 governed
Markdown documents, across 1118 checked source/build/document subjects. The final live phase gate
remains owned by Sprint 15.50 after all lower implementation work.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T04:40:04.873751+00:00 to 2026-11-04T04:40:11.152754+00:00,
6.279026 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 15.21: Node alias-route adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`, `core/hostbootstrap-core/test/Fixture.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Adopt the prepared alias boundary at the plan-owned node route.

#### Deliverables

- `reconcileNodeGuestAlias` takes the planned provider and share with their managed handles from its caller,
  refuses a handle whose key is not the planned resource's key, and resolves the alias projection from the
  node descriptor (`withNodeGuestAliasProjection`); generation and origin agreement are
  `withPreparedGuestAliasCall`'s checks, and the function's Haddock states exactly that split.
- The plan traversal reruns the share probe while sealing preconditions.
- The projected alias gate is taken once for one prepared effect.
- Missing or mismatched dependencies refuse before guest execution.
- The route returns only change or foreign descriptive settlement. A rerun over the link this route already
  owns (the shipped row's `ShippedSymbolicLinkRetained`) settles as Repaired, because the route passes no
  prior commit proof and `completePreparedUnchanged` admits Unchanged only over one, the rule every prepared
  provider and share settlement in this phase follows.

#### Validation

The private AliasCallObservation variants carry no generation supplied by an observation. The
indexed opaque result retains generation only for the public descriptive view, while settlement
uses its retained prepared handle. The vacuous AlreadyExact generation comparison is removed.
Haddocks and the lifecycle guide state the caller's planned/managed key checks and preparation's
generation, origin, plan and fresh-share-probe checks. The public result view remains compatible.

Four node-route cases use real Chain provider and share actions with actual interpreter gates.
The provider is provisioned, readied, carried and registered as a runtime dependency; the share
action obtains that authority through the service, prepares and settles the share, and invokes
reconcileNodeGuestAlias. They establish Created, the complete unrecorded-link foreign observation,
the exact conflict on taking the projected gate twice, and Created then Repaired across fresh
public root invocations with the same canonical root and plan. The rerun fixture verifies closed
sessions and acknowledges each completed lease before admitting another broker epoch.

Six further real-Chain controls cover missing provider and share dependencies, planned/managed
provider and share key mismatches, stale backend generation, and a share from another provider
origin. A temporary compiler producer selects the actual private interfaces for the descriptor
or planned-key change; it does not widen ordinary package visibility. Replacement cases stop and
delete the original VM and provision/readiness-settle generation 18 through the public prepared
route. Every case asserts its full ReconcileError, zero probes, zero guest invocations, zero
provider commands and zero provider mutations after setup. The action returns a terminal refusal,
the Chain stops, and the wrapper compares the exact reported terminal diagnostic.

The four guest cases remain a declared-size platform family on every host. Linux exercises the
actual shipped symbolic-link row; Windows asserts all four declared unsupported results. The six
refusal controls execute on both hosts. The wrapper also requires the complete correctly indented terminal diagnostic.

Production scope is one module, Alias.hs, with 35/52 nonempty lines added/removed. Only four test/support modules also change; the other 987 Haskell files and all 697 compile-fail fixtures are byte-preserved against the sprint baseline. Both final native and Linux builds pass under unchanged -Werror.

Windows node/refusal and manifest checks: 2026-11-04T05:31:44.659903+00:00 to 2026-11-04T05:32:34.483499+00:00; 49.823884 wall seconds; all 11 cases pass, exit 0/empty stderr, frozen source exact.

Linux node/refusal and manifest checks: 2026-11-04T05:32:07.481836+00:00 to 2026-11-04T05:32:28.139301+00:00; 20.657573 wall seconds; all 11 cases pass, exit 0/empty stderr, frozen source exact.

Windows provider/compiler regression: 2026-11-04T05:32:50.182476+00:00 to 2026-11-04T05:35:12.792954+00:00; 142.611331 wall seconds; all 226 cases pass, exit 0/empty stderr, frozen source exact.

Linux provider/compiler regression: 2026-11-04T05:32:35.979536+00:00 to 2026-11-04T05:33:56.828529+00:00; 80.849467 wall seconds; all 226 cases pass, exit 0/empty stderr, frozen source exact.

All four host-static commands pass on the exact synchronized Linux CPU source tree (GHC 9.12.4,
Cabal 3.16.1.0); these ordinary static runs do not establish the live Incus/KVM confirmation:

- core: `cabal test all`, 2026-11-04T05:34:48.006463+00:00 to 2026-11-04T05:41:28.824318+00:00; 400.819756 wall seconds; 4314 cases/367.57 reported seconds; exit 0, frozen source exact.
- demo: `cabal test all`, 2026-11-04T05:42:18.440391+00:00 to 2026-11-04T05:50:36.855816+00:00; 498.417052 wall seconds; 167 cases/1.34 reported seconds, 4314 cases/358.29 reported seconds; exit 0, frozen source exact.
- check_code: `poetry run python -m hostbootstrap.check_code`, 2026-11-04T05:33:20.789008+00:00 to 2026-11-04T05:33:21.606870+00:00; 0.817848 wall seconds; ruff, black and mypy pass; exit 0, frozen source exact.
- test_all: `poetry run python -m hostbootstrap.test_all`, 2026-11-04T05:33:20.789268+00:00 to 2026-11-04T05:33:27.748818+00:00; 6.959576 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, frozen source exact.

The synchronized audit matched all 992 Haskell files, 967 core-owned Haskell files and 95 governed
Markdown documents, across 1118 checked source/build/document subjects. The final live phase gate
remains owned by Sprint 15.50 after all lower implementation work.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-04T05:51:00.309021+00:00 to 2026-11-04T05:51:06.497286+00:00,
6.188270 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


### Sprint 15.22: Provider-live prepared-route adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/provider-live/ProviderLiveMain.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveConfig.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveRunner.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveAliasFixture.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Make the opt-in native provider component a static client of the same sealed backend used by production.

#### Deliverables

- The component is compiled by the ordinary gate on every host and uses a runtime Linux/x86_64/KVM/Incus
  check plus an explicit confirmation guard to decide whether to exercise its live subject.
- It constructs validated Incus and Direct specs and admits their generative strong backends.
- Provision, ready, share, stop, and delete use only matching prepared calls and settlements.
- Discovery and guest execution derive only from the matching managed Running provider.
- Alias acquisition and release use only matching prepared alias calls and opaque managed authority.
- After the exact owned VM and share are ready, the live-only fixture installs and syncs its current executable
  through the admitted Incus file API; that executable's main serves the hidden frame-child entry with the
  shipped-ownership interpreter before considering the live-run entry.
- Cleanup addresses only exact owned VM, share, alias, and origin identities and reports residue as failure.
  The residue checks read the protected store's own record and staging grammar (`<key>.rec` and
  `<key>.rec.tmp-<16 hex>`), and the provider-record check covers every key under the VM name, share records
  included. The owned-state check reads the listing row whose name is exactly the run's VM, and a run that
  fails before its durable intent is published removes its root and names no VM in its remedy.
- Every step after provisioning, including the initial ready and its recovery, runs under the exception
  boundary that hands a thrown failure to cleanup, so a provisioned VM is deleted however the route ends; when
  the route body and the alias release both fail, the reported failure names both.

#### Validation

Static implementation validation and the confirmed live lifecycle gate pass on the synchronized
source recorded below. Sprint 15.50 owns the final confirmation after the remaining implementation.

Final Windows compilation of all components with tests enabled: 2026-11-04T06:04:10.945692+00:00 to 2026-11-04T06:04:14.636998+00:00; 3.691315 wall seconds, exit 0/empty stderr. Final dedicated Linux compilation with tests enabled: 2026-11-04T06:04:19.867375+00:00 to 2026-11-04T06:04:24.640748+00:00; 4.773395 wall seconds, exit 0/empty stderr. Both use the package's unchanged -Werror policy.

The final Windows ProviderSpec/DocValidatorSpec selection passed all 45 cases at 2026-11-04T06:06:12.082954+00:00 to 2026-11-04T06:06:18.938360+00:00; 6.855409 wall seconds; exit 0/empty stderr, frozen source exact.

All four host-static commands pass on Ubuntu 24.04.5 x86_64 in the dedicated hostbootstrap-linux
WSL2 distribution, as user hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3:

- core: `cabal test all`; 2026-11-04T06:05:01.330947+00:00 to 2026-11-04T06:13:24.082498+00:00; 502.753210 wall seconds; 4314 cases/459.51 reported seconds; exit 0, both source snapshots exact.
- demo: `cabal test all`; 2026-11-04T06:14:03.421250+00:00 to 2026-11-04T06:26:45.207333+00:00; 761.788595 wall seconds; 167 cases/1.82 reported seconds, 4314 cases/471.18 reported seconds; exit 0, both source snapshots exact.
- check_code: `poetry run python -m hostbootstrap.check_code`; 2026-11-04T06:04:19.867255+00:00 to 2026-11-04T06:04:20.985969+00:00; 1.118717 wall seconds; ruff, black and mypy pass; exit 0, both source snapshots exact.
- test_all: `poetry run python -m hostbootstrap.test_all`; 2026-11-04T06:04:19.867369+00:00 to 2026-11-04T06:04:26.865319+00:00; 6.997976 wall seconds; 376 cases; 100% coverage, 1585 statements/460 branches; exit 0, both source snapshots exact.

The source synchronization checks every one of 1160 source/build/document files against the Windows
working tree. The production delta is 72/34 nonempty lines added/removed in ProviderLiveRunner and
46/43 in ProviderLiveAliasFixture: 195 changed lines across two modules. The other 990 Haskell files
and all 697 compile-fail fixtures are byte-preserved; scoped LF and diff checks pass.

The explicitly confirmed component preflight failed at 2026-11-04T06:05:11.462966+00:00 to 2026-11-04T06:05:12.261791+00:00, 0.798829 wall seconds. The actual live binary exited 1 because opening /dev/kvm returned
No such device (ENODEV). Its source snapshot was exact and the temporary-root listing remained
empty before and after the run. This proves the early device refusal without VM intent creation.
Incus local initialization completed at 2026-11-04T06:37:52.213399+00:00 to
2026-11-04T06:37:55.534809+00:00 (3.323283 wall seconds): the local daemon, default dir storage pool
and root-disk profile were configured. At that initialization the profile had no NIC, there were no
managed networks or HTTPS listener, and interface and route data matched exactly before and after it. The
ordinary user (UID 1000, incus-admin group) passes waitready and reads the pool/profile configuration.
At that audit, usable KVM, VM-network configuration and the confirmed lifecycle gate remained owed.

The resumed 2026-11-04 20:18 UTC host audit finds the other WSL distributions stopped and a user-added
gpuSupport=false setting; repository sources still match all 1160 verified files. KVM still returns
ENODEV and neither SVM nor VMX is exposed. The Windows host is build 26300.9711 with KB5127648 installed.
A direct read-only HCS ProcessorCapabilities query returns HRESULT 0x8007000D (invalid data), matching
the [confirmed upstream regression](https://github.com/microsoft/WSL/issues/41917).
[Microsoft's KB5127936 update](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/10/kb5127936-windows-11-25h2-26h2-update)
for build 26300.9818 documents the AMD WSL2 nested-virtualization fix. At that audit, the fix was
neither installed nor staged and no Windows reboot was pending. Windows Update's read-only search did
not offer the cumulative fix. The official x64 update and checkpoint packages are staged separately for review. Their SHA-1
hashes match Microsoft's download filenames, and Windows Authenticode verifies both signatures as
Valid from Microsoft Corporation. The user authorized installation on 2026-11-05. Both package
hashes and Microsoft signatures were reverified. The NoRestart servicing invocation, including
verification, ran from 2026-11-05T02:24:52.8318446Z to 2026-11-05T02:30:07.5121177Z (314.675320 wall
seconds) and completed successfully. Add-WindowsPackage returns Online=True, RestartNeeded=True;
Windows reports that restart was suppressed. Post-install inspection lists KB5127936, marks the
9818 servicing package InstallPending and the prior 9711 package UninstallPending, and confirms the
component-servicing reboot-pending flag. The user completed the PC reboot: at 2026-11-05 02:46 UTC,
Windows reports build 26300.9818 with no reboot pending. The HCS ProcessorCapabilities query succeeds
with HRESULT 0x00000000 and includes NestedVirt. The ordinary WSL user sees SVM and opens /dev/kvm
read/write successfully.
No PC reboot or global WSL configuration change has been performed by the agent.
The Windows servicing prerequisite is now verified. Incus 6.0.0 reports its QEMU 8.2.2 driver and
ready dir storage. At 2026-11-05T02:53:30.189423+00:00 to 02:53:34.206999+00:00 (4.019390 wall seconds),
the ordinary user created the owned hb15br0 bridge at 10.223.15.1/24 with IPv4 NAT and IPv6 disabled.
The subnet does not overlap observed Windows or WSL routes. The default profile retains its original
root disk and adds only the eth0 NIC on this bridge; the network carries user.hostbootstrap.owner
phase15-live-gate. The confirmed lifecycle gate subsequently passed as recorded below.

Initial readiness uses attemptReconcile, including exceptions from gateFor's store/key/record
operations and from the ready call. Provisioned-state recovery uses the same exception boundary.
combineBodyRelease normalizes thrown and returned failures and retains both in the
"body failure: ...; release failure: ..." diagnostic when both fail. The fixture's step plan is
Either StepPlanError StepPlan, passed directly to the validated builder. Haddocks state the three
callback lifetimes and place the guest-self-path explanation on liveGuestSelfPath.

The runner performs host configuration and Incus/KVM preflight before temporary-root creation.
KVM permission bits are followed by an actual read-only device open, so ENODEV fails before any
VM intent or creation. Its exception boundary tracks successful durable intent publication;
collision and other pre-intent setup failures remove the owned temporary root, while only a
post-publication failure prints cleanupRemedy. Name-and-state readback selects exactly vmName,
staging residue uses the store writer's .rec.tmp- grammar, and provider-record residue includes
every vmName-dot entry, including share records and their staging.

The ProviderSpec source guard rejects raw lifecycle planners, opaque provider-authority constructor
imports, an independent guest executor, and any Direct delete path after prepared stop refusal.
Compile the component with `cabal build all --enable-tests` on Windows and Linux; the package's
common warnings hold -Werror. Run the source guards and all four host-static commands.

The full confirmed command below passed on the native Linux/x86_64 KVM/Incus gate host and is
recorded in the phase-level baseline acceptance. An unrequested Unsupported result establishes no
live lifecycle evidence.

Active-status native DocValidatorSpec passed all 17 cases at 2026-11-04T06:27:32.274963+00:00 to 2026-11-04T06:27:38.472971+00:00,
6.198013 wall seconds, exit 0/empty stderr, with Active status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

Active-status native DocValidatorSpec passed all 17 cases at 2026-11-04T06:40:48.977353+00:00 to 2026-11-04T06:40:55.164520+00:00,
6.187180 wall seconds, exit 0/empty stderr, with Active status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

The dedicated user can run only seven exact read-only sudo probes for QEMU, firmware and virtiofsd;
`sudo -n true` remains refused. The environment now includes qemu-system-modules-spice and
incus-agent, Ubuntu recommendations omitted by the initial no-recommends dependency install.
The stopped VM left by the missing-SPICE launch failure was removed only after its exact name,
UUID, ownership marker, durable intent and provider record agreed; its owned temporary root was removed.
Keeping a foreground WSL process open avoids idle shutdown during validation.

On 2026-11-05 the standalone confirmed provider-live component passed at 03:19:12.619257 to
03:19:56.254494 UTC (43.714093 wall seconds), exit 0/empty stderr.
The complete, unfiltered command from `core/` then passed:

```text
HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct
```

The full run started at 2026-11-05T03:20:08.856646+00:00 and finished at
2026-11-05T03:30:35.645767+00:00, 626.885361 wall seconds, exit 0. The provider-live component
reported PASS and the main suite passed all 4314 tests (561.75 reported seconds).
Both commands preserved all 1160 source/build/document files exactly in the Windows working tree
and the dedicated Linux source tree. The actual gate host is Ubuntu 24.04.5 x86_64,
Linux 6.18.33.2-microsoft-standard-WSL2, GHC 9.12.4/Cabal 3.16.1.0, Incus client/server 6.0.0
and QEMU 8.2.2. The lifecycle and exact residue checks passed, including the Direct refusal boundary.
The phase remains Active; Sprint 15.50 still owes confirmation of the finished phase tree.

Closed-status DocValidatorSpec passed all 17 cases on 2026-11-05 at 03:33:02.445908 to
03:33:07.979501 UTC (5.533589 wall seconds; 5.45 reported seconds), exit 0/empty stderr,
with all 1160 files exact before and after the run.

#### Remaining Work

None.


### Sprint 15.23: Provider suite host neutrality [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/engineering/incus.md`

#### Objective

Assert this phase's provider boundary from every supported outer host realization.

#### Deliverables

- Every host `HostConfig` tool table in the phase's suites names either a path built through the
  fixture-path constructor the [Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns
  or a real executable written under a host temporary root, so the same total `AbsExe` constructor
  production uses admits them on the host that runs them.
- Every assertion that compares a rendered argument vector against one of those paths compares the same
  constructed value, so a host-neutral fixture cannot weaken a retained-tool or no-bare-command guard.
- Guest paths stay POSIX. A guest alias spec, an in-VM `which` result, and a guest argument vector name
  files on a different machine reached through one host-provider command, which is the invocation split
  § K already draws; only the host side moves.
- The POSIX-only cases the suites already separate — the real `flock(2)` namespace, the crash-resume
  fixtures, and the symlink-root probe — keep their existing platform conditions and are skipped rather
  than failed on an outer host that cannot run them.
- The work is test-harness only: no production module, no named type, and no change to any provider
  contract the phase already states.

#### Validation

`cabal test all --ghc-options=-Werror` from `core/`, run host-native and recorded against the outer host
that ran it (§ II), on a POSIX outer host and on Windows. The phase's existing static evidence below
records the POSIX side; the Windows side is what this sprint adds. The provider-live component and the
live KVM/Incus route are unaffected, because both are declared Linux/x86_64 and keep their own gate.

Each suite takes its host side the way its subject needs. `ProviderBackendSpec` names its host tools as
`fixture*` bindings built by `PlatformPath.hostFixturePath` and hands those exact values to the production
`mkAbsExe`; the Direct Ready request assertion compares the same constructed values rather than a POSIX
literal. `ProviderReconcileSpec` builds its provider state path with `hostFixturePath` and its host tools as
real executables `Fixture.newFakeTool` writes under a temporary root. `ProviderAliasSpec` builds no
`HostConfig` and no tool table: its cases are the guest descriptor and the shipped row run against the
kernel. The guest side is stated where it is written: the in-VM `which` result,
the guest argument vector, the Incus provider state directory, and the Direct already-local root name
files inside the Linux substrate the provider realizes, so they stay POSIX and the backend's own
POSIX absoluteness check matches them.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal test all --ghc-options=-Werror` from `core/` host-native at 1,877/1,877 in 211.76 seconds,
including every case in the three suites above. Confirming the same gate on the remaining gate host
families belongs to the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md) (§ JJ), not to this sprint.

#### Remaining Work

None.

### Sprint 15.24: The one guarded destructive delete [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Frame.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/lima.md`,
`documents/engineering/wsl2.md`

#### Objective

Write the frame table's first shared computation once, so the three providers that remove a frame answer the
same question the same way (§ LL).

#### Deliverables

- `HostBootstrap.Substrate.Frame` owns `guardedDeleteArgs`: the guard, the refusal, and the noun table. A
  provider module supplies only its own noun and its own argument vector, and receives the name after the
  guard has admitted it. The argv callback is a plain `String -> [String]` and the result a plain argument
  list, so the types do not stop a row from ignoring the admitted name or rendering a delete without the
  guard; every row passes the admitted name through, and the `guardedDeleteArgs` Haddock states that as the
  rows' convention, held by the shared case below and each realization's import guard.
- `FrameNoun` is the closed table of what each frame calls the thing it removes, so a refusal reads in the
  operator's own terms without the computation being written again to say so.
- Two degenerate inputs refuse before the prefix is compared: an empty guard prefix, which is a prefix of
  every name, and an empty name. Each of the three rows independently admitted an empty prefix, and each
  passed its own test, because each test only asked whether a differently-prefixed name refused.
- Lima's `deleteVMArgs`, Incus's `destroyVMArgs`, and WSL2's `wslUnregisterArgs` are three rows over that one
  computation. The frames still spell the removal differently — WSL2's is `--unregister` — and that
  difference is the row's argv rather than a second guard.
- The dependency direction is unchanged: the shared table is below the realizations, and each provider
  suite's import guard names it explicitly rather than admitting an open set.

#### Validation

`ProviderSpec`'s guarded-delete group asks all three rows the same four questions at once — an admitted name
reaches the row's own argv, an unguarded name refuses in the frame's own noun, an empty prefix refuses as
vacuous, and an empty name refuses before the prefix is compared. `IncusSpec`, `LimaSpec`, and `Wsl2Spec`
each pin the exact import token set their realization takes from the shared table.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/` host-native at 1,922/1,922 in 234.62 seconds. The
declared native Linux/x86_64 provider-live build and live KVM/Incus route are unaffected by this sprint and
keep the evidence recorded below.

The guardedDeleteArgs Haddock now states that passing the admitted name through is the rows'
convention, which the callback's types do not enforce. The Lima engineering page states the same
boundary; the Incus page already does, and the WSL2 page carries no stronger type claim.
All four host-static commands pass for this correction, as recorded below.

The 2026-11-05 correction changes only three removed/three added nonempty Haddock lines in
Substrate/Frame.hs and aligns the Lima engineering paragraph. The other 991 Haskell files and
all 697 compile-fail fixtures are byte-preserved; scoped LF and diff checks pass.
The shared ProviderSpec guarded-delete group still exercises all three rows' admitted argv,
foreign-name refusal, empty-prefix refusal and empty-name refusal. IncusSpec, LimaSpec and
Wsl2Spec still hold the exact shared-table import guards.

All four commands ran in the dedicated hostbootstrap-linux WSL2 distribution, Ubuntu 24.04.5
x86_64, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3:

- `cabal test all` from `core/`: 2026-11-05T03:34:13.326899+00:00 to 2026-11-05T03:42:29.431479+00:00;
  496.104581 wall seconds; 4314 cases/505.42 reported seconds; exit 0.
- `cabal test all` from `demo/`: 2026-11-05T03:34:13.334408+00:00 to 2026-11-05T03:42:39.385189+00:00;
  506.050780 wall seconds; 167 demo cases/1.95 reported seconds and 4314 core cases/504.19 reported seconds; exit 0.
- `poetry run python -m hostbootstrap.check_code`: 2026-11-05T03:34:13.335028+00:00 to 2026-11-05T03:34:14.580915+00:00;
  1.245888 wall seconds; ruff, black and mypy pass; exit 0.
- `poetry run python -m hostbootstrap.test_all`: 2026-11-05T03:34:13.359956+00:00 to 2026-11-05T03:34:20.999896+00:00;
  7.639918 wall seconds; 376 cases/6.44 reported seconds; 100% coverage (1585 statements/460 branches); exit 0.

Each command verifies all 1160 source/build/document files before and after execution against
both the Windows working tree and the dedicated native Linux source tree. The package's
unchanged common warning policy holds -Werror. The ordinary provider-live component is compiled
and reports Unsupported without confirmation; the dated confirmed lifecycle evidence belongs to
Sprint 15.22, and Sprint 15.50 owns the final phase run.

#### Remaining Work

None.


### Sprint 15.25: The shipped ownership authority path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Keep the shipped transaction as the transport to the owning frame and seal its authority-root role.

#### Deliverables

- The existing closed transaction crosses through the lift's one fold and the authenticated handoff. An empty context is a real local self-fork; the receiving process holds the protected store's exclusive entry for its own lifetime and uses that store's compare-and-swap.
- The far side runs the binary's selected host row: POSIX in a Linux guest, the outer host's own row under an empty context. Darwin's symbolic-link publication uses renamex_np(RENAME_EXCL); Windows refuses the symbolic-link acts as OwnershipUnsupported.
- The six acts remain observe, take-directory, take-file, give-back, take-symbolic-link and give-back-symbolic-link; no act runs a command.
- A private-constructor authority-path type admits nonempty absolute Unicode scalar paths, refusing NUL and surrogate escapes. Guest paths use POSIX grammar; empty-context paths retain the outer host's native grammar, including fully absolute Windows paths. The receiver refuses a path outside its own absolute grammar before opening the store.
- ShippedOwnership is abstract, with a producer that requires the authority-path type and descriptive selectors. The guest alias spec retains validated authority data so its transaction producer uses no partial conversion.
- The module header states the per-frame host row. The observation Haddock states that the act records nothing while opening an absent authority store creates its directories and identity file. The encoder describes UTF-8 path text and an arbitrary-byte payload.

#### Validation

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `OwnershipShippedSpec`
passed 23/23 — three column cases, seven transaction-codec cases, four outcome-codec cases, seven
transactions run against the production row and a real protected store, and two crossings across a real
process boundary. Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 2,174/2,174 in
220.73 seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

**Coverage owed rather than claimed (§ NN).** A crossing into a provider frame is the
[worked-demo phase](phase-24-worked-demo.md)'s to confirm live. This sprint's crossings are all
empty-context, so what they prove is the transport and the far-side transaction, not that a provider
guest answers one.

The authority producer rejects empty, relative, NUL and surrogate-escape paths. Hand-built transaction wires with an empty or relative authority refuse as OwnershipMalformed. Native absolute Windows and POSIX examples remain codec values, while an authority in the wrong receiving-host grammar refuses before store creation. OwnershipShippedSpec exercises an empty-context native transaction against the real kernel. A registered compile-fail fixture rejects a raw FilePath as authority, and the export inventory holds the constructor boundary.

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The authority-path implementation and adoption are in place on 2026-11-05. ShippedOwnership
has a private positional constructor and descriptive functions; the alias spec retains admitted
authority and record-key values, so its transaction producer performs no partial conversion.
Four focused authority cases and RawFilePathAsShippedAuthority.hs are added. The wire format
is unchanged. Compilation, the focused checks and all four host-static commands pass.

On 2026-11-05, `cabal build all --enable-tests` from `core/` passes on both hosts with the
unchanged -Werror policy: native Linux at 03:56:30.110838 to 03:56:49.064928 UTC
(18.954090 wall seconds) and Windows at 03:56:30.109234 to 03:56:50.958337 UTC
(20.849097 wall seconds), both exit 0/empty stderr with frozen source exact.
The focused OwnershipShippedSpec, ProviderAliasSpec, ProviderBackendSpec, AuthoritySpec,
DocValidatorSpec and RawFilePathAsShippedAuthority.hs selection passes all 531 cases on each
host: Linux at 03:57:27.989407 to 03:57:59.348857 UTC (31.359450 wall seconds;
32.51 reported seconds), Windows at 03:57:27.989327 to 03:58:45.114342 UTC
(77.125012 wall seconds; 76.88 reported seconds), both exit 0/empty stderr.
The selection includes the real empty-context child transaction on the actual host's kernel row;
platform capability refusals stay explicit.

The production delta is 75 added/38 removed nonempty lines in Ownership/Shipped.hs and
21 added/20 removed in Provider/Alias.hs, 154 changed lines across two modules.
The other production modules and all 697 existing compile-fail fixtures are byte-preserved;
one new compile-fail fixture is registered. All 1161 source/build/document files match the
synchronized source snapshot before and after these runs.

All four host-static commands then passed on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3:

- `cabal test all` from `core/`: 2026-11-05T03:59:36.918886+00:00 to 2026-11-05T04:08:23.565340+00:00;
  526.646451 wall seconds; 4319 cases/504.34 reported seconds; exit 0.
- `cabal test all` from `demo/`: 2026-11-05T03:59:36.935047+00:00 to 2026-11-05T04:08:21.223498+00:00;
  524.288452 wall seconds; 167 demo cases/1.99 reported seconds and 4319 core cases/504.41 reported seconds; exit 0.
- `poetry run python -m hostbootstrap.check_code`: 2026-11-05T03:59:36.918991+00:00 to 2026-11-05T03:59:37.723881+00:00;
  0.804892 wall seconds; ruff, black and mypy pass; exit 0.
- `poetry run python -m hostbootstrap.test_all`: 2026-11-05T03:59:36.949822+00:00 to 2026-11-05T03:59:43.906869+00:00;
  6.957035 wall seconds; 376 cases/6.16 reported seconds; 100% coverage (1585 statements/460 branches); exit 0.

Every command verified all 1161 source/build/document files before and after execution in both
source trees. The ordinary provider-live component compiles and reports Unsupported without
confirmation; this sprint claims no additional live lifecycle evidence. Sprint 15.50 owns that
confirmation of the completed phase tree. Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25a: The shipped object target path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Give the object target its own opaque path role, distinct from the authority that owns its record.

#### Deliverables

- The transaction's target is a private-constructor type with a producer admitting only a nonempty absolute path in the addressed frame's grammar, Unicode scalar text and no NUL. It cannot stand in for the authority-path type.
- The abstract transaction producer, decoder and guest alias producer carry that role without unchecked conversions. The receiving host rejects its wrong-frame grammar before any store or object effect.
- Guest addressing stays POSIX; the empty-context real child retains host-native addressing on every gate host.

#### Validation

OwnershipShippedSpec covers empty, relative, NUL and surrogate target inputs and malformed target wires, plus the retained codec round-trips and real empty-context transactions. - a compile-fail fixture under `test/compile-fail/` registered in `CompileFailSpec` that passes a target path
  where the authority root is expected and is rejected;

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The object-target role and its retained clients are implemented on 2026-11-05. The authority
and object-target producers share one scalar/NUL/absolute-path admission function, and the receiver
checks both paths against its host grammar before opening the store. The alias spec retains its
admitted object path. Four target cases and TransposeShippedAuthorityTarget.hs are added;
compilation, focused checks and all four host-static commands pass.
The wire format is unchanged.

On 2026-11-05, `cabal build all --enable-tests` from `core/` passes with the unchanged
-Werror policy on native Linux at 04:15:56.949258 to 04:16:04.078695 UTC
(7.129437 wall seconds) and on Windows at 04:15:56.949180 to 04:16:05.104394 UTC
(8.155210 wall seconds), both exit 0/empty stderr with source frozen exactly.
The authority wrong-frame case now uses an actual native object target, so another invalid role
cannot satisfy its expected refusal.

The focused OwnershipShippedSpec, ProviderAliasSpec, ProviderBackendSpec, AuthoritySpec,
DocValidatorSpec, RawFilePathAsShippedAuthority.hs and TransposeShippedAuthorityTarget.hs
selection passes all 536 cases on each host: Linux at 04:16:24.309942 to 04:16:55.501514 UTC
(31.191569 wall seconds; 32.34 reported seconds), Windows at 04:16:24.310028 to
04:17:39.641348 UTC (75.331319 wall seconds; 75.09 reported seconds).
Both exit 0/empty stderr and preserve the source snapshot. The new fixture fails for its exact
authority/target type mismatch. The real empty-context child transactions still run on each
host's own kernel row.

The production delta is 35 added/16 removed nonempty lines in Ownership/Shipped.hs and
7 added/3 removed in Provider/Alias.hs, 61 changed lines across two modules. The other production modules and all 698 existing compile-fail
fixtures are byte-preserved; one transposition fixture is added. All 1162 source/build/document
files match before and after these runs.

All four host-static commands then passed on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3:

- `cabal test all` from `core/`: 2026-11-05T04:19:08.442643+00:00 to 2026-11-05T04:28:08.746839+00:00;
  540.304191 wall seconds; 4324 cases/518.40 reported seconds; exit 0.
- `cabal test all` from `demo/`: 2026-11-05T04:19:08.442926+00:00 to 2026-11-05T04:28:06.816944+00:00;
  538.374020 wall seconds; 167 demo cases/1.85 reported seconds and 4324 core cases/519.52 reported seconds; exit 0.
- `poetry run python -m hostbootstrap.check_code`: 2026-11-05T04:19:08.458985+00:00 to 2026-11-05T04:19:09.250759+00:00;
  0.791770 wall seconds; ruff, black and mypy pass; exit 0.
- `poetry run python -m hostbootstrap.test_all`: 2026-11-05T04:19:08.473984+00:00 to 2026-11-05T04:19:15.505917+00:00;
  7.031937 wall seconds; 376 cases/6.12 reported seconds; 100% coverage (1585 statements/460 branches); exit 0.

Every command verified all 1161 source/build/document files before and after execution in both
source trees. The ordinary provider-live component compiles and reports Unsupported without
confirmation; this sprint claims no additional live lifecycle evidence. Sprint 15.50 owns that
confirmation of the completed phase tree. Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25b: The shipped symbolic-link target path [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Keep a symbolic link's target distinct from both the object being owned and the authority store.

#### Deliverables

- ShipTakeSymbolicLink and ShipGiveBackSymbolicLink require a third private-constructor path type. Its producer refuses empty, relative, NUL and non-scalar text and admits only absolute paths in the addressed frame's grammar.
- The transaction decoder validates this role, the alias spec retains its admitted value, and encoding preserves UTF-8 scalar text without replacement.
- The three role types cannot be transposed; the six existing acts and wire framing stay otherwise unchanged.

#### Validation

OwnershipShippedSpec applies all six acts to real codec values and refuses empty/relative link-target wires and surrogate producer inputs. Registered compile-fail fixtures reject authority/object/link-target transposition. ProviderAliasSpec and ProviderBackendSpec keep their real-kernel symbolic-link cases, including the Windows Unsupported row.

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The symbolic-link target role and retained clients are implemented on 2026-11-05. Its producer
uses the shared scalar/NUL/absolute-path admission, and both link acts check their receiving-host
grammar before opening the store. The alias spec retains the admitted destination for prepared
acquisition and release; the codec uses one admitted-path reader for all three roles.
Four producer/codec/kernel cases are added. The positive case compares each link tag and UTF-8
field with an independently built wire. TransposeShippedObjectLinkTarget.hs and
TransposeShippedAuthorityLinkTarget.hs complete the three role-pair compile-fail boundaries.
The production delta is 36 added/16 removed nonempty lines in Ownership/Shipped.hs,
12 added/5 removed in Provider/Alias.hs and 3 added/2 removed in the demo Commands module:
74 changed lines across three modules.
The other production modules and all 699 existing compile-fail fixtures are byte-preserved.
Compilation and focused checks pass; the complete corrected-source gate is recorded below.

On 2026-11-05, `cabal build all --enable-tests` from `core/` passes with the unchanged
-Werror policy on native Linux at 04:36:10.464528 to 04:37:32.668211 UTC
(82.203683 wall seconds) and on Windows at 04:36:10.464433 to 04:37:01.285825 UTC
(50.821389 wall seconds), both exit 0/empty stderr with source frozen exactly.
The OwnershipShippedSpec, ProviderAliasSpec, ProviderBackendSpec, AuthoritySpec, DocValidatorSpec,
RawFilePathAsShippedAuthority.hs and all TransposeShipped fixtures selection passes all
542 cases on each host: Linux at 04:37:58.990291 to 04:38:30.755806 UTC
(31.765515 wall seconds; 32.97 reported seconds), Windows at 04:37:42.926577 to
04:38:52.787822 UTC (69.861239 wall seconds; 69.63 reported seconds).
Both exit 0/empty stderr. The compile-fail cases pin each pair's exact named type mismatch,
and the two symbolic-link acts retain their exact tag/UTF-8 bytes against independent wires.
All 1164 source/build/document files match before and after the builds and focused runs.

The first full static attempt passed the Python checks (376 cases/100% coverage) and the core's
4330 cases, but the demo command exited 1 at compilation: its two compatibility calls still supplied
raw FilePath values to the symbolic-link acts. The failed demo invocation ran from
2026-11-05T04:42:06.644342+00:00 to 04:50:56.053789+00:00 (529.409446 wall seconds);
its embedded 4330-case core suite passed, which does not make the whole command pass.
The two demo calls now use the alias spec's public, admitted guestAliasLinkTarget view, and the
sealed export inventory includes that view. The earlier core-only build/focus evidence above
precedes this consumer correction. That correction re-owed compilation and the complete four-command gate.

After the consumer correction, `cabal build all --enable-tests` passes on 2026-11-05:

- native Linux core: 04:55:34.202725 to 04:56:54.852279 UTC, 80.649557 wall seconds;
- native Linux demo: 04:55:34.202648 to 04:56:26.282277 UTC, 52.079629 wall seconds;
- Windows core: 04:55:34.202552 to 04:56:23.026022 UTC, 48.823469 wall seconds.

All three builds exit 0/empty stderr under the unchanged -Werror policy and preserve the
source snapshot. The corrected demo binary then passes all 167 cases at 04:56:59.925289 to
04:57:01.948909 UTC (2.023617 wall seconds; 1.86 reported seconds), exit 0; its stderr contains
the suite's expected negative-fixture diagnostics. The core boundary selection again passes all
542 cases on native Linux at 04:57:32.548892 to 04:58:04.671131 UTC
(32.122235 wall seconds; 33.39 reported seconds) and Windows at 04:56:59.925342 to
04:58:17.314111 UTC (77.388770 wall seconds; 77.15 reported seconds), both exit 0/empty stderr.
All 1164 source/build/document files remain exact. The complete four-command gate passes
on the corrected source, as recorded below.

The complete corrected-source host-static gate then passed on 2026-11-05 in the dedicated
hostbootstrap-linux WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000),
with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3:

- `cabal test all` from `core/`: 2026-11-05T04:59:30.300011+00:00 to 2026-11-05T05:08:09.578153+00:00;
  519.278141 wall seconds; 4330 cases/499.26 reported seconds; exit 0.
- `cabal test all` from `demo/`: 2026-11-05T04:59:30.300122+00:00 to 2026-11-05T05:07:48.271700+00:00;
  497.971579 wall seconds; 167 demo cases/1.93 reported seconds and 4330 core cases/501.76 reported seconds; exit 0.
- `poetry run python -m hostbootstrap.check_code`: 2026-11-05T04:59:30.314696+00:00 to 2026-11-05T04:59:31.060729+00:00;
  0.746032 wall seconds; ruff, black and mypy pass; exit 0.
- `poetry run python -m hostbootstrap.test_all`: 2026-11-05T04:59:30.314879+00:00 to 2026-11-05T04:59:37.292792+00:00;
  6.977910 wall seconds; 376 cases/6.29 reported seconds; 100% coverage (1585 statements/460 branches); exit 0.

Every command verifies all 1164 source/build/document files before and after execution against
both source trees. The package's common warning policy holds -Werror. The ordinary provider-live
component compiles and reports Unsupported without confirmation; Sprint 15.50 owns the final
confirmed lifecycle gate for the finished phase. Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25c: The shipped crossing failure value [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Preserve whether a transaction failed to cross, returned an undecodable outcome, or was refused by its frame.

#### Deliverables

- shipOwnedTransaction returns one closed failure sum with distinct crossing, undecodable-outcome and frame-refusal cases; its Haddock describes those values.
- The pure outcome classifier is exercised with values, including undecodable bytes, without an injected transport.
- The alias mapping marks only the frame's own OwnershipMalformed refusal DoNotRetry; transport and decode failures retain their own recovery meaning.

#### Validation

- `shipOwnedTransaction` over a context whose crossing cannot be made (a one-layer Incus context with a
  `HostConfig` that resolves no `incus`) returns the crossing-failure value, and an
  answer the near side cannot decode returns the undecodable-outcome value, each distinct from a frame
  refusal;
- `HandoffSpec` adds a separate local ownership crossing that decodes the actual answer with
  `decodeShippedOutcome` and asserts `ShippedRefused (OwnershipMalformed _)`. Its existing
  cluster-exposure protocol refusal case stays unchanged;

The pure classifier distinguishes an undecodable answer from a frame refusal. Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The closed ShippedFailure sum, pure classifyShippedOutcome and both alias mappings are implemented
on 2026-11-05. The transport module continues to carry opaque bytes without an ownership dependency.
The shared shippedAliasFailureRecovery decision makes only a decoded frame OwnershipMalformed
permanent; unreadable responses, crossing failures and inapplicable decoded outcomes require reprobe.

Seven concrete cases are added:

- OwnershipShippedSpec: "a transport diagnostic retains its crossing stage";
- OwnershipShippedSpec: "an unreadable outcome stays distinct from a decoded malformed-input refusal";
- OwnershipShippedSpec: "every decoded successful outcome retains its exact value";
- OwnershipShippedSpec: "every frame refusal retains its exact ownership fault";
- OwnershipShippedSpec: "a frame with no configured host tool returns a crossing failure";
- ProviderAliasSpec: "only the frame's decoded malformed-input refusal is permanent";
- HandoffSpec: "a local ownership crossing returns a decoded malformed-input refusal".

The classifier and recovery cases apply real pure functions to values. The missing-tool case
calls the production transport over a one-layer Incus context with no admitted host tool.
The new handoff case crosses a real local process boundary and reads the actual ownership
interpreter's encoded refusal; the older cluster-exposure refusal case is preserved.
The retained empty-context ownership case now matches ShippedFrameRefused (OwnershipOccupied _).

The production delta is 27 added/18 removed nonempty lines in Ownership/Shipped.hs and
54 added/39 removed in Provider/Alias.hs: 138 changed lines across two modules.
The other production modules and all 701 existing compile-fail fixtures are byte-preserved.
Compilation, focused checks and all four host-static commands pass.

On 2026-11-05, `cabal build all --enable-tests` passes under the unchanged -Werror policy:

- native Linux core, from `core/`: 05:22:59.303734 to 05:25:18.763638 UTC,
  139.459905 wall seconds;
- native Linux demo, from `demo/`: 05:22:59.303576 to 05:24:21.912950 UTC,
  82.609375 wall seconds;
- Windows core, from `core/`: 05:22:59.303455 to 05:24:26.493968 UTC,
  87.190512 wall seconds.

All three exit 0/empty stderr with the source snapshot exact. The focused ownership, alias,
backend, authority, documentation, path-role compile-fail and new local ownership crossing
selection passes all 549 cases on native Linux at 05:25:47.528515 to 05:26:18.916671 UTC
(31.388153 wall seconds; 32.65 reported seconds) and Windows at 05:25:15.243253 to
05:26:32.500161 UTC (77.256913 wall seconds; 76.99 reported seconds).
Both exit 0/empty stderr. The demo binary separately passes all 167 cases at
05:25:15.243154 to 05:25:17.324354 UTC (2.081197 wall seconds; 1.93 reported seconds),
exit 0 with the expected negative-fixture stderr. Every run preserves all 1164 synchronized
source/build/document files before and after execution.

The complete host-static gate then passed on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3:

- `cabal test all` from `core/`: 2026-11-05T05:27:31.984004+00:00 to 2026-11-05T05:36:05.489870+00:00;
  513.505868 wall seconds; 4337 cases/494.16 reported seconds; exit 0.
- `cabal test all` from `demo/`: 2026-11-05T05:27:31.983942+00:00 to 2026-11-05T05:35:41.919632+00:00;
  489.935687 wall seconds; 167 demo cases/1.91 reported seconds and 4337 core cases/495.00 reported seconds; exit 0.
- `poetry run python -m hostbootstrap.check_code`: 2026-11-05T05:27:31.988200+00:00 to 2026-11-05T05:27:33.178658+00:00;
  1.190455 wall seconds; ruff, black and mypy pass; exit 0.
- `poetry run python -m hostbootstrap.test_all`: 2026-11-05T05:27:31.989656+00:00 to 2026-11-05T05:27:39.437789+00:00;
  7.448136 wall seconds; 376 cases/6.32 reported seconds; 100% coverage (1585 statements/460 branches); exit 0.

All four commands verify all 1164 source/build/document files before and after execution in
both source trees. The common warning policy holds -Werror. The ordinary provider-live component
compiles and reports Unsupported without confirmation; Sprint 15.50 owns the finished phase's
confirmed lifecycle gate. Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25d: The shipped take re-observes its bound object [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Answer an exact retry only for the same kind, file payload and currently bound object.

#### Deliverables

- A stored record's originRecordKind must match the requested directory/file act, including a file's payload digest.
- The stored origin is absent; a record of an already-present object cannot grant a take.
- A bound record is re-observed before returning ShippedObjectTaken; a vanished or replaced target refuses rather than producing stale authority.
- A refused retry leaves the existing object and stored ownership intact.

#### Validation

The six real-store/native-row cases in OwnershipShippedSpec.hs are:

- "an exact file retry preserves its payload, identity and record";
- "a changed file payload refuses without changing the owned file or record";
- "a directory take refuses a file record without changing the file";
- "a vanished bound directory refuses retry and preserves its record";
- "a replaced bound directory refuses retry and leaves the replacement intact";
- "a bound record with a present origin cannot adopt the existing directory".

The refused mismatches assert OwnershipMalformed and preserve payload, identity and record.
The missing and replacement cases assert the exact conflict subject, expected identity and
observed origin; they preserve the exact record and version and the replacement's sentinel. The invalid-origin
case plants a real protected record through compareAndSwapProtectedRecord.
The retained exact directory retry remains in the suite. OwnershipSpec.hs's
"shipped give-back retains stored origin evidence" retains the literal give-back tape read
and counts the two sealed read sites and their import.

takeObject reads readStoredRecordUnder, checks kind/payload and absent origin, then re-enters
the sealed stored record and calls reobserveOwnedIdentity before answering Taken. The
unbound-record resolution is the next sprint's contract. The production delta is 24 added
and 9 removed nonempty lines in Ownership/Shipped.hs: 33 changed lines in one module.
All other production modules and the 701 existing compile-fail fixtures are byte-preserved.
Compilation, the expanded focused selection and the complete host-static gate pass.

On 2026-11-05, the three `cabal build all --enable-tests` preflights pass under -Werror.
The focused selection covers OwnershipShippedSpec, ProviderAliasSpec, ProviderBackendSpec,
AuthoritySpec, DocValidatorSpec, the shipped-path compile-fail cases and the local ownership
crossing. Each run exits 0 and verifies all 1164 source/build/document files before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T05:52:08.310316+00:00 | 2026-11-05T05:52:18.754101+00:00 | 10.443787 |
| Linux demo build | 2026-11-05T05:52:08.309810+00:00 | 2026-11-05T05:52:16.374283+00:00 | 8.064470 |
| Windows core build | 2026-11-05T05:52:08.310075+00:00 | 2026-11-05T05:52:19.199041+00:00 | 10.888964 |
| Linux focused: 555 cases | 2026-11-05T05:52:33.576081+00:00 | 2026-11-05T05:53:05.178111+00:00 | 31.602026 |
| Windows focused: 555 cases | 2026-11-05T05:52:33.576202+00:00 | 2026-11-05T05:53:46.853081+00:00 | 73.276876 |
| Linux demo: 167 cases | 2026-11-05T05:52:33.547734+00:00 | 2026-11-05T05:52:35.674929+00:00 | 2.127192 |

The initial preflight diagnosed the test helper's raw-byte declaration for a protected record.
The validated helper compares the complete ProtectedRecord, including its version.
The successful builds and focused runs have empty stderr, except for the demo's expected
negative-fixture diagnostics. The first complete core and demo commands exit 1: each reports one failure among 4343 cases,
OwnershipSpec.hs's "shipped give-back retains stored origin evidence" (expected two occurrences
of readStoredRecordUnder, observed three). The additional occurrence is the take retry's
sealed read. The guard counts both read sites and the import and independently pins the
literal give-back read. The six behavioural cases pass in those initial full runs. The successful updated-guard
runs are recorded below.

On 2026-11-05 the updated guard compiles in both Linux workspaces and on Windows.
The expanded selection includes the named OwnershipSpec guard; all 556 cases pass on each host.
These runs exit 0/empty stderr and preserve all 1164 source/build/document files.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T06:04:36.046950+00:00 | 2026-11-05T06:05:26.526502+00:00 | 50.479549 |
| Linux demo build | 2026-11-05T06:04:36.047872+00:00 | 2026-11-05T06:05:03.046940+00:00 | 26.999068 |
| Windows core build | 2026-11-05T06:04:36.047774+00:00 | 2026-11-05T06:04:49.422395+00:00 | 13.374622 |
| Linux focused: 556 cases | 2026-11-05T06:05:44.335800+00:00 | 2026-11-05T06:06:15.881168+00:00 | 31.545363 |
| Windows focused: 556 cases | 2026-11-05T06:05:26.898472+00:00 | 2026-11-05T06:06:43.506350+00:00 | 76.607876 |

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T06:07:17.166849+00:00 | 2026-11-05T06:15:53.348313+00:00 | 516.181452 | 4343 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T06:07:17.166658+00:00 | 2026-11-05T06:15:29.323071+00:00 | 492.156410 | 167 demo cases and 4343 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T06:07:17.167020+00:00 | 2026-11-05T06:07:17.967231+00:00 | 0.800217 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T06:07:17.194773+00:00 | 2026-11-05T06:07:24.181836+00:00 | 6.987063 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1164 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25e: The shipped unbound directory record resumes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Resolve an interrupted directory take without wedging its ownership key or adopting an unrelated object.

#### Deliverables

- Under the protected entry, an unbound absent-origin directory record with an absent target resumes the take.
- An unbound record with a present target refuses as OwnershipConflict with a recovery message.
- ShipTakeDirectory and ShipGiveBackObject use the same absent/present resolution, preserving the object on refusal; absent give-back forgets the record.

#### Validation

OwnershipShippedSpec.hs exercises the production row and protected store in four named cases:

- "an unbound absent directory record resumes the take";
- "an unbound present directory record refuses the take";
- "an unbound absent directory record settles give-back";
- "an unbound present directory record refuses give-back".

Each case plants the unbound OriginRecord through compareAndSwapProtectedRecord.
The resumed take gains a binding, retains it on exact retry and conditionally gives it back.
The absent give-back forgets the record, is idempotent, and permits a fresh take under the same key.
Both present cases assert the exact OwnershipConflict, recovery guidance, expected absent origin
and observed identity, and preserve the directory's identity, sentinel and full protected
record/version. The retained stored-evidence source guard in OwnershipSpec.hs is also selected.

The private shared resolver observes through enterOwnedObject under the protected entry.
An absent take reuses createUnder and the tape's idempotent exact unbound publication;
an absent give-back durably forgets its record. A present object grants neither act authority.
The production delta is 53 added/16 removed nonempty lines in Ownership/Shipped.hs:
69 changed lines in one module. All other production modules and the 701 existing compile-fail
fixtures are byte-preserved. Compilation, focused checks and the complete static gate pass.

On 2026-11-05, `cabal build all --enable-tests` passes under -Werror in both Linux
workspaces and Windows core. The focused selection covers ownership, alias, backend,
authority, documentation, path-role compile-fail and local ownership crossing cases,
including OwnershipSpec's stored-evidence guard. All 560 cases pass on each host.
Each run exits 0 and verifies all 1164 source/build/document files before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T06:18:54.646520+00:00 | 2026-11-05T06:20:26.615555+00:00 | 91.969031 |
| Linux demo build | 2026-11-05T06:18:54.647986+00:00 | 2026-11-05T06:19:56.455498+00:00 | 61.807514 |
| Windows core build | 2026-11-05T06:18:54.648278+00:00 | 2026-11-05T06:19:57.624188+00:00 | 62.975914 |
| Linux focused: 560 cases | 2026-11-05T06:20:34.424208+00:00 | 2026-11-05T06:21:05.794986+00:00 | 31.370773 |
| Windows focused: 560 cases | 2026-11-05T06:20:13.969272+00:00 | 2026-11-05T06:21:31.766429+00:00 | 77.797154 |
| Linux demo: 167 cases | 2026-11-05T06:20:13.974451+00:00 | 2026-11-05T06:20:16.149638+00:00 | 2.175185 |

The builds and focused runs have empty stderr, except for the demo's expected
negative-fixture diagnostics. The complete host-static gate is recorded below.

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T06:22:16.340710+00:00 | 2026-11-05T06:30:53.760007+00:00 | 517.419297 | 4347 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T06:22:16.340555+00:00 | 2026-11-05T06:30:31.106031+00:00 | 494.765474 | 167 demo cases and 4347 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T06:22:16.350203+00:00 | 2026-11-05T06:22:17.112026+00:00 | 0.761820 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T06:22:16.361051+00:00 | 2026-11-05T06:22:23.353485+00:00 | 6.992434 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1164 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25f: The ownership column declares its row [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Frame.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Keep the ownership column descriptive rather than a second decision to ship or run.

#### Deliverables

- The public ownership column describes its row without offering a second routing decision.
- The frameOwnershipRow Haddock states that this is a declaration no production module consults; it mints no ship-or-run authority.
- The retained column cases apply the total row table to host and crossing values; a source guard holds the routing-helper absence.

#### Validation

OwnershipShippedSpec.hs retains these pure table cases:

- "the outer host's clauses are held by this binary's own row";
- "every crossing's clauses are held by the POSIX row";
- "a nested crossing is still a crossing".

Its "the ownership column offers no second routing decision" reads the actual Frame.hs and
guards the absent public helper. The guard names the rationale's "VM crossings share one
placement renderer" entry. The source search across core source, internal libraries,
provider-live and demo source finds the descriptive column only in its declaring module.
The matching deletion-ledger row is absent.

Frame.hs's production delta is 2 added/8 removed nonempty lines: 10 changed lines in one
module. Other production modules and all 701 existing compile-fail fixtures are byte-preserved.
The retained three table cases remain; the added source guard increases the suite by one.
Compilation, focused checks and all four host-static commands pass.

On 2026-11-05, `cabal build all --enable-tests` passes under -Werror in both Linux
workspaces and Windows core. The focused ownership, alias, backend, authority, documentation,
path-role compile-fail, local ownership crossing and stored-evidence guard selection passes
all 561 cases on each host. Every run exits 0 and verifies all 1164 source/build/document files
before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T06:33:28.249856+00:00 | 2026-11-05T06:34:20.218075+00:00 | 51.968217 |
| Linux demo build | 2026-11-05T06:33:28.251076+00:00 | 2026-11-05T06:33:52.612484+00:00 | 24.361409 |
| Windows core build | 2026-11-05T06:33:28.282155+00:00 | 2026-11-05T06:33:44.553648+00:00 | 16.271492 |
| Linux focused: 561 cases | 2026-11-05T06:34:46.998747+00:00 | 2026-11-05T06:35:18.276058+00:00 | 31.277307 |
| Windows focused: 561 cases | 2026-11-05T06:34:29.201928+00:00 | 2026-11-05T06:35:47.001086+00:00 | 77.799155 |
| Linux demo: 167 cases | 2026-11-05T06:34:29.201994+00:00 | 2026-11-05T06:34:31.236074+00:00 | 2.034080 |

The builds and focused runs have empty stderr, except for the demo's expected
negative-fixture diagnostics. The complete host-static gate is recorded below.

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T06:36:32.628869+00:00 | 2026-11-05T06:45:11.624912+00:00 | 518.996044 | 4348 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T06:36:32.628731+00:00 | 2026-11-05T06:44:45.942354+00:00 | 493.313623 | 167 demo cases and 4348 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T06:36:32.628662+00:00 | 2026-11-05T06:36:33.407275+00:00 | 0.778611 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T06:36:32.638784+00:00 | 2026-11-05T06:36:39.527383+00:00 | 6.888601 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1164 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25g: The test child uses the production frame routing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Make real crossing cases exercise the routing the shipped project binary performs.

#### Deliverables

- HostBootstrap.CLI exports interpretFrameTransaction, shared by the production and suite child entries.
- test/Spec.hs imports that dispatcher and contains no direct owner-interpreter routing; a source guard holds that boundary.
- The OwnershipShippedSpec header calls the child the production route only to the extent that route is shared.

#### Validation

OwnershipShippedSpec.hs's "the crossing child uses the production frame transaction dispatcher"
reads the actual test/Spec.hs, checks its CLI dispatcher import and use, and guards the absence
of direct ownership and cluster-exposure interpreter calls. The guard names the rationale's
"Frame transactions share their production dispatcher" entry.

Its retained "an empty context runs the transaction in a real child process" and
"a frame's refusal crosses back as a refusal, not as a broken exchange" exercise the shared
route across an actual process boundary. HandoffSpec's "a local ownership crossing returns a
decoded malformed-input refusal" exercises that route's encoded rejection too.
The process-group fixture wrapper remains only around its existing probe; it delegates
ordinary transaction bytes to the production dispatcher.

The production delta is 5 added/0 removed nonempty lines in CLI.hs: 5 changed lines in one
module. The dispatcher definition is byte-preserved. The reviewed export inventory includes
the shared dispatcher, the matching deletion-ledger row is absent, and the suite header
describes only the production route it actually shares. All other production modules and the
701 existing compile-fail fixtures are byte-preserved.
Compilation, focused crossing checks and all four host-static commands pass.

On 2026-11-05, `cabal build all --enable-tests` passes under -Werror in both Linux
workspaces and Windows core. The focused ownership, alias, backend, authority, documentation,
path-role compile-fail, local ownership crossing and stored-evidence selection passes all
562 cases on each host. Every run exits 0 and verifies all 1164 source/build/document files
before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T06:49:03.331911+00:00 | 2026-11-05T06:50:32.025176+00:00 | 88.693266 |
| Linux demo build | 2026-11-05T06:49:03.332132+00:00 | 2026-11-05T06:50:04.020605+00:00 | 60.688473 |
| Windows core build | 2026-11-05T06:49:03.331832+00:00 | 2026-11-05T06:50:03.176336+00:00 | 59.844501 |
| Linux focused: 562 cases | 2026-11-05T06:51:03.315060+00:00 | 2026-11-05T06:51:34.816791+00:00 | 31.501729 |
| Windows focused: 562 cases | 2026-11-05T06:50:46.229984+00:00 | 2026-11-05T06:52:04.085651+00:00 | 77.855665 |
| Linux demo: 167 cases | 2026-11-05T06:50:46.230072+00:00 | 2026-11-05T06:50:48.300191+00:00 | 2.070119 |

The builds and focused runs have empty stderr, except for the demo's expected
negative-fixture diagnostics. The complete host-static gate is recorded below.

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T06:53:18.459011+00:00 | 2026-11-05T07:01:55.512094+00:00 | 517.053080 | 4349 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T06:53:18.459084+00:00 | 2026-11-05T07:01:32.636658+00:00 | 494.177574 | 167 demo cases and 4349 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T06:53:18.465988+00:00 | 2026-11-05T06:53:19.248261+00:00 | 0.782272 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T06:53:18.483234+00:00 | 2026-11-05T06:53:25.456502+00:00 | 6.973265 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1164 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.25h: The shipped row proves its exact refusals [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Make the existing kernel and codec cases fail for the concrete residue, refusal and identity defects they name.

#### Deliverables

- Kernel cases assert exact OwnershipOccupied and OwnershipConflict constructors, subjects and expected identities, then retry after removing an operator's object to detect a leaked record.
- Observation checks doesPathExist; file publication and give-back assert the exact shipped staging path is absent.
- Alias release proves its record is absent and a subsequent take creates a fresh symbolic link.
- Malformed wires cover every sized-field ceiling, invalid UTF-8, invalid origin tags, invalid identity widths and invalid path roles.
- The field-ceiling Haddock states one 4 MiB getSized limit for every field, paths included, and that the encoder does not enforce it. The directory case proves its identity binding and stored record; exclusion and parent-sync proofs stay with their owning row cases.

#### Validation

OwnershipShippedSpec.hs adds one real store-open case and seven pure codec cases:

- "an authority beneath a regular file refuses at store open";
- "every transaction field enforces the same 4 MiB ceiling";
- "transaction text rejects invalid UTF-8 while file payloads remain bytes";
- "the decoder admits 4 MiB payloads and the encoder preserves wider payloads";
- "every outcome field enforces the same 4 MiB ceiling";
- "every refusal text field rejects invalid UTF-8";
- "both conflict origins reject an unknown origin tag";
- "every identity position refuses zero and 65 bytes".

The width cases hand-build 0x00400001 prefixes at all six transaction and twelve outcome
field positions, pinning each exact ceiling diagnostic so truncation cannot satisfy the case.
The text cases cover all five transaction text sites and six fault text fields. The identity
case covers four answer tags and both conflict origins at both invalid widths. The origin-tag
case covers both conflict origins. The exact 4 MiB file payload decodes, its wider form is
encoded completely and refused by the decoder, and arbitrary binary payload bytes survive.

The retained admitted-path cases name "unchecked authority wire fields are refused as malformed",
"unchecked object target wire fields are refused as malformed" and
"both symbolic-link acts refuse unchecked target wire fields"; they cover empty,
relative and NUL paths and both symbolic-link acts. The retained codec round-trips pin each
success and closed refusal constructor.

The strengthened real-kernel cases are:

- "an absent object is reported absent, and nothing is created": doesPathExist checks the
  target and exact shipped stage; the protected record is absent;
- "a directory is taken, bound to its identity, and given back": the observed identity and
  parsed protected record agree on kind, absent origin and binding, and release forgets it;
- "a file is published with its payload, and given back": the exact staging path is absent
  after publication and after release, and its record is forgotten;
- "an object already there is refused, and nothing is recorded": exact OwnershipOccupied,
  preserved operator bytes, no record, and a successful same-key take after removing that file;
- "a replaced object is refused, and left intact": exact conflict subject, expected owned
  identity and observed replacement, plus unchanged identity, sentinel and record/version;
- "a replacement symbolic link is refused on release and left intact": the same exact
  conflict fields and record preservation. Renaming the original link retains its inode so
  the foreign replacement has a distinct identity.

ProviderAliasSpec.hs's "create, exact retry, and release use one durable identity" asserts
assertRecordPresent False after give-back and then ShippedSymbolicLinkCreated on a new take,
with the record present again. It does not demand distinct identity bytes from a freed inode.

The store-open case matches OwnershipProbeFailed for the exact open operation, retains its
diagnostic, and preserves the obstructing file while leaving target and stage absent.
The production delta is 4 added/4 removed nonempty comment lines in Ownership/Shipped.hs:
8 changed lines in one module. The executable body is unchanged. Other production modules
and all 701 existing compile-fail fixtures are byte-preserved.
Compilation, focused checks and all four host-static commands pass.

On 2026-11-05, `cabal build all --enable-tests` passes under -Werror in both Linux
workspaces and Windows core. The focused ownership, alias, backend, authority, documentation,
path-role compile-fail, local ownership crossing and stored-evidence selection passes all
570 cases on each host. Every run exits 0 and verifies all 1164 source/build/document files
before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T07:09:42.709294+00:00 | 2026-11-05T07:10:33.819279+00:00 | 51.109984 |
| Linux demo build | 2026-11-05T07:09:42.709233+00:00 | 2026-11-05T07:10:10.023929+00:00 | 27.314694 |
| Windows core build | 2026-11-05T07:09:42.709072+00:00 | 2026-11-05T07:09:57.183120+00:00 | 14.474042 |
| Linux focused: 570 cases | 2026-11-05T07:11:38.358655+00:00 | 2026-11-05T07:12:11.706847+00:00 | 33.348193 |
| Windows focused: 570 cases | 2026-11-05T07:11:38.358725+00:00 | 2026-11-05T07:12:58.087795+00:00 | 79.729069 |
| Linux demo: 167 cases | 2026-11-05T07:11:38.358596+00:00 | 2026-11-05T07:11:40.427474+00:00 | 2.068874 |

The builds and focused runs have empty stderr, except for the demo's expected
negative-fixture diagnostics. The complete host-static gate is recorded below.

Closure uses all four host-static commands of § JJ, with the named cases in the unfiltered core suite.

The first complete demo command on 2026-11-05 exits 1 at 07:21:24.884364 UTC
after 447.387797 wall seconds: its 167 demo cases pass, while 94 of 4357 core cases
refuse the same generated build-information freshness check. The component's build-info.json
mtime is 07:14:12.743458 UTC and setup-config is 07:14:14.143907 UTC.
The separate core command passes all 4357 cases on the same source.

Cabal regenerates the actual metadata through `cabal build all --enable-tests` from
`demo/` at 07:27:15.487251 to 07:27:33.603548 UTC (18.116297 wall seconds), exit 0.
Its build information is then newer than setup-config. The previously failing "the native
no-replace link preserves a taken destination" case passes through the demo workspace's
actual core-test binary at 07:28:19.608519 to 07:28:20.773928 UTC (1.165406 wall seconds),
exit 0/empty stderr. No source or assertion changes during this metadata regeneration or
the subsequent complete demo retry; the successful complete gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T07:13:57.481888+00:00 | 2026-11-05T07:22:37.115510+00:00 | 519.633621 | 4357 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T07:28:27.975856+00:00 | 2026-11-05T07:36:32.849133+00:00 | 484.873264 | 167 demo cases and 4357 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T07:13:57.496748+00:00 | 2026-11-05T07:13:58.671667+00:00 | 1.174920 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T07:13:57.496917+00:00 | 2026-11-05T07:14:05.022203+00:00 | 7.525287 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1164 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.


### Sprint 15.26: The reported observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The seam's second face: the four clauses over an object whose stable identity another authority answers
for.

#### Objective boundary

The seam is the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)'s,
and this sprint extends it rather than restating it. Every owner that phase built keeps the face it
already holds; what is added is the face a provider needs, because the identity of a provider instance is
not a fact any kernel this process can call knows.

#### Deliverables

- The four clause tokens gain a second set of producers, taking the observation as a value instead of
  reading it from a row. The tokens, their order, and their nominal indices are unchanged, so a reported
  transaction is the same transaction run against a different answerer.
- `enterReportedObject` introduces the fresh object index from an `Origin` a total classification produced.
  Clause 1 is still the protected store's exclusive entry and clause 2 still that store's
  compare-and-swap, so neither clause moves.
- `reobserveReportedIdentity` is **pure**: by the time clause 4's precondition is asked both faces have
  already made their observation, so the comparison is a function of two values and every conflict is
  reachable by application (§ NN).
- `releaseReportedObject` forgets the record only over a reported absence. A target still present is a
  conflict, so the order clause 4 requires — object first, record second — is the order the program has
  even when the removal was a described command outside this process.
- Each computation both faces share is written once: the record an origin describes, the binding attached
  to it, and the conflict a release reports. The kernel producers reach them through their own clause
  gate, which is what keeps a row's declaration deciding what that row may hold.
- The reported face names no `OwnershipRow` and reaches no primitive, and that is a property of its
  signatures rather than of a stand-in nobody called.
- The Windows row's direct namespace entry points are exactly the two its primitives call, so the row
  declares no capability it does not reach.

#### Validation

The reported face is exercised by application over values inside a real protected entry: the origin a
record describes is the observation the caller was handed, a durable write that refuses mints no token,
the binding is the identity the authority reported, clause 4 admits exactly the bound identity and reports
an absence and a replacement as distinct conflicts, and a record is forgotten over a reported absence and
never over a surviving object — the second proved by a forget continuation that would end the case if it
ran. Two source guards hold the shape: the reported region names no row primitive, and each shared clause
has exactly one computation both faces reach.

Dated 2026-08-19 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): `OwnershipSpec` passed
20/20, of which seven are this sprint's. Canonical `cabal test all --ghc-options=-Werror` from `core/`
passed 2,085/2,085 in 232.24 seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The face exists and is total; the provider operations that hold their clauses through it are the
sprints that follow.

### Sprint 15.27: The provider report [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Resume.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`,
`core/hostbootstrap-core/test/ProviderResumeSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ConstructEmptyProviderConfigValue.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

One total classification from a provider's own output to the observation a clause is held over.

#### Deliverables

- A closed vocabulary names what a provider reports about an instance: the one listing row that names it,
  the two lifecycle states a clause-holding transaction can act from, and one configuration value. The
  provider prints the same empty line for an unset key and for a key set to the empty string, so both are
  `ProviderConfigUnset`. The nonempty value branch is private, produced by classification and exposed through `providerConfigValueText`.
- A closed sum names why a report is not a value: a command that produced no child, a provider that ran
  and refused, a success that wrote to standard error, and a report outside the shape this vocabulary
  admits. Each renders once.
- Classification is a total function of the interpreter's own outcome, so the report a driver returns and
  the decision a caller makes are the same value rather than a rendering and a parser.
- The instance listing is reduced to the row naming the exact instance before any row's state or arity is
  judged, because the provider matches a listing argument by prefix and a sibling row is not about this
  instance: a sibling in any state or with malformed arity is an absence rather than a refusal. Global
  line and character bounds apply to the report, and a nonblank nameless row refuses. The
  exact name listed twice is a refusal rather than a choice between two disagreeing answers.
- A lifecycle state outside the admitted two is refused rather than mapped onto whichever is closer.
- The identity a report carries is admitted through the seam's own producer, so a value outside the
  identity grammar or past the seam's ceiling is a refusal rather than something a release could compare
  against.
- One function joins a listing and an identity read into the `Origin` the seam's reported face is held
  over, and refuses the two ways a provider can contradict itself.
- Nothing in the module executes anything.

#### Validation

ProviderReportSpec.hs adds these pure value cases:

- "a frozen sibling does not decide the exact instance's state";
- "a malformed sibling row does not decide the exact instance's shape";
- "the exact listing line bound is admitted";
- "one empty line is the same unset answer as no output";
- "the exact configuration value bound is admitted";
- "configuration values refuse Unicode controls and formatting characters";
- "a non-zero exit's rendering retains its numeric code";
- "provider diagnostics remove the report's forbidden characters".

The exact-instance and sibling queries use the same mixed RUNNING/FROZEN report.
A malformed sibling cannot refuse the exact row, and a sibling-only report is absence.
The existing nameless-row, exact duplicate, malformed exact-row, unadmitted-state,
bound-plus-one and carriage-return cases remain. Exact line and value bounds are admitted.
The Unicode case covers U+202E, U+0085, U+200D and U+009F. Diagnostics cover ESC,
C1 and format removal, both exited and noisy-success results, and a sanitized-empty fallback.

The retained "an identity the seam will not admit is a refusal" applies
classifyProviderIdentity to a grammatically valid overlong identity. That case proves the
seam's separate ceiling through the subject under test. Both success joins and both contradictory
listing/identity joins remain. Configuration-value assertions inspect the total text view,
and ProviderResumeSpec's fixtures obtain values through the actual pure report admission.

ConstructEmptyProviderConfigValue.hs is registered as a public compile-fail boundary:
unchecked construction of the private value branch is refused. The reviewed export inventory
permits ProviderConfigUnset and providerConfigValueText while keeping that branch private.

The production delta is 36 added/25 removed nonempty lines in Provider/Report.hs,
7 added/7 removed in Provider/Resume.hs and 3 added/3 removed in Provider/Ownership.hs:
81 changed lines across three modules. The latter two adopt the total config-value view.
All other production modules and the 701 existing compile-fail fixtures are byte-preserved.
Compilation, the actual fixture diagnostic, focused value cases and all four
host-static commands pass.

On 2026-11-05, `cabal build all --enable-tests` passes under -Werror in both Linux
workspaces and Windows core. ConstructEmptyProviderConfigValue.hs fails for the exact named
reason, "Illegal term-level use of the type constructor 'ProviderConfigValue'". The broader
report, resumption, backend, authority, documentation, constructor and provider-claim
stored-evidence selection passes all 529 cases on each host. Every run exits 0 and verifies
all 1165 source/build/document files before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T07:53:35.396162+00:00 | 2026-11-05T07:55:05.085638+00:00 | 89.689476 |
| Linux demo build | 2026-11-05T07:53:35.396081+00:00 | 2026-11-05T07:54:36.629532+00:00 | 61.233448 |
| Windows core build | 2026-11-05T07:53:35.397345+00:00 | 2026-11-05T07:54:33.020963+00:00 | 57.623620 |
| Linux constructor fixture: 1 case | 2026-11-05T07:55:36.407254+00:00 | 2026-11-05T07:55:36.849139+00:00 | 0.441883 |
| Linux focused: 529 cases | 2026-11-05T07:56:36.159577+00:00 | 2026-11-05T07:57:05.914850+00:00 | 29.755270 |
| Windows focused: 529 cases | 2026-11-05T07:56:36.155293+00:00 | 2026-11-05T07:57:50.445079+00:00 | 74.289782 |
| Linux demo: 167 cases | 2026-11-05T07:55:36.407342+00:00 | 2026-11-05T07:55:38.263606+00:00 | 1.856264 |

The builds, constructor case and focused runs have empty stderr, except for the demo's
expected negative-fixture diagnostics. The complete host-static gate is recorded below.

Closure uses all four host-static commands of § JJ, including the named cases and
the public compile-fail boundary in the unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T08:00:14.221464+00:00 | 2026-11-05T08:08:48.962938+00:00 | 514.741470 | 4365 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T08:00:14.221957+00:00 | 2026-11-05T08:08:29.960644+00:00 | 495.738688 | 167 demo cases and 4365 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T08:00:14.221589+00:00 | 2026-11-05T08:00:15.411413+00:00 | 1.189819 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T08:00:14.221773+00:00 | 2026-11-05T08:00:21.609467+00:00 | 7.387705 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.28: The described provider commands [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderCommandSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Every outer-host provider effect as a described `HostCommand`, produced by a function that cannot run it.

#### Objective boundary

Every command this sprint renders is interpreted by a process of the **outer host** — the provider's own
client, run where the binary is running. A vector that *crosses into* the instance is not rendered here:
§ LL admits one crossing renderer and it is the lift's own fold, `foldLeaf` in `HostBootstrap.Lift`, which
the [ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns; the guard that holds that rule across
the repository is Sprint 15.47's. The guard the destructive delete goes through is the frame table's, which
Sprint 15.24 built.

#### Deliverables

- Listing, configuration read, device listing, device read, launch, start, stop, and share attachment are
  each a `HostCommand` value naming the `Incus` host tool, its exact argument vector, its stdio disposition,
  and the frame whose process reads it (§ KK, § MM). The frame table carries no frame-to-tool column, so the
  tool is the module's literal `Incus`, not a table lookup.
- One listing answers presence and lifecycle state together, because a presence answered by one command
  and a state answered by another are two answers that can disagree about the moment they describe.
- The owner tag rides on the creating command rather than on a configuration write that follows it, so
  there is no interval in which the instance exists without naming the record that owns it.
- The destructive delete is rendered through the frame table's one guarded delete, so a name outside the
  project's guard prefix — and each of the two degenerate inputs that make the guard vacuous — has no
  argument vector at all rather than one that is not run.
- The declared sizing is rendered once, so the three quantities reach the provider under one spelling.
- The two configuration keys a clause is held through — the owner tag and the provider's own stable
  identity — are named once each.
- No argument vector is built by a function that also executes it.
- Stop and restart are `--force`, a hard power-off of the VM that skips the guest's clean shutdown, and the
  module documentation says so: a forced stop can lose guest writes that were not flushed, which is why it
  is issued only against the exact owned instance its transaction re-observed.

#### Validation

ProviderCommandSpec.hs retains the pure command-vector cases:

- "start names the instance and stop cannot wait on its guest agent", including
  `["stop", name, "--force"]`;
- "share activation restarts exactly the owned instance", including
  `["restart", name, "--force"]`;
- "every command names the Incus tool", comparing every command with literal ToolTarget Incus;
- "every command is interpreted by a process of the outer host";
- "every command carries the described stdio disposition";
- "no command is empty".

The remaining listing, configuration, launch, share and guarded-delete equality/refusal cases
remain in the same suite. The renamed tool case makes the assertion's actual scope explicit.
No new case or command vector is introduced.

The stop, restart and owned-stop Haddocks state that --force powers off without clean guest
shutdown, can lose unflushed guest writes and is issued by the calling ownership transaction
against its re-observed exact instance. The renderer carries no independent ownership authority.
The module description names literal Incus, and its shared crossing-renderer ownership link
points to the ensure-reconcilers phase. The Incus engineering document retains its forced-power
semantics and states the literal tool and the frame table's shared delete-guard role.

The production delta is 9 added/5 removed nonempty comment lines in Provider/Command.hs and
4 added/4 removed in Provider/Ownership.hs: 22 changed lines across two modules.
Both executable bodies, all other production modules and all 702 existing compile-fail
fixtures are byte-preserved. Compilation, focused command cases and the complete static
gate pass.

On 2026-11-05, `cabal build all --enable-tests` passes under -Werror in both Linux
workspaces and Windows core. The retained 19 described-command cases and 17 documentation
cases pass as one 36-case selection on each host. Every run exits 0/empty stderr and verifies
all 1165 source/build/document files before and after.

| Run | Start UTC | End UTC | Wall seconds |
|---|---|---|---|
| Linux core build | 2026-11-05T08:15:01.353516+00:00 | 2026-11-05T08:15:52.707094+00:00 | 51.353574 |
| Linux demo build | 2026-11-05T08:15:01.353285+00:00 | 2026-11-05T08:15:24.971732+00:00 | 23.618445 |
| Windows core build | 2026-11-05T08:15:01.353384+00:00 | 2026-11-05T08:15:14.316978+00:00 | 12.963585 |
| Linux focused: 36 cases | 2026-11-05T08:17:04.967946+00:00 | 2026-11-05T08:17:10.476799+00:00 | 5.508857 |
| Windows focused: 36 cases | 2026-11-05T08:17:04.967866+00:00 | 2026-11-05T08:17:12.578872+00:00 | 7.611003 |

The complete host-static gate is recorded below.

Closure uses all four host-static commands of § JJ, with the named cases in the
unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T08:18:38.581582+00:00 | 2026-11-05T08:27:15.332534+00:00 | 516.750950 | 4365 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T08:18:38.609790+00:00 | 2026-11-05T08:26:51.368435+00:00 | 492.758643 | 167 demo cases and 4365 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T08:18:38.609590+00:00 | 2026-11-05T08:18:39.377250+00:00 | 0.767656 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T08:18:38.614699+00:00 | 2026-11-05T08:18:45.675916+00:00 | 7.061215 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.29: The claimed object [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`,
`core/hostbootstrap-core/test/OwnershipObjectSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The durable record's third kind: an object another authority owns, and the claim that closes its
outcome-unknown window.

#### Objective boundary

The record vocabulary is the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)'s
and this sprint extends it, exactly as Sprint 15.26 extended the producers above it. Every record that
phase's owners write keeps its meaning and its bytes.

#### Deliverables

- `OwnerClaim` is the tag a run stamps on an object whose identity another authority answers for: minted
  before the creating command, carried by that command so the object names it from the moment it exists,
  and written into the durable record.
- The claim is a digest of the bytes a run derived it from, on the same terms a payload digest is, and
  minting is total — what makes a claim *fresh* is the derivation, which belongs to the owner that knows
  what distinguishes one of its attempts from the next.
- `ObjectKind` gains its third case, carrying that claim where a file carries its payload digest, so the
  value that makes a kind's crash window resolvable is a field of the case that has one (§ HH).
- The one canonical record codec carries the third kind in the same six tokens and the same column, and a
  reported-object record with no claim, or with a claim that is not 64 lowercase hex characters, is
  malformed rather than half-read.
- The kernel producers refuse a record describing an object they do not answer for, before any primitive,
  because no kernel primitive creates one and a producer that treated it as a directory or a file would
  bind an identity to something it never created.
- Every owner that reads a record under its own key refuses a kind that is not the one it writes.

#### Validation

The third record shape round-trips through the one codec bound and unbound, its rendering places the claim
in the payload column, and the two ways it can be malformed are refusals. The claim is the SHA-256 of
exactly the bytes it was minted from, two derivations that differ mint different claims, and its journal
codec refuses an empty, short, long, and upper-case value. Both kernel producers refuse a reported-object
record against a row whose every primitive diverges, so "the refusal comes before the mutation" is a
property of a case that finished.

Dated 2026-08-19 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): `OwnershipObjectSpec`
passed 21/21 and `OwnershipSpec` 21/21. Canonical `cabal test all --ghc-options=-Werror` from `core/`
passed 2,137/2,137 in 231.58 seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. A record can describe a claimed object; the decisions a driver makes from one are the sprint that
follows.

### Sprint 15.30: The provider resumption decisions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Resume.hs`,
`core/hostbootstrap-core/test/ProviderResumeSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Where a provider transaction stands, as a total function of what it found.

#### Deliverables

- A closed sum names the four places a transaction can legitimately stand, and they are the four prefixes
  of the one clause order: nothing done, the origin recorded, the instance created under this record's
  claim, and the instance owned.
- A closed sum names every state that is not one of those: an instance no record claims, an instance
  carrying a different claim or none at all, a bound record whose instance has been replaced, a bound
  record whose instance is gone, a record another owner wrote, and a record naming an instance that was
  there before it. Each renders once, naming both sides.
- The decision is a total function of the durable record, the observation the report produced, and the
  claim the instance carries — so the outcome-unknown window between clause 2 and clause 3 is decided by
  application rather than by whichever branch a live run happened to take, and no patchable crash point is
  needed to reach it.
- The claim comparison is the whole of that resolution: the instance name is the same by construction, so
  the claim is the only thing that tells an instance this record created from one an earlier record left
  behind. An unset claim is a conflict rather than a lenient case.
- One vocabulary answers every verb, so provision, readiness, and release act differently on the same
  answer rather than each asking a differently shaped question.

#### Validation

ProviderResumeSpec.hs's "every conflict names both sides and reads as itself" compares the
complete list of six providerStandingConflictMessage results with six exact expected texts.
The claim conflict uses separate "record-claim" and "instance-claim" literals and their exact
role words. The unclaimed, replacement, vanished and prior-instance messages retain every
carried identity through objectIdentityText; the foreign-record message retains its subject.
Swapping the claim roles or dropping either replacement identity fails the equality.

The retained "the four standings are the four prefixes of the one clause order" compares
all four successful states. Existing conflict cases cover unclaimed, differently claimed,
replaced, vanished, foreign-kind and prior-origin records. Both disclosure cases remain total
over all four standings. The unset-claim fixture comment reflects the provider's shared
answer for an absent key and an empty tag.

No production Haskell changes. The resumption classifier and renderer, every other production
module and all 702 compile-fail fixtures are byte-preserved. The existing message case is
strengthened in place; no test case is added or removed.
Compilation, focused resumption cases and all four host-static commands pass.

The focused selection contains all 16 resumption cases and 17 DocValidatorSpec cases.
The native Windows core build uses GHC 9.12.4/Cabal 3.16.1.0; Linux uses the same
versions in the dedicated hostbootstrap-linux WSL2 distribution.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T08:33:49.531797+00:00 | 2026-11-05T08:34:35.093987+00:00 | 45.562190 | PASS; exit 0 |
| Linux demo build | 2026-11-05T08:34:53.005171+00:00 | 2026-11-05T08:35:14.365568+00:00 | 21.360393 | PASS; exit 0 |
| Windows core build | 2026-11-05T08:34:09.646397+00:00 | 2026-11-05T08:34:17.001715+00:00 | 7.355315 | PASS; exit 0 |
| Linux focused resumption and documentation | 2026-11-05T08:34:53.005260+00:00 | 2026-11-05T08:34:59.027772+00:00 | 6.022515 | 33 cases pass; exit 0 |
| Windows focused resumption and documentation | 2026-11-05T08:34:28.686721+00:00 | 2026-11-05T08:34:36.336188+00:00 | 7.649465 | 33 cases pass; exit 0 |

Closure uses all four host-static commands of § JJ, including the named resumption
cases in the unfiltered core suite.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T08:35:48.231394+00:00 | 2026-11-05T08:44:28.898193+00:00 | 520.666798 | 4365 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T08:35:48.231254+00:00 | 2026-11-05T08:44:02.907431+00:00 | 494.676175 | 167 demo cases and 4365 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T08:35:48.242265+00:00 | 2026-11-05T08:35:48.996097+00:00 | 0.753827 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T08:35:48.260733+00:00 | 2026-11-05T08:35:55.239884+00:00 | 6.979149 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 197 production Haskell files under src/internal and 702 compile-fail fixtures match the
sprint baseline. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.31: The backend takes the one interpreter [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

The provider backend runs described commands through the one interpreter, and holds no execution seam of
its own.

#### Objective boundary

This sprint changes *how* the backend reaches a process, not *what* it asks for. The described commands
are Sprint 15.28's and the classifications Sprint 15.27's; what goes away is the injected runner between
them. § NN is the reason it goes: a seam whose only purpose is to let a suite answer for a provider is a
substitution point that has to be trusted to have been reached, and the decisions it was standing in for
are now total functions that need no stand-in.

#### Deliverables

- The strong backend carries the typed host configuration rather than a runner, and every provider process
  it starts goes through `interpretHostCommand` (§ KK).
- The Incus driver's report parsing is an application of the total classifier: every Incus outcome reaches
  a decision through `Provider/Ownership.hs` and `classifyProviderReport`. The guest-VM row (Lima and WSL2)
  and the Direct egress probe still decide from the exit code and their own first diagnostic line, so a
  noisy success there is a success. Bringing the guest-VM row onto the classifier is Sprint 15.42's.
- The suite's cases move from feeding a stand-in runner to applying the classifier to the streams a
  provider produces, so each keeps its subject and loses its stand-in.
- No public or package-private type names an executor, and the source guard that says so is part of the
  sprint: the backend reaches a process only through `interpretHostCommand`, imports nothing from
  `HostBootstrap.Effect.Run` but `CapturedRun` and its fields, and names none of the package's process
  spawners.

#### Validation

ProviderBackendSpec.hs's "the backend reaches every process through the one interpreter"
uses backendHasNoExecutionSeamCase to check the interpreter import and absence of System.Process.
It compares the explicit Effect.Run import list with exactly CapturedRun and its three report
fields. Lexical identifier counts reject runCaptured, runBoundedGrouped and
runBoundedGroupedWithInput in both Provider/Backend.hs and Provider/Ownership.hs.

The retired-executor scan enumerates the physical src/ and internal/ trees through
SourceGuard.listHaskellSources and reads each source strictly. It checks all seven retired
executor names, including files not registered in a Cabal library. The former private walker
is already absent in the sprint baseline; none is introduced.

The existing case is strengthened in place; no case is added or removed. No production
Haskell changes. All production modules and all 702 compile-fail fixtures are byte-preserved.
The lifecycle family's provider-client fixtures remain separate from this source-boundary
evidence. The real KVM/Incus confirmation of the finished tree belongs to Sprint 15.50.

Compilation and the focused guard/documentation selection pass on Linux and Windows.
The selection contains the one execution-seam guard and all 17 DocValidatorSpec cases.
Both native core builds use GHC 9.12.4/Cabal 3.16.1.0. The complete host-static gate is recorded below.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T08:47:00.092301+00:00 | 2026-11-05T08:47:55.734893+00:00 | 55.642594 | PASS; exit 0 |
| Linux demo build | 2026-11-05T08:47:26.061723+00:00 | 2026-11-05T08:47:57.058187+00:00 | 30.996461 | PASS; exit 0 |
| Windows core build | 2026-11-05T08:47:00.092229+00:00 | 2026-11-05T08:47:16.309771+00:00 | 16.217539 | PASS; exit 0 |
| Linux execution-seam guard and documentation | 2026-11-05T08:48:05.665965+00:00 | 2026-11-05T08:48:11.619305+00:00 | 5.953339 | 18 cases pass; exit 0 |
| Windows execution-seam guard and documentation | 2026-11-05T08:47:50.677933+00:00 | 2026-11-05T08:47:59.013487+00:00 | 8.335552 | 18 cases pass; exit 0 |

Closure uses all four commands of § JJ.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T08:48:48.671341+00:00 | 2026-11-05T08:57:26.661255+00:00 | 517.989916 | 4365 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T08:48:48.670692+00:00 | 2026-11-05T08:57:01.540645+00:00 | 492.869950 | 167 demo cases and 4365 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T08:48:48.670949+00:00 | 2026-11-05T08:48:49.452104+00:00 | 0.781155 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T08:48:48.671593+00:00 | 2026-11-05T08:48:55.758852+00:00 | 7.087257 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 197 production Haskell files under src/internal and 702 compile-fail fixtures match the
sprint baseline. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.32: The provision and readiness drivers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Provision and readiness holding their clauses through the reported face.

#### Deliverables

- Provision enters the protected store the provider's state directory names, records the origin under a
  fresh claim, launches through the one interpreter, classifies the report, and binds the reported
  identity — in that order, because the tokens admit no other.
- Clause 2's publication continuation is idempotent, so a resumed transaction mints its token honestly: a
  first attempt is the store's compare-and-swap from absent, a resumed one accepts the record already
  there when its kind and origin are this transaction's (the record tape's `extendsThisRecord`, reached
  through `publishFreshRecord`), so a record a previous entry already bound is accepted, and either way the
  token asserts the same fact — this record is durable.
- Provision answers AlreadyOwned only for an instance bound under this run's own claim; an instance the
  record binds under another claim is a standing conflict, so provision and the forward delete that follows
  judge the same object the same way.
- Readiness re-observes the bound identity through the report before any dependent mutation, and retries
  only an instance that is not answering yet: a failure or a conflict ends the poll after one probe.
- A provider replaced or reclaimed under a guest command crosses back as an `HB_PROVIDER_CONFLICT` marker
  whose fields are space-free tokens carrying the bound and observed identities, under one token grammar the
  emitter in `Provider/Backend.hs` and the parser in `Substrate/Provider.hs` share.
- The driver runs no interpreter program and parses no report vocabulary of its own; the prepared provision
  and ready calls consume it.

#### Validation

ProviderBackendSpec.hs adds the following cases:
- "an owned instance bound under another run's claim is refused" compares the complete standing
  conflict and preserves every instance and protected-record byte, with no second launch;
- "Ready stops after one failed guest probe" requires the permission-denied failure after exactly
  one true probe and unchanged protected-record bytes;
- "guest conflicts retain both identities through the marker grammar" applies guestOutcome to
  InstanceReplaced and to the OwnershipConflict shape emitted by replacedUnderGuestCommand,
  comparing the exact marker, parsed ProbeConflict and classified ProbeConflicted;
- "the marker emitter and reader refuse non-ASCII tokens" requires the shared grammar to reject
  a non-ASCII letter and checks the emitter's bounded invalid-marker refusal and parser rejection;
- "an unavailable daemon refuses discovery and provision without mutation" classifies the actual
  stand-in listing refusal and calls provision through the real store, requiring no record or instance;
- "unavailable provisioning egress is classified as unavailable" applies the probe classifier to
  the stand-in's image-info refusal;
- "the CLI stand-in refuses absent and wrong-state operations" checks exact exits and diagnostics,
  unchanged mutation history on refusal and no guest dispatch while stopped;
- "the CLI stand-in gives a relaunched name a fresh identity" compares both counter-derived identities
  and the complete launch/delete/launch mutation sequence;
- "nested provider fixtures restore the previous environment value" checks both nesting levels
  and restoration of the caller's prior value.

The existing readyObservationReplacementCase also requires exactly one guest probe. retainedReverseCase
compares the complete launch/stop/delete sequence. concurrentProvisionCase catches each child's
exception into its MVar and retains convergence assertions; AuthoritySpec owns the exclusion proof.

The stand-in's module header names its served vectors and evidence limits. Its global daemon check
precedes every vector, instance-dependent operations require an instance, and launch/start/stop/exec
check their declared states. A persistent counter separates identities across name reuse.
The served listing includes both name and state. Prepared alias fixtures use the shared
FakeProvider.aliasGuest handler under the exact prepared-alias role.
The recordedGuestInvocations assertions use one local reader owned by ProviderBackendSpec.

The clause-2 idempotent-publication Haddock is attached to withRecordedClaim. No orphaned forget-record
comment or publication Haddock on interpret exists in the sprint baseline. The marker's foreign
translation carries structured identity sides alongside its descriptive observation, and its origin
tokens use identity= consistently. The backend consumes the one exported validConflictToken grammar.
guestOutcome is the public pure classification boundary; no injected execution seam is introduced.

These process fixtures prove their stand-in protocol and real store behavior, not native Incus/KVM.
Sprint 15.50 owns the finished tree's live confirmation. All 702 compile-fail fixtures are preserved.
Initial Linux and Windows core builds both refused the new branch because its explicit
InstanceUnderAnotherClaim import was missing. The import is corrected; no passing build or
case run is claimed for those attempts.
The next Linux and Windows builds compiled production but caught overloaded string defaulting
in the new probe script under -Werror. The complete script tuple list now has its explicit
[(Int, String, String)] type; those attempts are not claimed as passing builds.
Compilation and all 577 focused cases pass on both hosts. The selection includes all nine
new cases, ProviderBackendSpec, ProviderReconcileSpec, ProviderSpec, ProviderAliasSpec,
provider reports, provider resumption, AuthoritySpec and DocValidatorSpec. Existing
platform-row refusals retain their declared cases on the host where they cannot apply.
Both native core builds use GHC 9.12.4/Cabal 3.16.1.0.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T09:12:55.359355+00:00 | 2026-11-05T09:13:14.815139+00:00 | 19.455785 | PASS; exit 0 |
| Linux demo build | 2026-11-05T09:15:18.195578+00:00 | 2026-11-05T09:16:19.942309+00:00 | 61.746726 | PASS; exit 0 |
| Windows core build | 2026-11-05T09:12:55.359266+00:00 | 2026-11-05T09:13:16.492811+00:00 | 21.133541 | PASS; exit 0 |
| Linux provider, ownership, alias and documentation | 2026-11-05T09:14:09.432772+00:00 | 2026-11-05T09:14:41.486503+00:00 | 32.053726 | 577 cases pass; exit 0 |
| Windows provider, ownership, alias and documentation | 2026-11-05T09:14:09.433628+00:00 | 2026-11-05T09:15:26.445477+00:00 | 77.011853 | 577 cases pass; exit 0 |

The production scope is 74 nonempty changed lines across three modules. All 702 compile-fail
fixtures and 194 other production Haskell files under src/internal are byte-preserved.
LF and scoped diff checks pass. The complete host-static gate is recorded below.
 Closure uses all four
commands of § JJ.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T09:17:16.099614+00:00 | 2026-11-05T09:26:03.778147+00:00 | 527.678529 | 4374 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T09:17:16.119354+00:00 | 2026-11-05T09:25:35.707629+00:00 | 499.588274 | 167 demo cases and 4374 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T09:17:16.099698+00:00 | 2026-11-05T09:17:17.284863+00:00 | 1.185161 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T09:17:16.131880+00:00 | 2026-11-05T09:17:23.570072+00:00 | 7.438189 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 194 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The three owned modules change 74 nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.33: Interrupted provider removal recovery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/ownership_seam.md`

#### Objective

Finish an interrupted provider removal from its durable claim and identity binding.

#### Deliverables

- The reported seam's resumeReportedRemoval consumes a retained Bound token under a live protected entry,
  admits fresh OriginAbsent, and performs the same clause-4 record cleanup as ordinary reported removal.
  Every present object is refused, including the prior bound identity.
- A forward or retained delete whose bound instance has vanished re-enters the durable binding, observes
  absence afresh and forgets its share records before its instance record, answering DeleteRemoved.
- An instance that carries the record's claim after an interrupted launch is bound before teardown. Both
  delete routes release it without re-provisioning.
- Forward recovery requires this run's owner claim. Retained recovery derives the claim from the exact
  stored record. Ordinary identity re-observation continues to admit exactly the bound identity.
- DeleteAlreadyRemoved describes an absent instance, including cleanup of an unbound clause-2 record.

#### Validation

OwnershipSpec.hs's "an interrupted reported removal cleans its record only over fresh absence"
uses an actual stored bound record and the real protected store. Its present-object checks preserve
the protected record, and its absent-object branch forgets that record. The entry-lifetime family
includes the recovery act, and the source guard checks its live-entry floor. The existing
"clause 4 admits exactly the bound identity" keeps the ordinary absence and replacement refusals.

ProviderBackendSpec.hs adds "a forward delete resumes after its removal response is lost"
and "a retained delete resumes after its removal response is lost". Both attach a share,
stop the instance, lose the post-delete answer, require both records to remain byte-identical,
retry without another delete, retire every record and provision under the same key with a fresh
counter-derived identity. The complete mutation list holds launch/device-add/restart/stop/delete/launch order.

"a forward delete releases an interrupted unbound launch" and
"a retained delete releases an interrupted unbound launch" require the real stored record to
have no identity binding after the launch failure. Teardown binds the observed instance before
stop/delete, retires the record, and permits a fresh launch under the same key.

The first Linux and Windows builds compiled the shared recovery producer but refused the
provider module because its explicit OwnershipMalformed import was missing. That import is
corrected; these attempts are not claimed as passing builds.
The next builds compiled production on both hosts, then refused the new exact-conflict case
because OwnershipSpec imported ConflictReport fields without its constructor. That explicit
constructor import is corrected; these attempts are not claimed as passing test builds.

The first focused Linux and Windows selections each ran 676 cases and reported three
expectation failures: the revoked-entry family counted 13 actions after adding its fourteenth,
and the two share/retry mutation lists omitted device-add. Those exact expectations are corrected.
No passing focused run is claimed for either selection.

The production scope is 156 nonempty changed lines across Primitive.hs and Provider/Ownership.hs.
The 702 compile-fail fixtures and all 195 other production Haskell files under src/internal,
including Provider/Backend.hs, are byte-preserved. Compilation and all 676 focused cases pass on both hosts. The selection includes all five
new cases, the fourteen revoked-entry effects, OwnershipSpec, ProviderBackendSpec,
ProviderReconcileSpec, ProviderSpec, ProviderAliasSpec, provider reports, provider resumption,
AuthoritySpec and DocValidatorSpec. Existing platform-row refusals retain their declared
cases on the host where they cannot apply. Both native core builds use GHC 9.12.4/Cabal 3.16.1.0.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T09:52:59.726635+00:00 | 2026-11-05T09:53:15.785154+00:00 | 16.058516 | PASS; exit 0 |
| Linux demo build | 2026-11-05T09:54:58.641604+00:00 | 2026-11-05T09:56:22.260610+00:00 | 83.619000 | PASS; exit 0 |
| Windows core build | 2026-11-05T09:52:59.726705+00:00 | 2026-11-05T09:53:18.712430+00:00 | 18.985726 | PASS; exit 0 |
| Linux provider, ownership, alias and documentation | 2026-11-05T09:53:30.858575+00:00 | 2026-11-05T09:54:10.123453+00:00 | 39.264874 | 676 cases pass; exit 0 |
| Windows provider, ownership, alias and documentation | 2026-11-05T09:53:30.858663+00:00 | 2026-11-05T09:55:02.698215+00:00 | 91.839553 | 676 cases pass; exit 0 |

The complete host-static gate is recorded below.
The process fixtures establish their stand-in protocol and real store behavior. Sprint 15.50
owns the finished tree's native Incus/KVM confirmation. Closure uses all four commands of § JJ.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T09:58:22.407149+00:00 | 2026-11-05T10:07:04.083005+00:00 | 521.675854 | 4379 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T09:58:22.407258+00:00 | 2026-11-05T10:06:41.008714+00:00 | 498.601454 | 167 demo cases and 4379 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T09:58:22.419118+00:00 | 2026-11-05T09:58:23.624791+00:00 | 1.205674 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T09:58:22.419003+00:00 | 2026-11-05T09:58:29.906659+00:00 | 7.487655 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 195 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The two owned modules change 156 nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.33a: Fresh instance and share identity at deletion [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Delete only the freshly observed instance and the share devices its records bind.

#### Deliverables

- A share device name hashes the share binding's UTF-8 bytes. Binding equality also depends on exact
  device readback, because a truncated digest admits collisions.
- Share bookkeeping admits the exact bound device or its absence. A device replaced under the same name
  is a conflict that preserves the device, every record and the instance.
- Delete observes its instance after share bookkeeping and immediately before the guarded command.
  Clause 4 compares that fresh identity, so a replacement receives no delete command.
- The post-delete observation compares identity even when a same-named replacement carries the old
  owner claim, leaving it standing and retaining every record.
- The share-bookkeeping Haddock describes the actual validation and parent-removal authority under which
  records retire; every token claim corresponds to a token the code actually holds.

#### Validation

ProviderBackendSpec.hs adds four cases:
- "delete refuses an instance replaced after share bookkeeping" changes only the instance identity
  after the last device read. It requires a conflict, no delete command, no new mutation, and
  byte-identical instance/share records.
- "delete refuses a repointed recorded share without forgetting records" compares the complete
  expected/observed identity fields with the protected binding and an independent Python hashlib
  vector for disk, /srv/replaced and /srv/hostbootstrap/data. The device, instance and every record
  remain exact, and no delete command is received.
- "delete releases an already absent recorded share" removes the device out of band, then requires
  successful instance deletion and retirement of both records.
- "UTF-8 share bindings distinguish U+0151 from Q" prepares and attaches both bindings through the
  same backend, requiring two different device names and the exact two guest paths.

The retained deleteReplacementLeftStandingCase compares every ProviderInstance field with its
pre-delete value except the changed identity. The test client's post-delete replacement inherits
the removed instance's claim, state and device fields, so a claim comparison cannot satisfy the case.
Existing shareObservationReplacementCase, shareRestartReplacementCase, stopObservationReplacementCase
and exactRestartBeforeDeleteCase remain present.

removeInstance now carries Bound through share bookkeeping and obtains its Releasable token only
from observeInstance's fresh origin immediately before the guarded command. observeShareRecord
compares the exact bound device identity and admits absence. The bookkeeping Haddock describes
record keys and parent-removal authority. shareDeviceName hashes UTF-8 bytes. No public surface changes.

The first focused Linux and Windows selections each ran 680 cases and reported one setup
failure: the Unicode case re-entered provisioning with a different fixture owner claim.
It now prepares both shares under one running provider, obtaining a fresh readiness dependency
for the second preparation. Production is unchanged by this correction. Neither initial
selection is claimed as passing.

The production scope is 47 nonempty changed lines across two modules. The 702 compile-fail
fixtures and all 195 other production Haskell files under src/internal are byte-preserved.
Compilation and all 680 focused cases pass on both hosts. The selection includes the four
new cases, the strengthened identity-only replacement, OwnershipSpec, ProviderBackendSpec,
ProviderReconcileSpec, ProviderSpec, ProviderAliasSpec, provider reports, provider resumption,
AuthoritySpec and DocValidatorSpec. Existing platform-row refusals retain their declared
cases on the host where they cannot apply. Both native core builds use GHC 9.12.4/Cabal 3.16.1.0.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T10:25:30.516210+00:00 | 2026-11-05T10:25:44.102169+00:00 | 13.585958 | PASS; exit 0 |
| Linux demo build | 2026-11-05T10:27:44.932781+00:00 | 2026-11-05T10:28:22.827774+00:00 | 37.894989 | PASS; exit 0 |
| Windows core build | 2026-11-05T10:25:30.516129+00:00 | 2026-11-05T10:25:45.123132+00:00 | 14.607001 | PASS; exit 0 |
| Linux provider, ownership, alias and documentation | 2026-11-05T10:26:34.713236+00:00 | 2026-11-05T10:27:14.663967+00:00 | 39.950728 | 680 cases pass; exit 0 |
| Windows provider, ownership, alias and documentation | 2026-11-05T10:26:34.713318+00:00 | 2026-11-05T10:28:16.247679+00:00 | 101.534361 | 680 cases pass; exit 0 |

The complete host-static gate is recorded below. The process fixtures
establish their stand-in protocol and real store behavior; Sprint 15.50 owns native Incus/KVM
confirmation of the finished tree. Closure uses all four commands of § JJ.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T10:30:13.742702+00:00 | 2026-11-05T10:38:54.686560+00:00 | 520.943859 | 4383 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T10:30:13.742622+00:00 | 2026-11-05T10:38:27.539410+00:00 | 493.796787 | 167 demo cases and 4383 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T10:30:13.742889+00:00 | 2026-11-05T10:30:14.930140+00:00 | 1.187248 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T10:30:13.769914+00:00 | 2026-11-05T10:30:21.186781+00:00 | 7.416865 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 195 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The two owned modules change 47 nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.34: Direct canonical-root admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`, `core/hostbootstrap-core/test/FakeProvider.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

The Direct host's admission as a pure decision over a real observation.

#### Deliverables

- The check that a root is absolute, unfollowed, a directory, and accessible is a total function over an
  observation this binary made, rather than a program delegated to an interpreter. Every fact the
  observation could not take is observed as the refusing answer, canonicalization included: a
  `canonicalizePath` that throws makes `directRootCanonical` false.
- Direct still claims no ownership of the host: it publishes no origin, holds no clause, and refuses stop
  and delete.
- A Direct share is admitted only when its source is exactly the admitted root; any other source is
  `ProviderShareConflict`, because the Direct host exposes its one canonical root and mounts nothing.
- Direct readiness probes egress with `docker manifest inspect` over exactly the spec's declared image.

#### Validation

ProviderBackendSpec.hs's "the Direct root admission refuses one observed fact at a time" applies
the valid observation and five single-fact refusals. Each refusal must contain its own exact
reason fragment. "a failed Direct canonicalization is a refusing fact" applies
directRootCanonicalFact to Nothing, the matching path and another path.

"Direct Ready validates the exact root then exact egress image" requires exactly
["docker manifest inspect images:ubuntu/24.04"]. The egress-failure case pins that same command.
"Direct Ready refuses an absent root before probing egress" checks the missing-directory reason
and an empty command list; the noncanonical-root case also requires no egress. The real root
observations use actual temporary directories. The symbolic-link and accessibility refusals are
applied as fact values, without claiming host privileges the gate lacks.

ProviderReconcileSpec.hs's "a Direct share refuses a sibling of its admitted root" creates the
sibling directory and requires settlement to yield Conflict with resource direct-host-share.
The matching-root and prior-proof cases remain.

FakeProvider.hs's Docker role is the compiled test executable. It records actual argv and can
restrict its accepted command. ProviderBackendSpec uses the recording role; ProviderReconcileSpec
accepts only manifest/inspect/alpine:3.22 and refuses every other vector. CompileFailSpec.hs's "a share without its provider dependency refuses before probing" uses an isolated
driver that serves the same role before executing its own probe, with UTF-8 set as
its first action. These clients establish argument routing, not real Docker/registry availability.

observeDirectRoot records failed canonicalization as Nothing, uses the shared pure fact, and
treats an unreadable link predicate as refusing. The directory refusal precedes the link refusal
so an absent root reports the missing-directory fact. SealedExportInventory includes the pure
canonical-fact function.

The production scope is 18 nonempty changed lines in one module. All 702 compile-fail fixtures
and 196 other production Haskell files under src/internal are byte-preserved.
Compilation and all 686 focused cases pass on Linux and Windows. The selection includes
the two new Direct cases, the reason-specific and exact-argv assertions, the isolated
share-descriptor control and all three provider-origin runtime controls, plus ProviderBackendSpec,
ProviderReconcileSpec, ProviderSpec, ProviderAliasSpec, OwnershipSpec, provider reports,
provider resumption, AuthoritySpec and DocValidatorSpec. Existing platform-row refusals
retain their cases. Both native core builds use GHC 9.12.4/Cabal 3.16.1.0.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T11:06:34.983684+00:00 | 2026-11-05T11:08:27.857705+00:00 | 112.874022 | PASS; exit 0 |
| Linux demo build | 2026-11-05T11:10:54.710426+00:00 | 2026-11-05T11:12:20.610968+00:00 | 85.900540 | PASS; exit 0 |
| Windows core build | 2026-11-05T11:06:34.983640+00:00 | 2026-11-05T11:08:04.450260+00:00 | 89.466619 | PASS; exit 0 |
| Linux provider/ownership/Direct and isolated runtime | 2026-11-05T11:09:08.367291+00:00 | 2026-11-05T11:10:11.016171+00:00 | 62.648886 | 686 cases pass; exit 0 |
| Windows provider/ownership/Direct and isolated runtime | 2026-11-05T11:09:08.367216+00:00 | 2026-11-05T11:11:13.533508+00:00 | 125.166289 | 686 cases pass; exit 0 |

The complete host-static gate is recorded below.
Sprint 15.50 owns the finished tree's real Direct egress and native Incus/KVM confirmation.
Closure uses all four commands of § JJ.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T11:13:49.894298+00:00 | 2026-11-05T11:22:33.900627+00:00 | 524.006324 | 4385 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T11:13:49.894054+00:00 | 2026-11-05T11:22:09.954385+00:00 | 500.060329 | 167 demo cases and 4385 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T11:13:49.902534+00:00 | 2026-11-05T11:13:51.029151+00:00 | 1.126616 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T11:13:49.915062+00:00 | 2026-11-05T11:13:57.354183+00:00 | 7.439119 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 196 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The owned module changes 18 nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.35: The provider's interpreter program is gone [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The provider boundary carries no program written in another language.

#### Objective boundary

What this sprint removes is the provider's own interpreter program and the locking front end it ran under.
Which names the closed `HostTool` set still carries is a description of what the binary drives, and the
last driver to stop driving an interpreter is the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md)'s, so the
enumeration narrows there rather than here.

#### Deliverables

- The provider backend resolves no interpreter and no locking front end, because every clause it holds is
  the seam's and every effect it performs is a described command.
- The guest-VM row's probes are exact argument vectors, not shell programs: the writable-share reprobe and
  the provisioning-egress probe each reach the guest as an argv with no `bash -lc` and no script text.
- A source guard holds the absence, naming the [rationale](rationale.md) entry ("A script is a fork of the
  binary, and it is the fork nothing can check") that says why a program in a string is refused.

#### Validation

The guest-VM share observation sends `test -d <target>` and, only after success,
`test -w <target>` as separate `runGuestVm` calls. The first refusal keeps its existing
classification and prevents the second probe. Provisioning egress sends
`getent hosts archive.ubuntu.com` directly. Neither route resolves an interpreter.

The three-case provider command boundary group in `ProviderBackendSpec` reads both
`Provider/Backend.hs` and `Provider/Ownership.hs`. It refuses the literal arguments
`bash`, `sh`, `-c` and `-lc` and the constructors `Python3`, `Flock` and `Lockf`.
Its Haskell token scan decodes string escapes, ignores comments, and has recognition controls.
The positive guard requires both modules to import `Provider.Command` and reach
`interpretHostCommand`, plus the backend's ownership-driver call and the driver's launch-command
call. The group's Haddock cites the rationale entry by title.

The opt-in live client uses the same observation and admission decision as the Direct realization
and reads the protected store's own record. Its component compiles on every gate host; runtime
platform and confirmation checks decide whether the live subject runs. The closed `HostTool`
vocabulary remains owned by the [cluster lifecycle phase](phase-16-cluster-lifecycle-and-cordoning.md).
Sprint 15.50 owns this phase's final confirmed live gate.

Dated 2026-11-05 build and focused evidence uses GHC 9.12.4/Cabal 3.16.1.0 on
native x86_64 Windows and Ubuntu 24.04.5 x86_64 in the dedicated hostbootstrap-linux WSL2
distribution. Builds use `cabal build all --enable-tests`; the focused selection covers provider
backends, reconciliation, aliases, reports, resumption, authority, ownership, documentation,
and the isolated prepared-route runtime controls.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Native Windows core build | 2026-11-05T11:25:08.962120+00:00 | 2026-11-05T11:25:37.558885+00:00 | 28.596763 | all components, including the live client; exit 0 |
| Linux core build | 2026-11-05T11:25:08.972987+00:00 | 2026-11-05T11:26:13.864743+00:00 | 64.891753 | all components, including the live client; exit 0 |
| Linux demo build | 2026-11-05T11:25:08.991083+00:00 | 2026-11-05T11:25:44.886963+00:00 | 35.895878 | consumer and core components; exit 0 |
| Native Windows focused selection | 2026-11-05T11:25:48.321966+00:00 | 2026-11-05T11:27:52.976977+00:00 | 124.655012 | 689 cases; exit 0 |
| Linux focused selection | 2026-11-05T11:26:24.239492+00:00 | 2026-11-05T11:27:27.825090+00:00 | 63.585596 | 689 cases; exit 0 |

All commands pass on the first attempt and preserve the same 1165 source/build/document files;
the Linux wrappers verify both trees. The new source group contributes three cases. The existing
Windows fixture permission diagnostics remain explicit Unsupported observations. The change is
seven nonempty production lines in one module, with all 196 other production Haskell files and
702 compile-fail fixtures byte-preserved.

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T11:28:27.361106+00:00 | 2026-11-05T11:37:09.443287+00:00 | 522.082178 | 4388 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T11:28:27.361212+00:00 | 2026-11-05T11:36:48.501203+00:00 | 501.139993 | 167 demo cases and 4388 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T11:28:27.379186+00:00 | 2026-11-05T11:28:28.160039+00:00 | 0.780851 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T11:28:27.388090+00:00 | 2026-11-05T11:28:34.477406+00:00 | 7.089320 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 196 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The owned module changes seven nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.36: The inherited durability statement [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Say once, and hold mechanically, whose contract the provider boundary's durability is.

#### Objective boundary

The protected store's own durability contract — that a write publishes a fully written, flushed temporary
by atomic rename, and that an interrupted publication leaves either the old record or the new one — is the
[four-ownership-clauses-and-host-local-reservations phase](phase-14-ownership-clauses-and-reservations.md)'s,
and `AuthoritySpec` covers it. This sprint states the inheritance at the provider boundary and adds no
second statement of the contract itself.

#### Deliverables

- The provider ownership driver's module documentation states that every durable byte it publishes is the
  store's compare-and-swap, so the partial-write, partial-fsync, and partial-unlink windows are the
  store's contract rather than a second one stated here.
- A source guard holds the inheritance over the whole provider boundary — `Substrate/Provider.hs` and every
  module under `Substrate/Provider/`: none of them imports a mutating `System.Directory` or `System.IO`
  name, so no instruction point exists at which a second durability window could be reintroduced (§ NN),
  and the driver's durable publications are applications of the record tape's `publishFreshRecord`,
  `publishBoundRecord`, and `forgetRecord`, the tape being the one place `compareAndSwapProtectedRecord` and
  `compareAndDeleteProtectedRecord` are named.

#### Validation

`ProviderSpec`'s inherited durability group reads `Substrate/Provider.hs` and enumerates
every Haskell module under `Substrate/Provider/` with `SourceGuard.readHaskellSources`.
Each import of `System.Directory` or `System.IO` requires one explicit list, checked with
`SourceGuard.moduleImportTokens`, containing only the named read-only observation vocabulary.
The Direct root's permission projections, permission read, directory check, symbolic-link check
and canonicalization remain admitted. Read-only file reads are admitted; handle openers, flushers,
writers, renamers, link mutations and other unlisted imports refuse.

The same complete provider scan names neither protected compare primitive. The positive check
requires the driver to apply `publishFreshRecord`, `publishBoundRecord` and `forgetRecord`
beyond their import-list counts, and the record tape to apply both protected compare primitives.
Import controls cover named mutations, qualified aliases, unrestricted imports, hiding lists,
duplicate imports, admitted observations and comments. Publication controls distinguish imports
and comments from actual uses. The driver's module documentation states this inheritance and
the breadth of its mechanical guard.

Dated 2026-11-05 build and focused evidence uses GHC 9.12.4/Cabal 3.16.1.0 on
native x86_64 Windows and Ubuntu 24.04.5 x86_64 in the dedicated hostbootstrap-linux WSL2
distribution. Builds use `cabal build all --enable-tests`; the focused selection covers provider
dispatch, inherited durability, authority, ownership and documentation.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Native Windows core build | 2026-11-05T11:40:21.752168+00:00 | 2026-11-05T11:40:38.056749+00:00 | 16.304580 | all components, including the live client; exit 0 |
| Linux core build | 2026-11-05T11:40:21.766485+00:00 | 2026-11-05T11:41:15.149221+00:00 | 53.382732 | all components, including the live client; exit 0 |
| Linux demo build | 2026-11-05T11:40:21.781385+00:00 | 2026-11-05T11:40:46.687486+00:00 | 24.906089 | consumer and core components; exit 0 |
| Native Windows focused selection | 2026-11-05T11:40:59.247171+00:00 | 2026-11-05T11:41:49.583876+00:00 | 50.336703 | 480 cases; exit 0 |
| Linux focused selection | 2026-11-05T11:41:39.571933+00:00 | 2026-11-05T11:42:02.945084+00:00 | 23.373141 | 480 cases; exit 0 |

All commands pass on the first attempt and preserve the same 1165 source/build/document files;
the Linux wrappers verify both trees. The inherited durability group has three cases, including two new recognition controls. The existing
Windows fixture permission diagnostics remain explicit Unsupported observations. The change is
four nonempty production comment lines in one module, with no production logic changes, with all 196 other production Haskell files and
702 compile-fail fixtures byte-preserved.

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T11:42:40.339117+00:00 | 2026-11-05T11:51:27.752906+00:00 | 527.413786 | 4390 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T11:42:40.339184+00:00 | 2026-11-05T11:51:07.125568+00:00 | 506.786386 | 167 demo cases and 4390 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T11:42:40.354826+00:00 | 2026-11-05T11:42:41.119129+00:00 | 0.764299 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T11:42:40.370161+00:00 | 2026-11-05T11:42:47.422094+00:00 | 7.051935 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 196 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The owned module changes four nonempty comment lines, with no production logic changes. Scoped LF and diff checks pass.
The legacy ledger matches the completed handoff and provider sprints after an audit of their
actual source and exported surfaces; no row names a Done sprint.

#### Remaining Work

None.

### Sprint 15.37: The live Incus provider run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated live `provider-live` run on native Linux/x86_64 with KVM and Incus.

#### Deliverables

- one dated run of `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all
  --test-show-details=direct --ghc-options=-Werror` naming its host;
- that run also confirms `liveGuestSelfPath`, the in-VM path the shipped guest transaction re-invokes,
  which the host build cannot check.

#### Validation

On 2026-09-09 the phase's exact native Linux/x86_64 gate passed all 2,497 static cases and the live
component reported `provider-live: PASS — prepared Incus lifecycle/share/alias/restart/delete and
mutation-free Direct refusal`. The phase-level record below names the host, toolchain, observations, and
residue checks.

#### Remaining Work

None.

### Sprint 15.38: One guest-VM backend row [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

The substrate axis is a lift: guest-VM construction is one parameterized row, and each provider kind
has an explicit bound route and a distinct backend identity. Host guard, provider kind, tool and
refusal labels are data supplied to the common constructor.

#### Deliverables

- A guest-VM backend constructor takes the host guard, provider kind, tool and label as parameters.
- The Lima and WSL2 constructors become applications of it.
- The invalid-input and tool-requirement helpers that all four backend constructors redefine are hoisted to one definition parameterised by label.
- Adding a guest-VM provider is a new application, not a new copy, and every function that routes on the
  guest-VM provider kind matches each kind explicitly, so a new kind is a compile error at each route rather
  than a silent Lima route.

#### Validation

`mkGuestVmBackendSpec` holds the common guard sequence. `mkLimaBackendSpec` and
`mkWsl2BackendSpec` apply their realization values; `invalidBackend` and
`requireBackendTool` remain the shared constructor helpers. Existing source guards hold those
single definitions and applications.

`providerBoundRouteFor` returns a checked route. The guest-VM arm explicitly matches all four
`ProviderKind` constructors: Lima and WSL2 describe their own routes, while Incus and Direct
return a failure. No wildcard supplies a Lima route. A new provider kind makes that match incomplete
under the package's ordinary -Werror policy. `withProviderBoundExec` first validates its receipt and
origin, selects the retained realization's runner, and checks the route before invoking the continuation.
The binding and callback construction are shared across the three backend forms.

The dedicated backend identity case gives the WSL and Lima tools exactly one executable path while
holding the VM name, envelope and share constant. The two declarations remain unequal because their
provider kinds differ. The existing Windows CPU host admission case and constructor refusal cases
remain exercised.

The initial 2026-11-05 build attempts on native Windows and in both Linux workspaces refuse
the two explicit non-VM route arms because their constructors are absent from the import list.
Those attempts exit 1 before running tests: Windows at 11:54:56 UTC (2.348587 seconds),
Linux core at 11:55:29 UTC (35.072707 seconds), and Linux demo at 11:55:07 UTC
(13.435135 seconds). The explicit `ProviderKind` import now includes both constructors.

The next build attempts compile the production change and refuse the split test's terminal
binding in its do-block. They exit 1 before tests: Windows at 11:56:18 UTC (9.814259 seconds),
Linux core at 11:56:20 UTC (11.886898 seconds), and Linux demo at 11:56:18 UTC
(10.117679 seconds). The Windows CPU admission case now finishes with `void` over that admission.

The following test compilation reports -Wname-shadowing under -Werror: the local executable
name clashes with a System.Directory permission projection. All three builds exit 1 before tests:
Windows at 11:57:20 UTC (5.241020 seconds), Linux core at 11:57:19 UTC (4.513508 seconds),
and Linux demo at 11:57:17 UTC (2.143215 seconds). The test local is now `sharedGuestClient`.

Dated 2026-11-05 build and focused evidence uses GHC 9.12.4/Cabal 3.16.1.0 on
native x86_64 Windows and Ubuntu 24.04.5 x86_64 in the dedicated hostbootstrap-linux WSL2
distribution. Builds use `cabal build all --enable-tests`; the focused selection covers provider
backends, reconciliation, aliases, reports, resumption, authority, ownership, documentation,
and the isolated prepared-route runtime controls.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Native Windows core build | 2026-11-05T11:58:34.779554+00:00 | 2026-11-05T11:58:50.172839+00:00 | 15.393282 | all components, including the live client; exit 0 |
| Linux core build | 2026-11-05T11:58:34.796620+00:00 | 2026-11-05T11:58:48.630452+00:00 | 13.833830 | all components, including the live client; exit 0 |
| Linux demo build | 2026-11-05T11:58:34.809793+00:00 | 2026-11-05T11:58:48.630996+00:00 | 13.821197 | consumer and core components; exit 0 |
| Native Windows focused selection | 2026-11-05T11:59:20.294927+00:00 | 2026-11-05T12:01:24.132159+00:00 | 123.837231 | 692 cases; exit 0 |
| Linux focused selection | 2026-11-05T11:59:20.303289+00:00 | 2026-11-05T12:00:24.639752+00:00 | 64.336461 | 692 cases; exit 0 |

The recorded builds and focused checks pass after the compile fixes above and preserve the same 1165 source/build/document files;
the Linux wrappers verify both trees. The dedicated identity case contributes one new case. The existing
Windows fixture permission diagnostics remain explicit Unsupported observations. The change is
54 nonempty production lines in one module, with all 196 other production Haskell files and
702 compile-fail fixtures byte-preserved.

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T12:01:48.289417+00:00 | 2026-11-05T12:10:38.853188+00:00 | 530.563768 | 4391 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T12:01:48.289275+00:00 | 2026-11-05T12:10:17.492131+00:00 | 509.202858 | 167 demo cases and 4391 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T12:01:48.288826+00:00 | 2026-11-05T12:01:49.054942+00:00 | 0.766113 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T12:01:48.289194+00:00 | 2026-11-05T12:01:55.370049+00:00 | 7.080853 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 196 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The owned module changes 54 nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.39: One runtime-dependency coordinate opener [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Four coordinate checkers in this module are two pairs, each pair identical apart from one domain
literal. The module already demonstrates the fix two lines above them: the package openers beside these
share a parameterised implementation. The checkers were simply not given the same treatment, and the
cost is that a new requirement added to one does not apply to its twin.

#### Deliverables

- The coordinate and carried-coordinate checks are parameterised by domain, beside the package opener that already is.
- The four public names become applications of the two implementations.
- A requirement added once applies to every domain.

#### Validation

`openCoordinates` and `openCarriedCoordinates` sit beside `openPackage`, which already had this shape,
and take the domain as their first argument. The four public names are applications:
`withProviderRuntimeDependencyCoordinates` and `withClusterRuntimeDependencyCoordinates` open through the
first, `withCarriedProviderRuntimeDependencyCoordinates` and
`withCarriedProviderShareRuntimeDependencyCoordinates` through the second. Every `require` line and its
message is unchanged, and the comment explaining why a carried package does not equate plan identities
moved from inside one of the pair to the haddock of the implementation both now share.

A source guard asserts each implementation is named four times: its signature, its definition, and once
per domain that opens through it. That is the deliverable stated as a check — a requirement added to one
of the two reaches every domain, because there is no second place for a domain to be checked.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): the `runtime dependency
package` suite passed 10/10 under `cabal test all` from `core/`. The 2026-09-14 native run is recorded
in this phase's validation evidence.

#### Remaining Work

None.

### Sprint 15.40: The retained provider opens as well as closes [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`
**Production modules**: `HostBootstrap.Substrate.Provider.Backend` (1; cap 3)
**Sprint budget**: the retained readiness contract and its stop/delete peers, no new type; at most 35
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Retained reverse can make a stopped provider reachable before unwinding its children. Its readiness
operation derives claim and identity from the durable record, starts only the bound stopped instance,
and probes the guest rather than assuming a running instance answers. Stop and delete consume the
same retained authority and refuse a replacement.

#### Deliverables

- One retained operation that re-observes the record, starts the instance when it is stopped, and asks the
  guest itself whether it answers.
- It derives claim and identity from the durable record alone and refuses a replacement, exactly as its two
  peers do; no caller-supplied generation or owner is accepted.
- An instance that is running but not yet answering is polled rather than assumed ready.
- Direct and Lima answer the declared `Unsupported` refusals their peers already answer.

#### Validation

The nine-case retained provider group in `ProviderBackendSpec` drives the production operations
through `FakeProvider`'s compiled CLI client and the real protected store.

- Stop followed by readiness preserves the bound instance and exact record bytes, observes stopped
  then running, and records exactly one stop and one start.
- Two not-ready guest answers lead to three readiness probes and success without instance mutation.
  A terminal guest failure gives the exact structured failure after one probe.
- Separate stop, ready and delete cases replace only the instance's identity. Each requires the
  exact retained-provider conflict and preserves the full replacement, record bytes, mutation count
  and guest-probe history.
- An acknowledged stop whose raw listing still reports running produces the exact failed stop
  result and retains the record and instance.
- Direct and Lima each exercise all three retained operations against their declared Unsupported
  results. The Direct case also requires an empty tool-command history.

The stop-state fixture control changes only the CLI stand-in's raw state transition; it supplies
no ownership answer or injected production executor. No production source changes are required.
The final confirmed substrate gate belongs to Sprint 15.50.

Dated 2026-11-05 build and focused evidence uses GHC 9.12.4/Cabal 3.16.1.0 on
native x86_64 Windows and Ubuntu 24.04.5 x86_64 in the dedicated hostbootstrap-linux WSL2
distribution. Builds use `cabal build all --enable-tests`; the focused selection covers provider
backends, reconciliation, aliases, reports, resumption, authority, ownership, documentation,
and the isolated prepared-route runtime controls.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Native Windows core build | 2026-11-05T12:15:32.233355+00:00 | 2026-11-05T12:15:50.660267+00:00 | 18.426910 | all components, including the live client; exit 0 |
| Linux core build | 2026-11-05T12:15:32.236124+00:00 | 2026-11-05T12:16:27.261991+00:00 | 55.025867 | all components, including the live client; exit 0 |
| Linux demo build | 2026-11-05T12:15:32.253336+00:00 | 2026-11-05T12:16:03.996495+00:00 | 31.743158 | consumer and core components; exit 0 |
| Native Windows focused selection | 2026-11-05T12:16:39.352572+00:00 | 2026-11-05T12:18:50.459421+00:00 | 131.106845 | 701 cases; exit 0 |
| Linux focused selection | 2026-11-05T12:16:39.352800+00:00 | 2026-11-05T12:17:46.434183+00:00 | 67.081383 | 701 cases; exit 0 |

All commands pass on the first attempt and preserve the same 1165 source/build/document files;
the Linux wrappers verify both trees. The retained-operation group contributes nine cases. The existing
Windows fixture permission diagnostics remain explicit Unsupported observations. All 197 production Haskell files and
702 compile-fail fixtures are byte-preserved; changes are confined to the compiled test client,
the cases and governed documentation.

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T12:19:12.120465+00:00 | 2026-11-05T12:28:02.623124+00:00 | 530.502658 | 4400 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T12:19:12.126396+00:00 | 2026-11-05T12:27:37.777828+00:00 | 505.651433 | 167 demo cases and 4400 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T12:19:12.131330+00:00 | 2026-11-05T12:19:12.909699+00:00 | 0.778369 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T12:19:12.145655+00:00 | 2026-11-05T12:19:19.165584+00:00 | 7.019935 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 197 production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. No production source changes are required. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.41: The shipped symbolic-link row settles every crash window [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/architecture/durable_state.md`

#### Objective

The shipped symbolic-link take and give-back (the guest-alias owner's acts) leave nothing behind in any crash
window, and unlink only the identity they bound, observed immediately before the unlink.

#### Deliverables

- Give-back removes the staging link `<target>.hostbootstrap-shipped-<key>` for the bound identity before it
  forgets the record, on both the alias-absent and alias-exact branches, and refuses rather than forgets when
  the stage holds a different identity.
- Give-back unlinks the alias only after a fresh `lstat` taken immediately before `removeLink` shows the bound
  identity; that fresh observation, not the earlier one, is what `reobserveReportedIdentity` compares.
- A give-back over an unbound record (a take interrupted after origin publication) has one stated outcome: it
  removes a stage only if that stage is an exact link, forgets the record when the alias is absent, and refuses
  as `OwnershipConflict` when something stands at the alias.
- A give-back with no record refuses any occupant at the alias as `OwnershipOccupied` and leaves it in place.
- A record whose claim names another link target, or whose origin is not absent, is refused as
  `OwnershipMalformed` on take and give-back, and the other target's link and record survive.

#### Validation

`HostBootstrap.Ownership.Shipped` cleans a bound stage before forgetting an absent alias or unlinking an
exact alias. An unbound intent observes the alias first, refuses an occupant as a conflict, and
cleans only an exact staging link before forgetting an absent alias. No-record give-back and
record target/origin admission retain their declared refusal policies.

`removeExactSymbolicLink` receives the expected identity and target, observes the current link,
and applies a pure identity admission to that fresh sample before unlink. The alias path supplies
`reobserveReportedIdentity` as that admission and receives its releasable evidence from the
same sample. Staging cleanup also checks the fresh identity. Parent synchronization precedes
the successful result, including a staging name already absent after an interrupted unlink or move. No injected effect runner or additional ownership-row producer is added.

Sixteen new `ProviderAliasSpec` cases cover no-record occupants, unbound absence and occupancy,
bound staging cleanup with and without the alias, same-target inode replacements, target-claim and
origin refusals, exact unbound staging recovery, foreign staging files, and replaced bound stages.
Two new `OwnershipShippedSpec` cases independently check no-record give-back over an exact-looking
link and a regular file. A source guard holds the fresh-observation/admission/unlink path and the
absence of the entry-time identity check.

The existing origin-publication resume case now checks the link target, kernel identity, bound
record, absent stage and subsequent successful release. The pre-publication binding case returns
the staged identity and requires that exact identity at the published alias. Fixture claims use UTF-8.
Linux fixtures can keep stage and alias as two names for the bound symlink inode; the Darwin fixture
moves the staging name as its actual publisher does. Every case is present on Windows and applies the
existing declared Unsupported path where symbolic-link ownership is unavailable.

The initial 2026-11-05 builds pass without warnings: native Windows at 12:47:14 UTC
(79.920077 seconds), Linux core at 12:47:44 UTC (109.708700 seconds), and Linux demo
at 12:47:16 UTC (81.933022 seconds). The final cleanup also synchronizes the parent of an
already-absent staging name; the source guard includes that interruption boundary.
The complete build and test evidence for that final tree remains owed.

Dated 2026-11-05 initial focused runs each report one failure out of 784 checks: the conditional
family registry declares five provider-alias kernel/refusal cases while the expanded tree carries
twenty-one. Linux exits 1 at 12:53:33 UTC (67.291511 seconds), and Windows exits 1 at
12:54:38 UTC (132.826307 seconds). All other selected cases pass, including the recovery assertions.
`CoverageManifest` now declares 21 total and 21 row/refusal cases for the same conditional family;
its reason names the platform's no-replace publication rather than requiring a hard-link realization.

Dated 2026-11-05 build and focused evidence uses GHC 9.12.4/Cabal 3.16.1.0 on
native x86_64 Windows and Ubuntu 24.04.5 x86_64 in the dedicated hostbootstrap-linux WSL2
distribution. Builds use `cabal build all --enable-tests`; the focused selection covers provider
backends, reconciliation, aliases, reports, resumption, authority, ownership, documentation,
the shipped ownership row, and the isolated prepared-route runtime controls.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Native Windows core build | 2026-11-05T12:56:16.481083+00:00 | 2026-11-05T12:56:24.084563+00:00 | 7.603478 | all components, including the live client; exit 0 |
| Linux core build | 2026-11-05T12:56:16.493561+00:00 | 2026-11-05T12:56:22.909491+00:00 | 6.415927 | all components, including the live client; exit 0 |
| Linux demo build | 2026-11-05T12:56:16.508274+00:00 | 2026-11-05T12:56:23.274651+00:00 | 6.766376 | consumer and core components; exit 0 |
| Native Windows focused selection | 2026-11-05T12:56:31.643975+00:00 | 2026-11-05T12:58:43.609154+00:00 | 131.965175 | 784 cases; exit 0 |
| Linux focused selection | 2026-11-05T12:56:31.673577+00:00 | 2026-11-05T12:57:39.452956+00:00 | 67.779375 | 784 cases; exit 0 |

The final builds and focused checks pass after the family declaration update and preserve the same 1165 source/build/document files;
the Linux wrappers verify both trees. The sprint contributes nineteen cases, including the fresh-observation source guard. The existing
Windows fixture permission diagnostics remain explicit Unsupported observations. The change is
127 nonempty production lines in one module, with all 196 other production Haskell files and
702 compile-fail fixtures byte-preserved.

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T12:59:57.606457+00:00 | 2026-11-05T13:08:57.102155+00:00 | 539.495696 | 4419 cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T12:59:57.606557+00:00 | 2026-11-05T13:08:33.151491+00:00 | 515.544935 | 167 demo cases and 4419 core cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T12:59:57.606638+00:00 | 2026-11-05T12:59:58.771699+00:00 | 1.165061 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T12:59:57.613461+00:00 | 2026-11-05T13:00:05.055640+00:00 | 7.442182 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both
source trees. The Python coverage report has 1585 statements and 460 branches, all covered.
The Cabal runs hold -Werror. The ordinary provider-live component compiles and reports
Unsupported without confirmation; Sprint 15.50 owns the finished phase's confirmed gate.
All 196 other production Haskell files under src/internal and 702 compile-fail fixtures match
the sprint baseline. The owned module changes 127 nonempty lines. Scoped LF and diff checks pass.

#### Remaining Work

None.

### Sprint 15.42: Guest-VM observations use the common report boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/FakeProvider.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

The Lima and WSL2 realization reads provider reports through the common total classifier. Its static
cases execute compiled fake clients with the same argv and stream boundary as installed clients.

#### Deliverables

- Guest commands, existence, readiness, share probes and bound guest-VM host-tool requests reach
  `classifyProviderReport` before an outcome is admitted. Noisy success and control characters are
  refused; a readiness command's ordinary non-zero exit remains NotReady. `firstDiagnosticLine` is absent.
- The WSL2 existence probe treats the recognized no-installed-distributions outcome as an empty member
  list. Other non-zero list outcomes are failures. Recognition uses the existing
  `Ensure.Wsl2.wslReportsNoInstalledDistributions` vocabulary.
- The retained writable share's host root participates in the guest-VM fingerprint.
- Compiled fake Lima and WSL2 roles implement only declared CLI vectors and record complete argv.

#### Validation

The implementation reuses `classifyProviderReport` in the existing report module; it adds no second
report parser. Existence, effects, readiness, guest share commands and bound guest-VM host-tool requests
all reach that boundary. Failed process diagnostics use its bounded, control-free rendering.
The old first-line helper is absent. WSL name-list normalization removes only its NUL padding before
the common report checks; other control characters refuse. The existing host-root fingerprint is
held by an additional changed-host-root assertion.

ProviderBackendSpec adds 43 real-process cases. Both compiled-client rows cover noisy/control/overlong
and failed listings, quiet CRLF membership, a failed readiness probe followed by success, malformed
readiness and guest discovery, directory/writable share probes, failed writable access and changed
share source/target. Discovery refusal preserves the failed VM observation through the unrun suffix;
the exact recorded argv proves that egress did not run. Lima additionally covers failed/noisy launch
and successful launch followed by an independent existence confirmation. WSL covers NUL-padded names
and the recognized no-distributions response. That last case proves absence reaches the declared
provisioning-effect boundary; global-wall acquisition and owned installation remain in Sprint 15.42c.

Each fixture is this suite's compiled executable under its provider role. Its declared raw argv/status/
streams sequence refuses unexpected vectors; every case checks complete command history and sequence
consumption. It produces no semantic reconciliation or ownership answer.

The first documentation selection reports a missing deleting-phase link in the new ledger row; the
link is present before subsequent selections. Initial builds on all three targets report a fixture
variable shadowing System.Directory's selector. A subsequent share-test build reports the missing
prior-proof argument to `settleProviderShare`. Both fixture errors are fixed before the successful
builds below. The first 233-case selections on Linux and Windows report 22 expectation failures:
recovery disposition and discovery's unrun suffix. The assertions now hold the existing exact
ReprobeBeforeRetry policy and short-circuit behavior. No production policy is weakened.

The change is 72 changed non-empty production Haskell lines in one module. All 196 other production
modules and all 702 compile-fail fixtures retain their baseline bytes. The focused selection contains
247 cases, including all 17 documentation cases, and passes on both native hosts. GHC 9.12.4 and
Cabal 3.16.1.0 compile the core on Windows and the core/demo workspaces on Linux.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T14:26:58.727484+00:00 | 2026-11-05T14:27:14.096658+00:00 | 15.369183 | PASS; exit 0 |
| Linux demo build | 2026-11-05T14:26:58.727570+00:00 | 2026-11-05T14:27:14.377510+00:00 | 15.649941 | PASS; exit 0 |
| Windows core build | 2026-11-05T14:26:58.727392+00:00 | 2026-11-05T14:27:16.660210+00:00 | 17.932816 | PASS; exit 0 |
| Linux focused report/backend/documentation selection | 2026-11-05T14:27:35.533887+00:00 | 2026-11-05T14:28:06.006961+00:00 | 30.473072 | 247 cases pass; exit 0 |
| Windows focused report/backend/documentation selection | 2026-11-05T14:27:35.533075+00:00 | 2026-11-05T14:28:44.591281+00:00 | 69.058203 | 247 cases pass; exit 0 |

The complete four-command host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T14:29:50.980913+00:00 | 2026-11-05T14:38:47.306860+00:00 | 536.325947 | 4462 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T14:29:50.980830+00:00 | 2026-11-05T14:38:22.682954+00:00 | 511.702120 | 4462 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T14:29:50.985504+00:00 | 2026-11-05T14:29:52.177818+00:00 | 1.192313 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T14:29:51.003689+00:00 | 2026-11-05T14:29:58.629894+00:00 | 7.626204 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1165 source/build/document files before and after in both source
trees. Python coverage includes all 1585 statements and 460 branches. Cabal holds -Werror.
The ordinary provider-live component compiles and exercises its declared unconfirmed result;
Sprint 15.50 owns the finished phase's confirmed native gate. All 196 other production Haskell
modules and 702 compile-fail fixtures match the baseline. The changed files retain LF endings.

#### Remaining Work

None.

### Sprint 15.42a: A directory lease encloses the guest-VM namespace [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`, `core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

An opaque scoped directory lease keeps the protected entry live through a guest-VM transaction.

#### Deliverables

- Shared directory acquisition serves ordinary shipped directory take and scoped acquisition.
- The lease is nominal and is produced only after origin recording and identity binding, or recorded
  re-entry. The entry encloses the entire callback. Effect-bearing use checks entry liveness and the
  directory's actual identity.

#### Validation

`withShippedDirectoryLease` consumes a directory-take transaction, invokes the ordinary
`inEntry` acquisition, reads its matching bound directory record from the same entry's tape, and
re-enters the existing bound kernel token. The protected entry surrounds the complete callback.
`useShippedDirectoryLease` re-observes that live thread's directory identity before and after its
action. The fresh nominal lease hides its existential entry/object indices and constructor fields.
`runShippedOwnership` and lease acquisition share one receiving-frame validation and entry helper.

OwnershipShippedSpec adds 13 cases. Fresh and retained acquisition check the actual kernel identity and
bound record; unrecorded occupied and occupied unbound directories receive no callback; an absent
unbound record resumes through shared acquisition. Same-path replacements before callback, before use,
and during use produce the exact expected/observed identity conflict. The original directory is kept
under another name so kernel identity reuse cannot make a replacement fixture ambiguous.
An escaped action refuses after entry close; another thread refuses before its action. Three actual
child-process entry probes return contention across the callback and nested use, and a probe after
return acquires the entry. A non-IO callback exception propagates, releases the entry, and preserves
the recorded directory. A non-directory transaction refuses before opening an authority. Unsupported
hosts execute the lease producer and assert its actual refusal and an uncalled callback.

Four new compile-fail fixtures refuse construction, private field update, nominal coercion and rank
scope escape. The positive compiler control uses scoped acquisition and the effect-bearing eliminator.
The export inventory names the three public lease surfaces. All 702 pre-existing compile-fail fixtures
retain their bytes; the directory now contains 706 fixtures. The change is 99 changed non-empty production
Haskell lines in one module, with all 196 other production modules preserved.

All three builds and both 158-case focused selections pass on their first run. The selection covers
OwnershipShippedSpec, all 22 DocValidatorSpec cases, fixture inventory, the new compiler refusals and
their positive control. GHC 9.12.4/Cabal 3.16.1.0 hold -Werror on native Windows and Linux.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T15:51:03.623611+00:00 | 2026-11-05T15:53:31.125483+00:00 | 147.501868 | PASS; exit 0 |
| Linux demo build | 2026-11-05T15:51:03.623685+00:00 | 2026-11-05T15:52:57.975873+00:00 | 114.352188 | PASS; exit 0 |
| Windows core build | 2026-11-05T15:51:03.623772+00:00 | 2026-11-05T15:53:00.602472+00:00 | 116.978703 | PASS; exit 0 |
| Linux focused ownership/compiler/documentation selection | 2026-11-05T15:53:38.181952+00:00 | 2026-11-05T15:53:46.867622+00:00 | 8.685668 | 158 cases; exit 0 |
| Windows focused ownership/compiler/documentation selection | 2026-11-05T15:53:38.181865+00:00 | 2026-11-05T15:53:50.280514+00:00 | 12.098647 | 158 cases; exit 0 |

The first complete Linux gates on 2026-11-05 each report one failure among 4485 core cases:
OwnershipSpec's stored-origin source guard counts the whole module's tape reads, so the new lease's
legitimate read changes its expected count. The guard now checks the two reads inside the ordinary
entry and the lease's separate read, its stored re-entry, and all kind/origin/binding policy checks.
Its exact give-back assertion and whole-boundary refusal of the former unrecorded re-entry remain.
The other 4484 core cases and all 167 demo cases pass in those runs. Python checks and all 376 Python
cases also pass. The initial complete core run takes 686.511396 seconds; the demo workspace run takes
648.639860 seconds. The complete gate is rerun after the scoped guard change.

The scoped guard change compiles on all three targets. The expanded selection includes all
OwnershipSpec cases as well as the original ownership/compiler/documentation selection:
all 253 cases pass on Linux and Windows. Production bytes remain unchanged.

| Rebuild or expanded selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core rebuild | 2026-11-05T16:08:34.141489+00:00 | 2026-11-05T16:09:29.032168+00:00 | 54.890677 | PASS; exit 0 |
| Linux demo rebuild | 2026-11-05T16:08:34.141084+00:00 | 2026-11-05T16:09:03.316886+00:00 | 29.175799 | PASS; exit 0 |
| Windows core rebuild | 2026-11-05T16:08:34.141256+00:00 | 2026-11-05T16:08:48.478763+00:00 | 14.337513 | PASS; exit 0 |
| Linux expanded ownership/compiler/documentation selection | 2026-11-05T16:09:51.325434+00:00 | 2026-11-05T16:10:06.903270+00:00 | 15.577832 | 253 cases; exit 0 |
| Windows expanded ownership/compiler/documentation selection | 2026-11-05T16:09:33.785966+00:00 | 2026-11-05T16:09:54.193320+00:00 | 20.407355 | 253 cases; exit 0 |

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in the dedicated hostbootstrap-linux
WSL2 distribution, Ubuntu 24.04.5 x86_64, as hostbootstrap (UID 1000), with
GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T16:13:33.175186+00:00 | 2026-11-05T16:23:07.646620+00:00 | 574.471431 | 4485 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T16:13:33.183666+00:00 | 2026-11-05T16:22:41.848047+00:00 | 548.664381 | 4485 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T16:13:33.175265+00:00 | 2026-11-05T16:13:34.009729+00:00 | 0.834463 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T16:13:33.206372+00:00 | 2026-11-05T16:13:40.581941+00:00 | 7.375569 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1169 source/build/document files before and after in both source
trees. Python coverage includes all 1585 statements and 460 branches. Cabal holds -Werror.
The ordinary provider-live component compiles and exercises its declared unconfirmed result;
Sprint 15.50 owns the finished phase's confirmed native gate. All 196 other production Haskell
modules and all 702 pre-existing compile-fail fixtures match the baseline. Four new fixtures bring
the fixture directory to 706 files. The changed files retain LF endings.

#### Remaining Work

None.

### Sprint 15.42b: Native WSL registration is an observed identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

The Windows host observes the current WSL registration through the native registry API.

#### Deliverables

- The production reader uses the fixed WSL registration namespace and Unicode registry values.
  The borrowed-key reader holds fixed bounds of 1024 registrations and 4096 bytes per text value;
  the classifier preserves exact names and refuses case aliases instead of treating them as absence.
  It validates the registration identifier and install location and refuses duplicate, malformed or
  inaccessible observations. Other hosts return the declared Unsupported result.
- A generic read-only registry reader is exercised against an owned scratch registry subtree.
  The production query has no mutable fixture root or injected executor.

#### Validation

The fixed production query reads the current user's WSL registry namespace through Unicode Win32 calls.
Only an absent namespace is an empty observation. The borrowed-key observer closes no caller handle and
writes no registry state. It admits at most 1024 registrations and 4096 bytes per string, reads the
DWORD version with its native type, and refuses incomplete, wrongly typed, overlong or invalid UTF-16
values. The pure classifier admits a canonical braced GUID, exact name, WSL2 version and bounded
absolute Windows install path. Case aliases and duplicate names are explicit refusals.

Wsl2Spec adds 28 portable classifier cases: absent and unrelated registrations, exact GUID/path
preservation, GUID case normalization, Unicode, duplicate and case-ambiguous names, count bounds,
invalid requested names, unreadable names, non-WSL2 versions, malformed GUIDs and invalid install paths.
Nine real Windows registry cases cover an empty key, Unicode, duplicates, missing values, wrong types,
invalid UTF-16, oversized text, a handle without read rights and repeated use of the borrowed handle.
Each creates a fresh uniquely named scratch subtree, verifies creation, and removes its own children
and parent after the case. The limited-rights case changes no ACL. No fixture registers a distribution
or changes the real WSL namespace. On Linux each native case executes the actual Unsupported row;
the cases remain in the same test tree. A tenth case holds the fixed query's source boundary and
absence of process/environment imports. The live production query and VM lifecycle remain native
acceptance subjects.

The implementation adds one production module with 195 non-empty Haskell lines. All 197 existing
production modules and all 706 compile-fail fixtures retain their baseline bytes. The main package
exposes the observation module, the export inventory pins its ordinary data and read-only surfaces,
and only Windows builds depend on the native SDK and its ExceptT helper dependency.
All three builds pass on their first run. The 96-case focused selection passes on Linux and Windows,
including all 22 documentation checks, export pins and the module inventory. Native Windows runs
the nine real registry cases through Win32 2.14.2.1; both hosts use GHC 9.12.4/Cabal 3.16.1.0.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T16:41:15.102872+00:00 | 2026-11-05T16:42:32.946657+00:00 | 77.843785 | PASS; exit 0 |
| Linux demo build | 2026-11-05T16:41:15.102559+00:00 | 2026-11-05T16:42:02.160337+00:00 | 47.057776 | PASS; exit 0 |
| Windows core build | 2026-11-05T16:41:15.110463+00:00 | 2026-11-05T16:43:15.232976+00:00 | 120.122523 | PASS; exit 0 |
| Linux focused registration/documentation/export selection | 2026-11-05T16:50:51.159731+00:00 | 2026-11-05T16:51:01.394784+00:00 | 10.235051 | 96 cases; exit 0 |
| Windows focused registration/documentation/export selection | 2026-11-05T16:50:51.159816+00:00 | 2026-11-05T16:51:02.394446+00:00 | 11.234631 | 96 cases; exit 0 |

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T16:52:16.957617+00:00 | 2026-11-05T17:02:51.567139+00:00 | 634.609518 | 4523 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T16:52:16.957913+00:00 | 2026-11-05T17:02:23.967302+00:00 | 607.009382 | 4523 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T16:52:16.957991+00:00 | 2026-11-05T16:52:18.205077+00:00 | 1.247086 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T16:52:16.957690+00:00 | 2026-11-05T16:52:24.689277+00:00 | 7.731589 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1170 source/build/document files before and after in both trees.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. All 197 pre-existing production
Haskell modules and 706 compile-fail fixtures match the baseline. The added production module has 195
non-empty lines. Changed files retain LF endings. The unconfirmed provider-live component compiles
and exercises its declared result; Sprint 15.50 owns the finished phase's confirmed native gate.

#### Remaining Work

None.

### Sprint 15.42c: Guest-VM reports carry current identity and creation claims [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`,
`core/hostbootstrap-core/test/ProviderCommandSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

The guest-VM transaction consumes bounded current provider data and creation commands that carry
its recorded claim without changing a pre-existing instance.

#### Deliverables

- The common report boundary classifies exact Lima JSON instance rows into name, lifecycle state,
  native instance-directory path and the claim carried in creation metadata. Absence, duplicate rows,
  malformed fields, unknown states and stream failures are explicit results.
- The WSL registration observation supplies its GUID and install path. A location claim identifies
  only the exact owned install location; name-only matches supply no creation claim.
- Lima creation uses a closed create-only command and a structured configuration on stdin, with the
  claim in ordinary environment metadata, the admitted envelope and exact writable mount.
  Existing-instance readiness uses a separate start command. No shell or template program is shipped.
- WSL creation names the exact owned install location and the declared distribution and disk budget.
  Its native registry identity is observed separately from the command's acknowledgement.

#### Validation

The report classifier consumes native newline-delimited JSON through the common stream boundary.
It selects only the exact name, retains Running/Stopped and the bounded absolute directory, and reads
the creation claim from ordinary environment metadata. The directory remains an observation that
needs a kernel identity; no report grants ownership. Escaped controls are checked after decoding,
and raw controls are refused before decoding. Native errors, duplicate exact rows and malformed data
are explicit refusals. The WSL location comparison preserves the original registration observation and
admits only the equivalent owned location, including extended drive and UNC spellings; the transaction
separately binds its GUID.

ProviderReportSpec adds 40 cases: absent/exact/prefix/duplicate rows, lifecycle state, directory and
claim preservation, Unicode, field/type/syntax errors, path and claim bounds, native error reports,
stream failures, raw and escaped controls, and six exact/equivalent/foreign WSL location comparisons.
ProviderCommandSpec adds six cases. Exact argv separates create-only, start and WSL install, and
decoded JSON equality holds the claim, budget, one writable mount, image-only base and disabled
containerd. Paths with spaces, quotes, Unicode and backslashes remain data on stdin. No shell or
provisioning program crosses the boundary.

The change is 148 changed non-empty production Haskell lines across Report.hs and Command.hs.
All 196 other production modules and all 706 compile-fail fixtures retain their baseline bytes.
The export inventory pins every added ordinary report projection and closed command function.

Initial builds on Linux core, Linux demo and Windows report the missing OverloadedStrings pragma
for Command.hs's JSON keys. The pragma is present before successful builds.
The first 373-case focused selections report two expectation failures on both hosts: Aeson emits
U+202E directly, so the common stream check refuses it before the field parser. The fixtures now
explicitly escape that format control, and a separate case holds the raw-wire refusal. All 374 focused
cases then pass on both hosts, including existing provider/backend cases, all 22 documentation checks
and sealed exports. GHC 9.12.4/Cabal 3.16.1.0 hold -Werror on Linux and Windows.

| Build or selection, 2026-11-05 | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| Linux core build | 2026-11-05T17:17:41.671639+00:00 | 2026-11-05T17:17:51.301203+00:00 | 9.629563 | PASS; exit 0 |
| Linux demo build | 2026-11-05T17:17:41.671952+00:00 | 2026-11-05T17:17:51.304025+00:00 | 9.632072 | PASS; exit 0 |
| Windows core build | 2026-11-05T17:17:41.671820+00:00 | 2026-11-05T17:17:51.676310+00:00 | 10.004490 | PASS; exit 0 |
| Linux focused provider/report/command/export/documentation selection | 2026-11-05T17:18:15.183774+00:00 | 2026-11-05T17:19:15.714641+00:00 | 60.530868 | 374 cases; exit 0 |
| Windows focused provider/report/command/export/documentation selection | 2026-11-05T17:18:15.183685+00:00 | 2026-11-05T17:19:39.015741+00:00 | 83.832053 | 374 cases; exit 0 |

The complete host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T17:20:43.766314+00:00 | 2026-11-05T17:31:48.956050+00:00 | 665.189737 | 4569 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T17:20:43.765921+00:00 | 2026-11-05T17:31:10.183055+00:00 | 626.417130 | 4569 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T17:20:43.766047+00:00 | 2026-11-05T17:20:45.074285+00:00 | 1.308239 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T17:20:43.766171+00:00 | 2026-11-05T17:20:51.680122+00:00 | 7.913955 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1170 source/build/document files before and after in both trees.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. All 196 other production
Haskell modules and 706 compile-fail fixtures match the baseline. The two owned modules change 148
non-empty production Haskell lines. Changed files retain LF endings. The unconfirmed provider-live component compiles
and exercises its declared result; Sprint 15.50 owns the finished phase's confirmed native gate.

#### Remaining Work

None.

### Sprint 15.42d: A guest-VM transaction holds its recorded identity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/FakeProvider.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

The guest-VM driver holds the four ownership clauses over the current VM and dependent guest work.

#### Deliverables

- An owned directory lease encloses the reported-object transaction and its distinct protected VM
  record entry. Shared tape and reported-object primitives record absence before creation and bind
  the current kernel directory or native registration identity durably before adoption.
- Lima creation metadata and instance-directory identity, or the exact owned WSL install location
  and native GUID, prove the current VM. Unmarked, name-only, stale or ambiguous instances refuse.
- Every dependent effect checks the parent's live lease and current VM identity before and after
  use. A same-name replacement cannot inherit an earlier record or receive a mutation.
- Interrupted creation resumes only from recorded origin and the native claim; failure and
  outcome-unknown windows retain the record needed for an explicit retry.

#### Validation

Real-kernel/store cases with compiled CLI clients cover fresh, retained, foreign and replaced
instances, launch failure, missing or changed claims, interrupted origin/binding windows,
parent replacement and dependent-use refusal. Native registration remains a real Windows subject;
no fixture prints an authoritative GUID or plants a WSL registration. Pure recovery cases hold the
shared standing vocabulary. Run the focused selections and all four host-static commands.
Split the implementation further before exceeding the production module or line budget.

The driver, compiled Lima fixture and 22 transaction cases are implemented. On 2026-11-05, plain
`cabal build all --enable-tests` passed in Linux `core/` and `demo/` and native Windows `core/`.
The first focused selection passed all 371 cases on Windows; Linux correctly refused the new
namespace key's unsupported colon before any VM work, failing 22 of 371 cases. The key now uses
the shared record grammar. The initial builds also caught resource String/Text conversion,
the terminating fixture's result type, and fixture type-default/name-shadow warnings; those
were corrected before the passing builds.

The final focused selection passed all 371 cases on Linux (33.32 seconds reported) and native
Windows (70.96 seconds reported), including all 22 new transaction/platform-refusal cases.
The concurrency control now requires one creation, retained admission or the exact native
busy-lock refusal, and a successful explicit retry. The driver adds 279 non-empty production
Haskell lines in one module; all 198 pre-existing production modules and all 706 compile-fail
fixtures retain their baseline bytes. The source snapshot has 1,171 exact files on both hosts.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T17:59:57.927383+00:00 | 2026-11-05T18:09:25.429149+00:00 | 567.558855 | 4591 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T17:59:57.927179+00:00 | 2026-11-05T18:08:59.399969+00:00 | 541.527257 | 4591 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T17:59:57.925511+00:00 | 2026-11-05T17:59:59.174721+00:00 | 1.249334 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T17:59:57.927460+00:00 | 2026-11-05T18:00:05.682169+00:00 | 7.755492 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1171 source/build/document files before and after in both trees.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. All 198 pre-existing
production Haskell modules and all 706 compile-fail fixtures match the baseline. The one added
production module has 279 non-empty Haskell lines. Changed files retain LF endings. The unconfirmed
provider-live component compiles and exercises its declared result; Sprint 15.50 owns the finished
phase's confirmed native gate.

#### Remaining Work

None.

### Sprint 15.42e: The guest-VM backend consumes the owned transaction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/FakeProvider.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`,
`documents/architecture/ownership_invariant.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Provisioning, forward readiness, share probing and bound guest work consume the same recorded VM.

#### Deliverables

- Backend provisioning reports Created or AlreadyOwned only from the recorded transaction; it
  refuses an unmarked pre-existing VM and emits no mutation. No listed-name adoption remains.
- Forward readiness starts an owned Stopped Lima instance exactly once and a Running instance zero
  times before the bounded guest poll. WSL startup and its global wall retain their typed owners.
- Bound guest work and share probes keep the admitted parent and VM identities throughout the effect.
  Foreign host tools, Direct probes and malformed guest argv refuse before process launch.
- Forward stop/delete keep their exact Unsupported policy. Native-only evidence is owned by the
  corresponding terminal substrate acceptance phase.

#### Validation

Compiled-client backend cases cover fresh/retained/foreign ownership, failed launch, stopped/running
start counts, bounded timeout, share source/target mismatch, report refusals and same-name or parent
replacement. Exact command histories prove pre-launch refusal. Forward stop/delete assert their
structured Unsupported results. Adapt earlier report fixtures to valid owned setup without weakening
native identity admission. Run focused Linux and Windows selections and all four host-static commands.

Implemented on 2026-11-05. Backend provisioning, readiness, share probes,
bound guest work and the fixed daemon probe now enter the recorded guest-VM transaction.
The compiled fixture creates real Lima directories and ordinary creation metadata; native WSL
cases query the fixed registry and cannot substitute a CLI success for registration identity.
Initial Linux core/demo and Windows core builds caught retained-readiness owner threading and
Natural/Word64 CPU conversion. Those were corrected with an explicit width check; the following
build identified two imports made obsolete by deleting the unrecorded execution path.
The corrected plain builds pass on Linux core/demo and Windows core. The first focused selection
passed all 394 Windows cases and 392 of 394 Linux cases. Linux's two failures were new-test
expectations for the established fenced timeout retry and the exact forward-handle stop label.
Those expectations are corrected; public wrong-provider/Direct/VM-name and CPU-overflow refusal
controls are added. The final focused selection and complete host-static gate are recorded below.
The production change is 198 non-empty lines across two modules, within the sprint budget.
The obsolete name-only backend helpers and their ledger row are removed.

The final focused selection passes all 398 cases on Linux (93.26 seconds reported) and native
Windows (66.07 seconds reported). The Linux run includes all sixty real readiness probes and its
one-second waits. Public wrong-provider, Direct and VM-name routes refuse before any process or
capability callback; CPU overflow refuses before conversion or client launch. The Windows WSL
cases use real fixed-namespace registration reads and a compiled install client, leave all actual
registrations unchanged, and refuse to bind a quiet CLI answer without a native registration.
The final owned-file whitespace check passes.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T18:34:38.689159+00:00 | 2026-11-05T18:46:13.308229+00:00 | 694.652752 | 4588 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T18:34:38.689307+00:00 | 2026-11-05T18:45:34.358955+00:00 | 655.701891 | 4588 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T18:34:38.689780+00:00 | 2026-11-05T18:34:39.970742+00:00 | 1.281028 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T18:34:38.701805+00:00 | 2026-11-05T18:34:46.611864+00:00 | 7.910469 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1171 source/build/document files before and after in both trees.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. The production change is
198 non-empty Haskell lines across Backend (192) and GuestVm (6); all 197 other production modules
and all 706 compile-fail fixtures retain baseline bytes. Changed files retain LF endings.
Earlier raw name-list fixtures are replaced by recorded native-directory setup and fixed-query WSL
origin/refusal cases. The unconfirmed provider-live component compiles and exercises its declared
result; Sprint 15.50 owns the finished phase's confirmed native gate.

#### Remaining Work

None.

### Sprint 15.43: A carried provider handle's phase comes from fresh evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/internal/provider-start/HostBootstrap/Reconcile/ProviderStart/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

A managed handle carried from a parent frame keeps the phase its evidence names. The `Running` index of a
recovered provider dependency, and the `Provisioned` index of a recovered provider-share dependency, are
minted only after the fresh package probe has answered the handle's own generation, never chosen by the
continuation that rebinds the handle.

#### Deliverables

- `withPlannedReboundManagedResourceEvidence` in `Reconcile.hs` hands its continuation a
  `ResourceHandle scope planId id resource Managed oldPhase`: the phase index is the old handle's, so the
  continuation cannot pick one. Under `withCarriedManagedResourceReceipt` that phase is existential.
- One package-private producer turns a rebound handle into the `Running` (provider) or `Provisioned` (share)
  handle, and takes the generation the fresh `invokePackageProbe` returned. It refuses with `Conflict`
  when that generation differs from the handle's.
- `withFreshCarriedRunningProviderDependency`, `withFreshCarriedProviderShareDependency`, and
  `withFreshRunningProviderHandle` in `Provider/Reconcile.hs` mint
  `RecoveredRunningProviderDependency`, `RecoveredProviderShareDependency`, and the Running managed
  provider handle only through that producer, after the fresh probe.

#### Validation

Closure requires these cases, under `cabal test all` from `core/`:

- a compile-fail fixture `test/compile-fail/ReboundHandleChoosesPhase.hs`, registered in `CompileFailSpec`
  with `rejectsWith`, that passes a `Managed Provisioned` handle to
  `withPlannedReboundManagedResourceEvidence` with a continuation typed at `Managed Running` and is rejected
  with a `Couldn't match type` phrase naming the phase index;
- the existing `ProviderBackendSpec` running-dependency and carried provider-share cases (the
  `withFreshRunningProviderDependency` and `withFreshCarriedProviderShareDependency` call sites) pass
  unchanged;
- a `ProviderBackendSpec` case where the carried provider package's fresh probe answers a generation other
  than the carried handle's: `withFreshCarriedRunningProviderDependency` returns `Left (Conflict ...)` and the
  continuation never runs.

Implemented on 2026-11-05. Rebinding preserves the old phase. A single fresh
generation producer uses the same sealed-entry pattern as provider-start projection: its authority
constructor stays in the package-private module, so an ordinary client cannot choose a new phase.
All three recovery paths use that producer after the real package invocation. Two compile-fail
fixtures cover choosing Running during rebind and calling the producer without its private authority.
The runtime negative case supplies only a canonical raw generation field at the named dependency
probe response boundary; it retains real registration, carriage, request verification and invocation,
and requires Conflict with zero recovery callbacks. The first Linux core/demo and Windows core
builds compiled the production change but rejected the test's hidden execution-module import.
The fixture now borrows its existing scoped carrier representation; package visibility is unchanged.
The corrected plain Linux core/demo and Windows core builds pass. The raw response fixture invokes
the retained real probe before changing only its final generation field from 17 to 18, preserving
the real domain, commitment and nonce. The first focused selections passed 292 of 294 cases on
each host, including the runtime mismatch and unchanged dependency/share cases. The two new
negative programs failed for the intended phase/private-authority reasons; their registrations
incorrectly requested distinct diagnostic blocks for fragments of one error. Each registration now
pins one complete diagnostic. The corrected negative-client and documentation selection passes all 24 cases on Linux
(6.55 seconds reported) and native Windows (8.14 seconds reported). The other 292 focused cases,
including the exact generation Conflict with one real probe and zero recovery callbacks, passed
unchanged on both hosts. The production change is 104 non-empty Haskell lines across three modules;
all 196 other production modules and all 706 prior compile-fail fixtures retain baseline bytes.
The source snapshot has 1173 files, including the two added negative clients. The complete
host-static gate is recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T19:11:21.916962+00:00 | 2026-11-05T19:23:35.159644+00:00 | 733.259519 | 4591 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T19:11:21.917267+00:00 | 2026-11-05T19:22:50.813970+00:00 | 688.912693 | 4591 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T19:11:21.917408+00:00 | 2026-11-05T19:11:23.244001+00:00 | 1.326627 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T19:11:21.916744+00:00 | 2026-11-05T19:11:29.741585+00:00 | 7.825050 | 376 cases; 100% coverage; exit 0 |

All four commands verify the same 1173 source/build/document files before and after in both trees.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. The production change is
104 non-empty Haskell lines across Reconcile (22), Provider/Reconcile (78) and the private
projection-authority module (4). All 196 other production modules and all 706 prior compile-fail
fixtures retain baseline bytes; the two new negative clients bring that fixture set to 708. Changed files retain LF endings.
The existing running/provider-share recovery cases and the raw-response generation mismatch pass.
The latter invokes the real retained service and changes only its ordinary generation wire field;
the fresh-generation producer returns Conflict with zero recovery callbacks. The unconfirmed provider-live component compiles and exercises its declared
result; Sprint 15.50 owns the finished phase's confirmed native gate.

#### Remaining Work

None.

### Sprint 15.44: The fake host tools render one answer on every host [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/Fixture.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

The spec-written host tools that `ProviderReconcileSpec` and `ClusterReconcileSpec` resolve through
`hcToolPaths` print exactly the text they were given on a POSIX host and on Windows, carry no exported
helper that no case uses, and are documented as what they are: stand-in executables whose answer a spec
chose, not evidence of a real provider's behaviour.

#### Deliverables

- `fakeToolProgram` and `exhaustingToolProgram` escape their text the same way `recordingToolProgram` does. On Windows, each output line is `echo(` plus the cmd-escaped
  text (`^`, `%`, `&`, `|`, `<`, `>`), through one shared `escapeCmdEcho`. On POSIX, the text is
  single-quoted with each `'` written as `'\''` rather than quoted with `show`, so `$` and backticks are not
  expanded and non-ASCII characters are not turned into decimal escapes.
- `newRefusingFakeTool` and `refusingToolProgram` are deleted with their export, since no spec calls them.
  The egress-unavailable and daemon-stopped contracts their comment describes are the `FakeProvider`
  behaviours Sprint 15.32 exercises.
- The Haddocks of `newFakeTool`, `newExhaustingFakeTool`, and `newRecordingFakeTool` say these are stand-in
  executables a spec writes and production resolves through `hcToolPaths`. What a case using them proves is
  the code's reaction to a scripted exit status and output, not a real `docker` or `incus` answer, and the
  Haddocks cite no § NN reason for treating them as real programs.

#### Validation

Closure requires these `ProviderReconcileSpec` cases under `cabal test all` from `core/`, on a POSIX gate
host and on Windows. A tool written by `newFakeTool` reports the JSON object whose one member `a` holds
`b>c`, followed by `$HOME`, a backtick, `50%`, `&`, `|`, and `^`. Launched through `interpretHostCommand`
with the tool resolved in `hcToolPaths`, it prints exactly that text plus a newline, and the tool directory
gains no file. A tool written by `newExhaustingFakeTool` with the same text as its first report and its later
diagnostic returns that text exactly on the first call's standard output and the second call's standard
error. On a POSIX host the report also carries `é`, which comes back as that character rather than as
`\233`. A source guard asserts that no file under `core/hostbootstrap-core/test/` names
`newRefusingFakeTool`.

Implemented on 2026-11-05. All three generators use a shared host-specific data
quoter; Windows also escapes quotes and parentheses so quoted JSON cannot change how its
metacharacters are parsed. The exhausting batch helper uses one-pass labels and redirects before
echo, retaining no extra diagnostic space. The unused helper/export and generator are removed.
The three Haddocks and testing doctrine now describe chosen stand-in responses. Four new
ProviderReconcileSpec cases cover literal stdout, exhaustion stderr, an apostrophe-bearing transcript
path, native newlines, POSIX Unicode, unintended files and the test-tree absence guard.
Plain builds pass on Linux core/demo and native Windows core. The focused ProviderReconcileSpec,
ClusterReconcileSpec and documentation selection passes all 70 cases on each host (Linux 9.11
seconds reported; Windows 17.79 seconds reported). Both hosts launch the actual stand-in clients
through the production interpreter, preserve the exact metacharacter reports and expected native
newlines, and create only the declared fixture files. Production Haskell and all 708 compile-fail
fixtures are unchanged. The complete Linux static gate and explicitly declared native Windows
core cabal test all are recorded below.

The first complete core runs each passed 4594 of 4595 cases on Linux core/demo and native Windows.
The sole failure was the standalone share-descriptor control: ProviderReconcileSpec's new source
guard dependency was missing from that control's explicit home-module list, and -Werror correctly
refused compilation. The list now includes SourceGuard; no warning is disabled and no package
visibility is changed. The process round trips passed in every full run. Both Python commands passed,
with 376 cases and 100% coverage; the demo's own 167 cases passed. The corrected standalone case
passes on both hosts in the corrected 71-case selection (Linux 16.66 seconds reported; Windows
25.98 seconds reported). All three rebuilds pass. The required full gate commands pass in the corrected runs recorded below.

The corrected Linux full gate passes: core 4595 cases, demo 4595 core plus 167 demo cases,
and both Python commands with 376 cases and 100% coverage. The native Windows run passed the
standalone control but exposed a separate native fixture cleanup failure in Wsl2Spec:
RegQueryInfoKey reported a too-small buffer after the wrongly typed version check. Cleanup now
uses fixed-size native regEnumKey enumeration, initializes the terminator for the end-of-list
case, deletes index zero until empty, and closes its own fixture handle in finally. No
production observer or semantic test is changed. The expanded 113-case selection passes on both
hosts (Linux 17.24 seconds reported; Windows 25.77 seconds reported), including every Wsl2Spec
case and the corrected standalone control. All three builds pass. Native cleanup and every final
full gate pass in the runs recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T20:23:34.340166+00:00 | 2026-11-05T20:36:29.146804+00:00 | 774.810751 | 4595 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T20:23:34.340376+00:00 | 2026-11-05T20:35:38.249088+00:00 | 723.912579 | 4595 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T20:23:34.340240+00:00 | 2026-11-05T20:23:35.701643+00:00 | 1.361414 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T20:23:34.346909+00:00 | 2026-11-05T20:23:42.170912+00:00 | 7.824055 | 376 cases; 100% coverage; exit 0 |
| `cabal test all` from `core/` on native Windows | 2026-11-05T20:23:34.361238+00:00 | 2026-11-05T20:36:03.815760+00:00 | 749.458516 | 4595 core cases; exit 0 |

The four Linux commands verify both 1173-file source copies before and after. The explicitly
declared native Windows core command verifies the Windows tree against that same frozen snapshot.
Python covers all 1585 statements and 460 branches. Cabal holds -Werror. No production Haskell
changes: all 199 production source modules and all 708 compile-fail fixtures retain baseline bytes.
Four new process/source cases preserve literal output and inspect only declared fixture files.
Changed files retain LF endings. The unconfirmed provider-live component compiles and exercises its declared
result; Sprint 15.50 owns the finished phase's confirmed native gate.

#### Remaining Work

None.

### Sprint 15.45: Owned Incus instances answer for the declared sizing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/FakeProvider.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/engineering/resource_budgeting.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

An owned Incus instance answers for the CPU, memory and root-disk quantities the declaration names now.
Equivalent units compare equal; a different quantity is a typed Conflict with declared and observed
sizing and destroy-and-reprovision as the remedy. The shared sizing observation and conflict vocabulary
also serves the guest-VM rows: Sprint 15.45a adopts native Lima readback and Sprint 15.45b records and
compares the original WSL VHD cap. This split preserves every row of the original Sprint 15.45 while
keeping each adoption within section G's three-production-module limit.

#### Deliverables

- Normalize declared and observed native quantities through the existing canonical ResourceBudget parser.
  A native instance reports all three quantities; a recorded WSL disk cap reports only storage, because
  CPU and memory belong to the separately verified shared WSL wall.
- Carry a structured sizing mismatch through the ownership result and the common backend refusal
  classifier to one Conflict shape, naming the declared quantities, the observations actually available,
  and destroy-and-reprovision as the remedy.
- On the owned-instance branch of provisionOwnedInstance, read limits.cpu, limits.memory and root size
  through the existing configuration/device command descriptions and report classifiers. Compare before
  ProvisionAlreadyOwned, under the held entry, with fresh claim and native-identity checks.
- Equal readback launches nothing, changes no native object and republishes no origin record. A mismatch
  likewise mutates nothing. An absent, malformed, noisy or failed read refuses rather than supplying a
  fabricated limit. Preserve the exact existing plan/owner/backend binding.

#### Validation

ProviderReportSpec applies the real total sizing classification and comparison to equivalent units,
each differing dimension, invalid or missing quantities, and failed/noisy process reports.
ProviderBackendSpec's owned Incus sizing cases run a genuine prepared provision over the compiled
FakeProvider protocol, then repeat over equal limits and over changed CPU, memory and root size.
Equal limits settle ProviderProvisionAlreadyOwned; changed limits settle Left (Conflict ...) with exact
declared/observed quantities and the remedy. Every pair asserts no second launch or other mutation and
unchanged origin bytes. Cases also retain claim/identity replacement and malformed-report refusals.
The stand-in supplies raw protocol values; native Incus behavior is confirmed by Sprint 15.50.

Closure requires all four host-static commands: cabal test all from core and demo, and the Poetry
check_code and test_all modules from the repository root.

Implemented on 2026-11-05. Report carries ordinary native-budget versus recorded-WSL-cap
observations, canonical comparison/rendering, and the native Incus byte adapter shared with backend
admission. Ownership rejects non-positive sizing before a provider command, then reads retained limits
under the entered binding and rechecks the claim/native identity before AlreadyOwned. Backend maps
the structured sizing fault to the shared typed Conflict. No registration identity or owner binding
is supplied by sizing data. The compiled client retains ordinary launched limits. Twenty-one new
pure cases and ten ownership/prepared-backend cases cover unit equivalence, every native suffix,
quantity boundaries, each drift dimension, unchanged records/no mutation, and replacement during
readback. The first builds on all three workspaces found the redundant Text.Read import left
by moving the native parser; it is removed. The next builds exposed the spec referencing the
fixture's private replacement path; the case now uses its existing exported arming function.
The spec also retains expected Left results explicitly because its existing entry helper unwraps
successful results. No warning, visibility or production boundary is weakened. The corrected behavior
and complete gate results are recorded below.

Plain builds pass on Linux core/demo and native Windows core. The first broad focused selection
passes 415 of 419 cases on each host. Three exact-conflict cases exposed the identity-conflict helper
decorating the sizing remedy; the shared sizing arm now constructs its ConflictDetail directly.
The fourth case assumed Word64's maximum was a valid budget CPU count; the canonical constructor
bounds CPU at Int, so the case now checks that exact bound and rejects larger representable words.
Native suffix vectors use independent known byte values. The corrected focused and full gates
are recorded below.

The corrected 80-case selection passes on Linux and native Windows (6.62 and 11.83 seconds
reported), including all 31 new sizing cases, retained ownership checks, sealed exports and
all 22 documentation checks. The corrected builds pass on Linux core/demo and Windows core.
The production change is 168 non-empty lines in three modules; the other 196 production
modules and all 708 compile-fail fixtures retain baseline bytes. The four complete host-static
commands pass in the runs recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T21:00:58.581961+00:00 | 2026-11-05T21:14:10.978323+00:00 | 792.398344 | 4626 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T21:00:58.582375+00:00 | 2026-11-05T21:13:07.572643+00:00 | 728.992089 | 4626 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T21:00:58.582482+00:00 | 2026-11-05T21:01:13.767566+00:00 | 15.185122 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T21:00:58.583089+00:00 | 2026-11-05T21:01:20.419345+00:00 | 21.836314 | 376 cases; 100% coverage; exit 0 |

All four commands verify both 1173-file source copies before and after. Python covers all
1585 statements and 460 branches. Cabal holds -Werror. The change is 168 non-empty production
Haskell lines in Report (94), Ownership (52) and Backend (22); all other 196 production modules
and all 708 compile-fail fixtures retain baseline bytes. Thirty-one new cases are added.
The corrected 80-case selection also passes natively on Windows; it is protocol/static evidence,
while Sprint 15.50 owns native Incus behavior and phases 26/28 own guest-provider realization.
Changed files retain LF endings. The unconfirmed provider-live component compiles and exercises
its declared result; the finished phase's confirmed run remains Sprint 15.50's work.

#### Remaining Work

None.

### Sprint 15.45a: Owned Lima instances compare native sizing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/GuestVm.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/FakeProvider.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/engineering/resource_budgeting.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

The entered guest-VM transaction compares an owned Lima instance's native CPU, memory and disk
quantities with the declaration before returning ProvisionAlreadyOwned. The backend already delegates
to that transaction; it gains no second name-based adoption path.

#### Deliverables

- Read the native listing's top-level cpus, memory and disk fields. Memory and disk are integer bytes;
  missing, fractional, non-positive or out-of-range quantities refuse. Creation config is no substitute
  for the listing's sizing observation.
- Compare through Sprint 15.45's canonical decision after the actual directory identity and ownership
  claim agree, preserving the existing lease and protected-entry checks.
- Equal limits return AlreadyOwned without a create/start or record publication. A mismatch returns the
  shared typed Conflict without mutation.
- Keep static evidence honest: the compiled client supplies native-shaped JSON and actual temporary
  directories exercise the kernel identity row; Apple Silicon's real Lima confirmation belongs to
  phase 26.

#### Validation

ProviderReportSpec covers native numeric fields, malformed/missing limits and equivalent canonical
quantities. ProviderBackendSpec exercises the owned Lima equal/changed pair through the actual
GuestVm transaction and prepared backend, asserting exact typed conflicts, no second create/start
and unchanged origin bytes. Retain the native Windows Unsupported row in the same named cases.
Run all four host-static commands before closing.

Implemented on 2026-11-05. The native report admits bounded integral cpus/memory/disk
fields into the canonical budget; creation config supplies no missing field. GuestVm re-enters the
stored binding, checks the fresh native claim/directory identity and compares the native budget before
AlreadyOwned. The shared typed sizing conflict preserves all three quantities and the exact remedy.
The compiled client reports numeric native fields from its durable ordinary config; claim mutations
retain sizing so the existing ownership cases exercise the same refusal. Both retained positives
now assert protected-record equality, including its version. Twenty-nine new pure schema/boundary
cases and eight real-entry/prepared-protocol cases cover all three changed dimensions, missing
readback and the fresh claim barrier. The change is 52 non-empty production lines in Report
and GuestVm. The first builds compile production but reject a type-defaulting warning in the
new JSON exponent fixture helper; its String signature is now explicit, with -Werror retained.
Focused behavior and complete static results are recorded below.

The corrected plain builds pass on Linux core/demo and native Windows core. The broad selection
passes 455 of 456 cases on both hosts (Linux 104.79 seconds reported; Windows 86.09 seconds).
All parser, ownership, prepared-backend, reconciliation and export cases pass, including the
37 additions and retained claim barriers. The sole failure is a bare numeric phase citation in
the Lima documentation; it now links the owning Apple Silicon acceptance by name. Corrected
documentation checks pass, and the complete static gate is recorded below.

The corrected documentation selection passes all 22 cases on each host (Linux 5.92 seconds
reported; Windows 7.61 seconds). Only the phase-name link and validation prose changed after the
broad run; its Haskell bytes are unchanged. The complete host-static gate passes in the runs recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T21:33:39.339613+00:00 | 2026-11-05T21:46:56.583471+00:00 | 797.244920 | 4663 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T21:33:39.339741+00:00 | 2026-11-05T21:46:08.847230+00:00 | 749.508487 | 4663 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T21:33:39.339948+00:00 | 2026-11-05T21:33:40.659176+00:00 | 1.319230 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T21:33:39.340121+00:00 | 2026-11-05T21:33:47.315315+00:00 | 7.975207 | 376 cases; 100% coverage; exit 0 |

All four commands verify both 1173-file source copies before and after. Python covers all
1585 statements and 460 branches. Cabal holds -Werror. The change is 52 non-empty production
Haskell lines in Report (20) and GuestVm (32); the other 197 production modules and all 708
compile-fail fixtures retain baseline bytes. Thirty-seven new cases are added, and both retained
positive cases now check exact protected-record equality, including its version.
The broad native Windows selection passes every behavior case; its sole documentation citation
failure is corrected and all 22 documentation checks then pass on each host, with Haskell bytes
unchanged. Windows exercises the actual Unsupported Lima row. Static protocol/kernel evidence
does not supply native Apple Silicon realization, which remains the named acceptance phase's work.
Changed files retain LF endings. The unconfirmed provider-live component compiles and exercises
its declared result; Sprint 15.50 owns the finished phase's confirmed Linux provider run.

#### Remaining Work

None.

### Sprint 15.45b: WSL installation retains its original disk cap [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/WslDisk.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/GuestVm.hs`,
`core/hostbootstrap-core/test/WslDiskSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/engineering/cluster_lifecycle.md`, `documents/engineering/resource_budgeting.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Record the VHD size requested at WSL installation with the exact owned VM transaction and refuse a
different later storage declaration. The recorded value is the original installed cap, not a fresh
VHD-size observation; CPU and memory remain the separately verified shared WSL wall.

#### Deliverables

- Publish bounded, canonical, versioned disk-cap metadata for the exact owner inside the real VM
  protected entry before the installation command can create a registration. Preserve it over an
  interrupted creation and require it when accepting an existing owned registration.
- Equal storage admits the existing owned-registration path without reinstalling. A changed declaration
  returns Sprint 15.45's shared Conflict with the declared sizing and the recorded storage observation;
  it launches or mutates nothing. Missing, foreign or malformed metadata refuses.
- Preserve the original four ownership clauses and fixed native registry query. Disk metadata confers
  no registration identity and supplies no GUID or alternate observation root.
- Separate the pure metadata/decision and real protected-store evidence from native WSL realization.
  The positive real registration/installation equal-and-changed pair is owed to phase 28; static cases
  do not manufacture a registry registration or replace production's native observer.

#### Validation

WslDiskSpec applies the real metadata classifier and storage decision to equal/changed caps,
canonical boundaries, missing/foreign/malformed records and interrupted installation state. Its
temporary protected store exercises actual durable publication, re-entry and unchanged retained bytes.
ProviderBackendSpec retains real native unsupported rows and confirms cap publication before its
failed/no-registration install cases on Windows. Sprint 28.8 owns integration of the live case into
Windows acceptance, and Sprint 28.5 owns the live owned-distro equal/changed
provision pair, no-reinstallation/mutation assertion, and original VHD-cap confirmation.
Run all four host-static commands before closing.

Implemented on 2026-11-05. WslDisk stores an owner-bound, fixed-version, bounded binary cap through
the real protected entry and existing little-endian decoder. GuestVm validates whole-GiB WSL sizing
before namespace effects, reconciles the cap after native standing and before origin/install, and
retains the fixed registry query and native GUID binding. Existing cap bytes and versions are never
overwritten. Twenty-four new metadata/real-store/source cases and one fractional-GiB admission case
cover boundaries, corruption, re-entry, changed-cap refusal, closed/foreign-thread sessions and
pre-install ordering. The compiled client checks that the actual cap record exists before its installer
response; it supplies no native registration. The first complete core and demo runs each pass 4687 of 4688 cases; their sole failure is the
existing provider publication guard rejecting direct CAS in WslDisk. Disk-cap publication now uses
the shared record tape's absent-only raw-metadata operation, and reads use its raw reader.
That operation grants no origin or registration evidence and retains the real store error constructor.
The existing guard stays intact. The metadata boundary case also pins use of the tape.
Corrected builds, focused checks and complete gate results are recorded below.

The complete host-static gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, as hostbootstrap (UID 1000), with GHC 9.12.4/Cabal 3.16.1.0/Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T22:34:18.673185+00:00 | 2026-11-05T22:45:59.707509+00:00 | 701.034634 | 4688 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-05T22:34:18.673314+00:00 | 2026-11-05T22:45:35.802277+00:00 | 677.129268 | 4688 core cases and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-05T22:34:18.685685+00:00 | 2026-11-05T22:34:19.921737+00:00 | 1.236052 | ruff, black and mypy; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-05T22:34:18.706807+00:00 | 2026-11-05T22:34:26.330835+00:00 | 7.624032 | 376 cases; 100% coverage; exit 0 |

All four commands verify both 1175-file source copies before and after. Python covers all
1585 statements and 460 branches. Cabal holds -Werror. The change is 106 non-empty production
Haskell lines in WslDisk (79), GuestVm (12) and Tape (15); the other 197 production modules and all 708
compile-fail fixtures retain baseline bytes. Twenty-five new cases cover ordinary cap metadata,
real protected-store behavior, the fixed native-query boundary and fractional-GiB admission.
Corrected builds with tests enabled pass in Linux core/demo and native Windows core.
All 534 corrected focused cases pass on Linux (104.14 reported seconds) and native Windows
(83.50), including the original publication guard,
shared-tape cases and actual Windows failed-install paths' pre-install record assertion. No static client response supplies a WSL registration or GUID.
Native installation, original-cap readback, equal/changed provision and interrupted-install recovery
are assigned to Sprint 28.8's acceptance integration and Sprint 28.5's live confirmation.
Changed files retain LF endings. The unconfirmed provider-live component compiles and exercises
its declared result; Sprint 15.50 owns the finished phase's confirmed Linux provider run.

#### Remaining Work

None.

### Sprint 15.46: One Incus argument vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/IncusSpec.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Every Incus outer-host command is rendered once, by `Provider/Command.hs` (§ W). `HostBootstrap.Incus` also
renders `createVMArgs` (sized by `incusSizingArgs`), `startVMArgs`, `stopVMArgs`, `deviceListArgs`,
`addDiskDeviceArgs`, and `destroyVMArgs`, which only the Incus row of `selectProviderKind` in
`Substrate/Provider.hs` consumes; no production route runs that row's launch, share, stop, or delete
effects, because Incus mutation goes through the prepared calls. The same Incus operation therefore has
two renderers, and only one is exercised against a provider.

#### Deliverables

- The Incus row of `selectProviderKind` renders start, stop, device listing, share attachment, and the
  guarded delete from `Provider/Command.hs` (`startInstanceCommand`, `stopInstanceCommand`,
  `listShareDevicesCommand`, `attachShareDeviceCommand`, `deleteInstanceCommand`) as `RunHostCommand`
  effects.
- The Incus row's launch answers a structured refusal naming the prepared provision call, because the
  creating command carries an owner claim only the prepared route mints (Sprint 15.28).
- `HostBootstrap.Incus` keeps `IncusVM`, `execVMArgs`, and `pushFileArgs`; the six duplicate builders are
  deleted with their exports and `IncusSpec` cases.
- A source guard asserts `HostBootstrap.Incus` exports exactly `IncusVM (..)`, `execVMArgs`, and
  `pushFileArgs`, so a second Incus renderer cannot return there.

#### Validation

Closure requires, under `cabal test all` from `core/`: `ProviderSpec`'s Incus provider-row cases assert the
row's effects equal the `Provider/Command.hs` commands for the same instance, and its launch refusal;
`ProviderSpec`'s guarded-delete group takes the Incus row from `deleteInstanceCommand`; and `IncusSpec`'s
import-token guard and the export-list guard above name the reduced set.

Implemented on 2026-11-05 in two production modules. The Incus realization exports
only IncusVM, the lower crossing renderer and file push. Its provider row projects the existing
described commands, and descriptive launch returns ProviderOperationFailure requiring prepared
provision. Eight obsolete builder cases are removed; two provider-row cases cover exact structured
refusal and shared-command equality for two names. The retained guarded-delete matrix uses the shared
delete command. Import/export guards and sealed inventory pin the reduced surface.
The initial builds catch an incorrect commandTool accessor in the new listing projection.\nThe projection now reads commandArguments with its fixed Incus tool, and the case independently\nchecks the described command target. Corrected builds, focused checks and the declared complete\ncore suite remain to be recorded.

Corrected plain builds with tests enabled pass on Linux core (69.334958 wall seconds),
Linux demo (61.245103) and native Windows core (67.292596). All 173 focused Incus/provider,
command, chain, sealed-export and documentation cases pass on Linux (53.73 reported seconds)
and native Windows (23.57). The guarded-delete matrix retains foreign/empty-prefix/name refusals.

The declared complete core gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, UID 1000, GHC 9.12.4 and Cabal 3.16.1.0.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T22:52:22.119060+00:00 | 2026-11-05T23:03:23.084321+00:00 | 660.965455 | 4682 core cases; exit 0 |

The command verifies both 1175-file source copies before and after. The change is 91 non-empty
production Haskell lines in Incus (55) and Provider (36); the other 198 production modules and
all 708 compile-fail fixtures retain baseline bytes. Eight obsolete cases are removed and two
provider-row cases added. The legacy ledger entry is removed with the builders. Changed files
retain LF endings. This static gate does not claim a confirmed native provider lifecycle; Sprint
15.50 owns that finished-tree confirmation.

#### Remaining Work

None.

### Sprint 15.47: One crossing renderer is held by a repository-wide guard [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

§ LL admits one rendering of "cross into this frame": the lift's fold, `foldLeaf` in `HostBootstrap.Lift`,
and the per-provider crossing primitives it composes in `HostBootstrap.Lift.Context` (`execVMArgs`,
`shellVMArgs`, `wslExecArgs`). This phase owns the frame table and the rule; no guard holds it across the
repository today, and only `RegistrySpec` checks that one module derives its crossing from `foldLeaf`.

#### Deliverables

- A `ProviderSpec` source guard over every module under `core/hostbootstrap-core/src/` and
  `core/hostbootstrap-core/internal/` asserts that the set of modules naming `execVMArgs`, `shellVMArgs`,
  or `wslExecArgs` is exactly `Lift/Context.hs` (their definition), `Lift.hs` (the fold), the three
  realization re-exports `Incus.hs`, `Lima.hs`, and `Wsl2.hs`, and `Substrate/Provider.hs`
  (the readiness probe rows). Include their placement-aware At variants. The backend no longer
  names these primitives after Sprint 15.42e; GuestVm uses the fold rather than a parallel renderer.
- The same guard asserts that no module outside `Lift.hs` and `Lift/Context.hs` carries an `"exec"` or a
  `"shell"` string literal, the leading elements of the Incus and Lima crossing vectors. Use the shared
  Haskell lexer and decode literal tokens so comments, textual mentions and escaped spellings are
  classified correctly. Scan both physical source trees, including undeclared new modules.
- The guard's Haddock cites § LL and the rationale entry whose absence guard is "one crossing renderer".

#### Validation

Closure requires the guard to exist and pass under `cabal test all` from `core/`, plus a case applying the
guard's pure predicate to a constructed module list in which a further module names `shellVMArgs`, and to
one in which a further module carries an `"exec"` literal, each refused.

Implemented on 2026-11-05 in ProviderSpec only. One pure predicate consumes the
shared Haskell lexer's tokens. The actual scan enumerates both physical source trees and normalizes
their paths through SourceGuard, including undeclared files. Four new cases cover the real inventory,
an admitted constructed baseline with comments/textual mentions, each bare and placement-aware
primitive in a new qualified consumer, and literal duplicates including escaped spellings.
No production Haskell or compile-fail fixture is changed.
Builds, focused checks and the declared complete core suite are recorded below.

Plain builds with tests enabled pass on Linux core (48.802775 wall seconds),
Linux demo (9.094746) and native Windows core (9.578852). All 58 focused provider and
documentation cases pass on Linux (6.59 reported seconds) and native Windows (8.37),
including the actual physical inventory and every constructed positive/negative control.

The declared complete core gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, UID 1000, GHC 9.12.4 and Cabal 3.16.1.0.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T23:08:19.033332+00:00 | 2026-11-05T23:18:40.643022+00:00 | 621.609864 | 4686 core cases; exit 0 |

The command verifies both 1175-file source copies before and after. No production Haskell changes:
all 200 production modules and all 708 compile-fail fixtures retain baseline bytes. Four new cases
hold the real source inventory and the pure predicate's admitted/rejected controls. Changed files
retain LF endings. The test-only guard supplies no native provider realization; Sprint 15.50
owns the finished-tree confirmation.

#### Remaining Work

None.

## Static Validation Evidence

On 2026-08-08, macOS 26.5 arm64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 1,709 tests passed in 126.71 seconds. The run
included the provider, backend, alias, reconciliation, compile-fail, provider-live source-boundary, and
governed-documentation checks. This closes the static portion of the phase gate; it does not substitute for
the declared native Linux/x86_64 component build or live KVM/Incus run.

On 2026-08-10, Ubuntu 24.04.4 LTS x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 1,710 tests passed in 56.56 seconds, including the
socket-pathname bound refusal this phase's backend admission adds. The same host passed
`cabal build all --ghc-options=-Werror`.

On 2026-08-19, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 2,153 tests passed in 233.28 seconds, including
this phase's reported-observation, provider-report, described-command, claimed-object, and
resumption-decision families. The same host passed `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231. § II makes this a gate-host record rather than a
substrate declaration: it is the host static gate run natively on a Windows outer host, and it neither
substitutes for the declared native Linux/x86_64 component build nor for the live KVM/Incus run.

On 2026-08-20, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal build all --ghc-options=-Werror` from `core/` —
the first gate host other than Linux on which that component builds at all — and
`cabal test all --ghc-options=-Werror` from `core/`: all 2,227 tests passed in 310.17 seconds,
including this phase's clause-holding provider driver, its Direct canonical-root admission, and the
provider lifecycle family that this phase's final sprints made host-portable. The same host passed
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` at
231. § II makes this a
gate-host record rather than a substrate declaration: it is the host static gate run natively on a
Windows outer host, and it neither substitutes for the declared native Linux/x86_64 component build nor
for the live KVM/Incus run.

On 2026-08-20, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 2,229 tests passed in 305.82 seconds, including
the share's instance recheck and the inherited durability guard this phase's last two sprints add. The
same host passed `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231. § II makes this a gate-host record rather than a
substrate declaration: it is the host static gate run natively on a Windows outer host, and it neither
substitutes for the declared native Linux/x86_64 component build nor for the live KVM/Incus run.

## Phase-Level Baseline Acceptance

After every implementation sprint is statically closed, run the phase's opt-in provider test on a disposable
native Linux/x86_64 host with readable/writable `/dev/kvm` and a ready Incus daemon. The run requires
`HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host` and confirms:

- declared Incus sizing, origin-before-launch, ready, host-backed share/readback, stop/restart, prepared alias,
  conditional alias release, and identity-conditional delete through the production prepared route;
- Direct local admission and identity share plus guest, alias, and prepared-stop refusals without physical-host
  ownership or mutation; the stop refusal mints no `Stopped` authority, so the source-guarded route has no
  prepared delete call, while `ProviderSpec` separately pins the pure Direct delete-planner refusal;
- absence of the run's exact VM, alias, staging paths, and origin records after teardown.

Record the date, exact command, host/OS/architecture, GHC/Cabal/Incus versions, duration, and result here.

**2026-08-10 — passed.** Host: Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic, x86_64, `/dev/kvm` readable and
writable by the invoking user, Incus 6.0.0 with a `dir` storage pool. Toolchain: GHC 9.12.4, Cabal 3.16.1.0.
Command, from `core/`:

```text
HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all \
  --test-show-details=direct --ghc-options=-Werror
```

Result: `provider-live: PASS — prepared Incus lifecycle/share/alias/restart/delete and mutation-free Direct
refusal`, 1 of 1 test suites passed, 27.75 seconds wall clock on a repeat run from a clean host. The run
confirmed the declared Incus sizing by provider readback (`limits.cpu` 2, `limits.memory` 2GiB, root device
`size` 12GiB), the host-backed share and its guest-visible alias origin, the prepared alias across a stop and
restart, the conditional alias release, and the identity-conditional delete. The Direct route executed
exactly four requests — two canonical-root `lstat`/`realpath` probes and two `docker manifest inspect` egress
probes — and created no provider state. After teardown the run's VM, alias, staging paths, origin records,
and its whole `/var/tmp` root were absent.

**2026-08-21 — passed against the completed provider boundary.** Host: Ubuntu 24.04.4 LTS, Linux
7.0.0-28-generic, x86_64, `/dev/kvm` readable and writable by the invoking user, Incus 6.0.0 with a
`dir` storage pool. Toolchain: GHC 9.12.4, Cabal 3.16.1.0. The exact command above passed after the
provider observation was aligned with Incus's authoritative absent-instance behavior and the launch
command selected Incus's global quiet mode; the live run reported the declared PASS line and removed
its exact VM, alias, staging paths, origin records, and `/var/tmp` root. The host-static gate then passed
at 2,333/2,333 Haskell tests in 219.39 seconds, the Python code check passed, and the Python suite passed
at 231/231.

**2026-09-09 — passed against the current provider boundary.** Host: Ubuntu 24.04.4 LTS, Linux
7.0.0-28-generic, x86_64, `/dev/kvm` readable and writable by the invoking user, Incus 6.0.0 with a
`dir` storage pool. Toolchain: GHC 9.12.4 and Cabal 3.16.1.0. The exact command above passed all 2,497
static cases in 177.46 seconds and then passed the live component. The live result confirmed the prepared
Incus lifecycle, share, alias, forced restart, post-restart guest readiness, identity-conditional delete,
and mutation-free Direct refusal. The executable installed into the guest was synced before restart and
served the shipped-ownership frame-child entry after restart. The run left no matching VM, `/var/tmp`
root, alias record, or staging object, and all Cabal-generated `.log` files were removed from the working
tree after the run.

**2026-09-14 — passed.** Host: `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic,
`/dev/kvm` readable and writable by the invoking user, Incus 6.0.0. Toolchain: GHC 9.12.4, Cabal 3.16.1.0.
Commands, from `core/`: `cabal build all` and `cabal test all`, then
`HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct`. The host
static gate passed 2,546/2,546 in 200.71 seconds and the live component reported `PASS — prepared Incus
lifecycle/share/alias/restart/delete and mutation-free Direct refusal`.

**2026-11-05 - passed for Sprint 15.22's prepared-route adoption.** Host: the dedicated
hostbootstrap-linux WSL2 distribution on Windows build 26300.9818; Ubuntu 24.04.5 LTS,
Linux 6.18.33.2-microsoft-standard-WSL2, x86_64. The invoking user is hostbootstrap
(UID 1000), with SVM exposed and a successful read/write /dev/kvm open.
Toolchain: GHC 9.12.4, Cabal 3.16.1.0, Incus client/server 6.0.0 and QEMU 8.2.2.
Incus has a dir pool and the owned hb15br0 NAT bridge.

Exact command, from the source tree's `core/`:

```text
HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct
```

The unfiltered run started at 03:20:08.856646 UTC and finished at 03:30:35.645767 UTC,
626.885361 wall seconds, exit 0. The provider-live component reported the declared PASS line;
the main suite passed all 4314 tests (561.75 reported seconds). The component exercised prepared
Incus provision/readiness, declared sizing, share/readback, guest alias acquisition, stop/restart,
conditional alias release and identity-conditional delete, plus mutation-free Direct admission
and refusals. Its exact VM, alias, staging paths, origin records and temporary root were absent
after teardown. All 1160 synchronized source/build/document files matched before and after
the command in both the Windows working tree and the native Linux source tree.
This is evidence for Sprint 15.22's tree; the phase remains Active and Sprint 15.50 owns
confirmation after its remaining implementation sprints.

### Sprint 15.48: Canonical metadata for native provider observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`, `core/hostbootstrap-core/test/LifecycleDependencySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Provide one bounded, canonical ordinary record for the native identity observed at running-package
registration and its existing ready commitment. The record carries data, not native provenance or a
receipt. A private provider-domain accessor makes that ordinary record available after the existing
coordinate checks. Sprint 15.48a adopts it in actual probes and recovery; this split keeps both sprints
inside section G's three-production-module limit without changing the shared response framing.

#### Deliverables

- Encode and classify a bounded, versioned canonical JSON tuple using the existing JSON and object-identity
  codecs. Keep the ready commitment and native identity distinct; reject malformed, oversized,
  noncanonical, wrong-version and invalid-identity records.
- Move the backend's existing positive identity observation hash to the report vocabulary with its exact
  behavior preserved, and consume it from the backend. It is an ordinary observation version, not a
  logical resource generation or an ownership proof.
- Add a private read-only provider-domain metadata projection to the canonical runtime package owner.
  Cluster and provider-share packages do not open through it.
- Preserve the runtime probe and package behavior until Sprint 15.48a's adoption. Add no query injection,
  native identity producer, or callback authority.

#### Validation

ProviderReportSpec applies independent codec vectors and corrupt/boundary values to the actual codec,
plus known observation-hash vectors. LifecycleDependencySpec checks the actual provider-only metadata
projection and unchanged canonical package round-trip. The backend uses the relocated hash.
Build core/demo on Linux and core on Windows, run focused controls on both hosts, and run cabal test all
from core before closure. Sprint 15.48a retains the original native replacement cases and four-command
host-static closure.

Implemented on 2026-11-05. Report uses the existing JSON encoder/decoder and
object-identity codec for a bounded canonical tuple. It preserves the ready commitment separately
from the native identity and proves no native provenance. The backend consumes its existing identity
hash from Report with exact behavior preserved. The canonical private package owner exposes ordinary
provider observation metadata and refuses the other two domains. Twenty-one new report cases and one
package-projection case cover an independent wire vector, boundaries, corrupt/noncanonical bodies,
known hash vectors and canonical package round-trip.
Builds, focused controls and the complete core gate are recorded below.

Plain builds with tests enabled pass on Linux core (146.612803 wall seconds),
Linux demo (97.884325) and native Windows core (105.474449). All 505 focused report, runtime-package,
provider, sealed-export and documentation cases pass on Linux (95.39 reported seconds) and native
Windows (67.91). The backend's existing foreign-identity classifications retain their behavior.

The declared complete core gate passes on 2026-11-05 in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, UID 1000, GHC 9.12.4 and Cabal 3.16.1.0.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-05T23:33:23.578908+00:00 | 2026-11-05T23:44:01.335129+00:00 | 637.756284 | 4708 core cases; exit 0 |

The command verifies both 1175-file source copies before and after. The change is 59 non-empty
production Haskell lines in Report (41), Backend (8) and the canonical runtime-package leaf (10).
The other 197 production modules and all 708 compile-fail fixtures retain baseline bytes.
Twenty-two new cases exercise ordinary metadata and the relocated hash. Changed files retain LF endings.
This support sprint supplies no native provenance and changes no live probe behavior. Sprint 15.48a
owns actual native identity capture, fresh comparison and recovery adoption, including the full
host-static gate; Sprint 15.50 owns the finished-tree confirmed Linux provider run.

#### Remaining Work

None.

### Sprint 15.48a: Fresh identity evidence for running-provider dependencies [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
 `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Make a dependent's running-provider reprobe answer from fresh provider identity evidence.
Use Sprint 15.48's ordinary metadata to retain the actual native observation separately from the
already checked logical package generation. No native GUID or query result is supplied by a fixture.

#### Deliverables

- An Incus reprobe observes identity through the ownership driver and returns Conflict for a replacement.
- A realization unable to observe identity returns Unsupported to identity-sensitive dependents.
- Remove comparisons and Word64 payloads that merely echo the managed handle, or replace them with
  genuinely observed identity evidence without confusing plan generations with physical identities.

- Preserve typed Conflict and Unsupported across the existing owner-serviced response framing through a
  bounded canonical ordinary refusal envelope. A transport or malformed-envelope fault still refuses.

#### Validation

The backend captures actual native identity during running-package registration, then compares the
complete fresh identity on every service request. Incus and guest-VM observations use the existing
ownership transactions. Direct observes its canonical root through the native ownership row before
and after egress, without claiming host ownership. Recovery checks the native observation separately
from the already checked logical package generation. The bounded ordinary refusal envelope preserves
Conflict and Unsupported through the existing nonce/commitment response framing.

Two new real-entry cases replace the actual same-name stand-in instance and the actual Direct root.
Both return typed Conflict and prevent dependent continuation while preserving the replacement and
protected records. Four independent refusal-codec cases cover canonical vectors and corruption.
The retained peer-reply negative changes the real native token; its positive control recovers logical
generation 17 despite a different native token, and its refusal retains one request/zero continuations.

Plain builds with tests enabled pass on Linux core (20.940180 wall seconds), Linux demo (20.943050)
and native Windows core (19.482314). All 530 focused provider, reconcile, report, runtime-package,
sealed-export and documentation cases pass on Linux (103.14 reported seconds) and Windows (87.04).

The complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T00:31:12.452256+00:00 | 2026-11-06T00:43:24.245406+00:00 | 731.793224 | 4714 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T00:31:12.452140+00:00 | 2026-11-06T00:43:22.605073+00:00 | 730.153001 | 4714 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T00:31:12.455773+00:00 | 2026-11-06T00:31:16.347238+00:00 | 3.891466 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T00:31:12.458745+00:00 | 2026-11-06T00:31:21.464546+00:00 | 9.005800 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify both 1175-file source copies before and after. The three production modules
change by 290 non-empty lines: Backend 211, Reconcile 50 and Report 29. The other 197 production
modules and all 708 compile-fail fixtures retain baseline bytes. Changed files retain LF endings.
Sprint 1.11 records the packaging guard and its refreshed deferred evidence before this complete run.
Sprint 15.49 owns nonce retention across exact service registration; Sprint 15.50 owns the final
confirmed Linux/KVM/Incus run.

#### Remaining Work

None.

### Sprint 15.49: Consumed dependency nonces survive registration [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`

#### Objective

Retain consumed nonces when an exact running-provider or provider-share package is registered again.

#### Deliverables

- Exact package registration retains its existing consumed-nonce set or already registered closure.
- Running-provider and provider-share routes enforce the same replay rule.
- A mismatching package remains a structured conflict.

#### Validation

Two new actual-entry cases exercise the real prepared provider/share registration and recovery paths.
Each consumes a nonce, re-registers the exact package, and proves the same nonce refuses before
another native/provider probe. The share case also proves a fresh nonce succeeds, protected records
and mutation history are unchanged, and a changed package returns typed Conflict. The running-provider
case checks typed Conflict for its changed package while retaining the existing expiry and package guards.

Before the production change, both cases fail: the provider replay executes another guest probe,
and the share replay returns Right (). The corrected cases both pass on Linux. The existing live
service replacement routes remain unchanged; provider/share registration alone uses atomic retention
of the first exact route/commitment closure. No callback or consumed-nonce state enters the package.

Plain builds with tests enabled pass on Linux core (260.433659 wall seconds), Linux demo (228.612121) and native Windows core (212.900975).
All 532 focused provider, report, reconcile, runtime-package, sealed-export and documentation
cases pass on native Windows. The complete Linux suites cover those same cases.

The complete host-static gate passes on 2026-11-06 UTC in hostbootstrap-linux, Ubuntu 24.04.5
x86_64 under WSL2, UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all` from `core/` | 2026-11-06T00:50:53.413220+00:00 | 2026-11-06T01:04:42.811782+00:00 | 829.398609 | 4716 core cases; exit 0 |
| `cabal test all` from `demo/` | 2026-11-06T00:50:53.413867+00:00 | 2026-11-06T01:04:09.795665+00:00 | 796.381859 | 4716 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T00:50:53.413725+00:00 | 2026-11-06T00:50:54.837354+00:00 | 1.423627 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T00:50:53.414114+00:00 | 2026-11-06T00:51:00.388113+00:00 | 6.974001 | 376 Python cases; 100% coverage; exit 0 |

All four commands verify both 1175-file source copies before and after. The change is 41 non-empty
production lines in Backend (19) and the private execution kernel (22). The other 198 production
modules and all 708 compile-fail fixtures retain baseline bytes. Changed files retain LF endings.
Sprint 15.50 owns the completed tree and its explicitly confirmed Linux/KVM/Incus gate.

#### Remaining Work

None.

### Sprint 15.50: Native Incus guest startup readiness [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Classify the exact native Incus agent-startup reply as bounded not-readiness. Other exit-255
faults retain their causal refusal. The final composed live gate belongs to Sprint 15.50a.

#### Deliverables

- Exit 255 with empty stdout and the exact agent-not-running diagnostic reaches the existing bounded poll.
- Prepared and retained readiness retain their identity, protected record and start count through retries.
- Other exit-255 faults, wrong streams and changed diagnostics remain failures.

#### Validation

On 2026-11-06 UTC, three new actual-entry/classifier cases first fail for the native startup reply.
The corrected Linux selection passes all three (4.44 reported seconds), including five near-miss
vectors that remain failures, and actual prepared and retained stop/start polling. All 535 focused
provider, report, runtime-package, reconcile, export and documentation cases pass on native Windows
(97.41 reported seconds). Plain builds with tests enabled pass on Linux core (15.935114 wall seconds),
Linux demo (39.570173) and Windows core (28.673108).

The complete host-static gate passes in hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2,
UID 1000, GHC 9.12.4, Cabal 3.16.1.0 and Poetry 2.4.3.

| Command | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal test all from core/` | 2026-11-06T01:46:00.362078+00:00 | 2026-11-06T01:58:01.293278+00:00 | 720.931198 | 4719 core cases; exit 0 |
| `cabal test all from demo/` | 2026-11-06T01:46:00.362351+00:00 | 2026-11-06T01:58:10.579063+00:00 | 730.216710 | 4719 core and 167 demo cases; exit 0 |
| `poetry run python -m hostbootstrap.check_code` | 2026-11-06T01:46:00.362263+00:00 | 2026-11-06T01:46:01.337836+00:00 | 0.975574 | ruff, Black and mypy pass; exit 0 |
| `poetry run python -m hostbootstrap.test_all` | 2026-11-06T01:46:00.369400+00:00 | 2026-11-06T01:46:06.350398+00:00 | 5.980997 | 376 Python cases; 100% coverage; exit 0 |

All four commands measure the same 1175-file source snapshot before and after in both trees.
The classifier adds two production lines in one module. The other 199 production modules and
all 708 compile-fail fixtures retain baseline bytes. Changed files retain LF endings.

#### Remaining Work

None.

### Sprint 15.50a: Final native Incus provider confirmation [Done]

**Status**: Done
**Implementation**: none; this sprint records the composed gate
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/testing.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`, `README.md`,
`documents/architecture/lifecycle_state_model.md`, `documents/architecture/hostbootstrap_core_library.md`,
`documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

Confirm the completed provider tree on native Linux/x86_64 with KVM and Incus after the
implementation sprints close on the host static gate, then record current evidence for every
leg of the phase's composed gate.

#### Deliverables

- Run both exact phase-gate legs on the realized Linux host, including the in-guest self-reference path.
- Inspect cleanup, measure the declared evidence paths and close the phase and index on passing evidence.
- Reconcile the completed provider inventory and its ownership/readiness descriptions.

#### Validation

The final preflight opens /dev/kvm read/write as UID 1000 and obtains KVM API 12.
The host is hostbootstrap-linux, Ubuntu 24.04.5 x86_64 under WSL2, kernel
6.18.33.2-microsoft-standard-WSL2, GHC 9.12.4, Cabal 3.16.1.0, Incus client/server 6.0.0,
QEMU 8.2.2 and Docker CLI 29.9.3. The owned hb15br0 bridge is Created at 10.223.15.1/24 with NAT,
MTU 1500, no IPv6 and user.hostbootstrap.owner=phase15-live-gate. The default dir pool/profile are
ready. Docker service/socket remain inactive/masked; Windows .wslconfig retains its recorded SHA-256.

| Command from core/ | Start UTC | End UTC | Wall seconds | Result |
|---|---|---|---|---|
| `cabal build all` | 2026-11-06T01:45:28.874036+00:00 | 2026-11-06T01:45:45.368945+00:00 | 16.494905 | build pass; exit 0 |
| `cabal test all` | 2026-11-06T01:46:00.362078+00:00 | 2026-11-06T01:58:01.293278+00:00 | 720.931198 | 4719 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-06T01:58:37.265630+00:00 | 2026-11-06T02:10:06.015710+00:00 | 688.750078 | 4719 core cases and confirmed live provider PASS; exit 0 |

The complete host-static gate finishes before the explicitly confirmed composed command starts.
The live runner validates prepared create/recovery, readiness, share/readback and actual sizing,
forced restart/post-restart readiness, installed frame-child execution, conditional alias release,
identity-conditional delete and mutation-free Direct refusal. Its PASS follows its exact cleanup
checks. Independent inspection finds zero Incus instances and zero matching live-test roots under
/var/tmp, with the owned bridge intact. Every command checks the same 1175-file snapshot before
and after in both copies.

This confirmation changes documentation only. The declared source covers are measured afterwards
through the actual canonical Haskell digest implementation; the phase header records the result.
The standards and legacy inventory reflect the completed provider command and phase-preserving
rebound surfaces; the root README describes the implemented Windows destroy/shutdown route, and
the Lima/WSL2 documents distinguish shared backend evidence from their native acceptance work.

#### Remaining Work

None.



### Sprint 15.50b: Refresh provider evidence after launch-renderer change [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh the deferred provider evidence after the covered WSL launch renderer changed in Sprint 16.59a.

#### Deliverables

- Run both declared phase-gate legs, inspect the owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM read/write as UID 1000 and reported KVM API 12.
Incus 6.0.0 had no existing instances; its default profile and pool were available. The exact
phase gate ran against one frozen 1198-file source snapshot, with both copies verified before and
after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T13:35:44.656275+00:00 | 2026-11-08T13:47:11.211542+00:00 | 686.560550 | 5261 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T13:47:18.776177+00:00 | 2026-11-08T13:59:02.545819+00:00 | 703.775057 | 5261 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical covered-path
digest was remeasured as `6a18753bd64afde3a4788c30ba6eca760e56598980f50674c9170639361aba27`. Gate artifacts use the `hostbootstrap-15-50b-*` result
directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.


### Sprint 15.50c: Refresh provider evidence after direct-host wall decision [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after Sprint 16.62 changes the covered direct-host provision plan.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T16:38:55.761683+00:00 | 2026-11-08T16:49:56.556852+00:00 | 660.800154 | 5267 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T17:03:37.860703+00:00 | 2026-11-08T17:17:14.631511+00:00 | 816.776951 | 5267 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `df02d359558b01c9479e63aef6987702a8143ea44f8bcc6ac5756c89d777aabb`. Artifacts use the `hostbootstrap-15-50c-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`; the digest
measurement is `hostbootstrap-15-50c-resumed-digest-hkf_894q` under the user temporary directory.

#### Remaining Work

None.

### Sprint 15.50d: Refresh provider evidence after dependency probe producers [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the covered dependency producer change.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T18:26:07.975340+00:00 | 2026-11-08T18:38:05.669128+00:00 | 717.706634 | 5267 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T18:38:30.098439+00:00 | 2026-11-08T18:50:48.971908+00:00 | 738.886691 | 5267 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `a5f602e5682838d1b59fb5652a255aa572ef9c882022d73336d59964cf527fb9`. Artifacts use the `hostbootstrap-15-50d-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50e: Refresh provider evidence after callback probe change [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the covered running-provider callback change.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T18:57:47.581141+00:00 | 2026-11-08T19:10:19.173184+00:00 | 751.601233 | 5267 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T19:10:40.198308+00:00 | 2026-11-08T19:23:26.772907+00:00 | 766.583946 | 5267 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `5b869cbdac9eaf28c0663b486f48e0207548843cf5edfc21e12573c43a5e7918`. Artifacts use the `hostbootstrap-15-50e-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50f: Refresh provider evidence after probe kind tagging [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the covered probe kind changes.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T20:08:22.795871+00:00 | 2026-11-08T20:20:30.052757+00:00 | 727.263207 | 5270 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T20:20:51.023179+00:00 | 2026-11-08T20:34:04.186563+00:00 | 793.170282 | 5270 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `a29177d6607327d199d3198b250423d939b65525ad957956731532b4e65b68c4`. Artifacts use the `hostbootstrap-15-50f-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50g: Refresh provider evidence after share observation [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the read-only owned share observation changes a covered path.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T20:43:34.066299+00:00 | 2026-11-08T20:56:07.240381+00:00 | 753.180257 | 5271 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T20:56:39.312882+00:00 | 2026-11-08T21:09:03.632370+00:00 | 744.325589 | 5271 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `13a395e54e830960ab87e3534114fef2f1d9d56063d79c74bacc065e3ce50b2f`. Artifacts use the `hostbootstrap-15-50g-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50h: Refresh provider evidence after retained share reprobe [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after changing the retained share reprobe.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T21:13:52.308999+00:00 | 2026-11-08T21:26:31.845600+00:00 | 759.542682 | 5271 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T21:27:01.419760+00:00 | 2026-11-08T21:39:37.804806+00:00 | 756.391093 | 5271 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `393dc7ad59922cc0ad38b3c207f7057c607560d10568ca1713c1c32ed38b8c7b`. Artifacts use the `hostbootstrap-15-50h-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50i: Refresh provider evidence after share declaration binding [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after retaining the exact managed share declaration.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T22:32:56.208978+00:00 | 2026-11-08T22:45:30.922012+00:00 | 754.719073 | 5273 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T22:45:59.853058+00:00 | 2026-11-08T22:58:11.922535+00:00 | 732.075314 | 5273 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `597080115d936276544d3540455b753731fc613fb3bd918edf2a80672699ed08`. Artifacts use the `hostbootstrap-15-50i-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50j: Refresh provider evidence after share dependency producer [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after adding the declaration-bound share dependency producer.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T23:03:26.194769+00:00 | 2026-11-08T23:15:57.828012+00:00 | 751.639106 | 5273 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T23:16:27.485377+00:00 | 2026-11-08T23:28:48.487680+00:00 | 741.008079 | 5273 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `5da619d9a1d5df99f636f1223a9dd89858887ca03d509cfa7836dbe48018111d`. Artifacts use the `hostbootstrap-15-50j-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50k: Refresh provider evidence after guest mount reprobe [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after adding the guest mount reprobe.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-08 and 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-08T23:42:20.955291+00:00 | 2026-11-08T23:53:37.367271+00:00 | 676.417256 | 5273 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-08T23:54:15.693498+00:00 | 2026-11-09T00:07:10.806256+00:00 | 775.118826 | 5273 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `1050e1145b407a6fb86e5a4f74bdd4f9ba59e8794181c906343f68d81cf6ad20`. Artifacts use the `hostbootstrap-15-50k-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50l: Refresh provider evidence after local share identity [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after retaining local share identity in its dependency.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1200-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T00:13:22.713997+00:00 | 2026-11-09T00:25:57.073572+00:00 | 754.365603 | 5273 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T00:26:24.333918+00:00 | 2026-11-09T00:39:10.218309+00:00 | 765.890514 | 5273 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `adfc8ab0851734fe6108f615937f263c84307be2bf5d0d87f514b4ff0ba64c17`. Artifacts use the `hostbootstrap-15-50l-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50m: Refresh provider evidence after alias dependency adoption [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the guest alias dependency change.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1201-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T00:50:17.101499+00:00 | 2026-11-09T01:02:55.059123+00:00 | 757.963536 | 5275 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T01:03:12.692551+00:00 | 2026-11-09T01:15:55.604545+00:00 | 762.917943 | 5275 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `d07a5b60cf67cd75a32d465ea0602a43eeeffcdb61689f85f01c2b123dcb75c5`. Artifacts use the `hostbootstrap-15-50m-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50n: Refresh provider evidence after readiness indexing [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after provider dependency readiness indexing.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1201-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T02:13:44.411111+00:00 | 2026-11-09T02:24:41.152857+00:00 | 656.746961 | 5275 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T02:24:58.647533+00:00 | 2026-11-09T02:37:20.436320+00:00 | 741.794569 | 5275 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `275fe7b085baacfc8ba8260ac0a606869abb23ba5a6282dd3932fa2360ba7d55`. Artifacts use the `hostbootstrap-15-50n-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50o: Refresh provider evidence after live probe migration [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the live fixture adopts fresh backend probes.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1201-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T03:01:33.454322+00:00 | 2026-11-09T03:12:28.149600+00:00 | 654.700382 | 5275 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T03:12:46.539649+00:00 | 2026-11-09T03:26:01.332245+00:00 | 794.798792 | 5275 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `10344bbf7759f89e4c1e0ee4e444f0b02dd5709e29f3dc502eca60c42ed9e951`. Artifacts use the `hostbootstrap-15-50o-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50p: Refresh provider evidence after probe type migration [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after provider probe type migration.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1203-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T03:53:38.422249+00:00 | 2026-11-09T04:05:17.091202+00:00 | 698.678005 | 5278 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T04:05:43.797547+00:00 | 2026-11-09T04:18:59.092693+00:00 | 795.303339 | 5278 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `e1dc2563ddf6d583a095f7080d9f4f683c9b6edfa76f03f865bd54dcc6e8992a`. Artifacts use the `hostbootstrap-15-50p-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50q: Refresh provider evidence after claim migration [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after provider ownership claim migration.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1203-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T04:56:27.661335+00:00 | 2026-11-09T05:08:17.389913+00:00 | 709.734962 | 5281 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T05:08:40.796077+00:00 | 2026-11-09T05:22:07.850484+00:00 | 807.061313 | 5281 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `60b50f48e11ebbbdf65c7f2188768cf202a9e8da7ae290e25bbb2b20bcd48453`. Artifacts use the `hostbootstrap-15-50q-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50r: Refresh provider evidence after reported-origin restriction [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the guest VM ownership caller adopts claim-only recording.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1204-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T05:41:34.841706+00:00 | 2026-11-09T05:53:45.016748+00:00 | 730.181085 | 5282 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T05:54:25.706056+00:00 | 2026-11-09T06:07:36.157819+00:00 | 790.458240 | 5282 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `14d3d0b1a1babdd0de767fe5af0395c6657a7cb1b7539153764b367f956790c4`. Artifacts use the `hostbootstrap-15-50r-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50s: Refresh provider evidence after final claim adoption [Done]

**Status**: Done
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after provider owners adopt the final claim-only recorder.

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

On 2026-11-09 UTC, the WSL2 x86_64 Linux host opened KVM as UID 1000 and reported
KVM API 12. Incus 6.0.0 had no existing instances and its default profile and
storage pool were available. Both gate legs ran against the frozen 1204-file source
snapshot with both source trees verified before and after each command.

| Command from `core/` | Start UTC | End UTC | Seconds | Result |
|---|---|---|---:|---|
| `cabal test all` | 2026-11-09T06:29:30.035792+00:00 | 2026-11-09T06:41:20.060311+00:00 | 710.030267 | 5282 core cases; exit 0 |
| `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all --test-show-details=direct` | 2026-11-09T06:41:45.655990+00:00 | 2026-11-09T06:54:35.934918+00:00 | 770.285165 | 5282 core cases and live Incus/Direct PASS; exit 0 |

Post-run inspection found no Incus instances or provider-live roots. The canonical
covered-path digest is `5e418496d4448417780495331bbcceed6e0c3fbaf24b9490b689c5db2810dec4`. Artifacts use the `hostbootstrap-15-50s-*`
result directories under `D:/CodexScratch/hostbootstrap-test-temp/`.

#### Remaining Work

None.

### Sprint 15.50t: Refresh provider evidence after provider-live formatting [Active]

**Status**: Active
**Implementation**: none; this sprint revalidates the composed phase gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Refresh deferred provider evidence after the four `provider-live` modules were formatted with the base
image's `fourmolu` (formatting only, owed by the source-gate sprint that adds that root to the formatter).

#### Deliverables

- Run both declared phase-gate legs, inspect owned live resources, and record the current digest.

#### Validation

Not yet run. The edit is evidence expiry, not a design-error reopening (§ C).

#### Remaining Work

- Run both declared phase-gate legs on the Linux gate host and record the `**Gate evidence**` row.

## Remaining Work

Evidence expiry, not a design-error reopening (§ C): the `provider-live` modules this phase covers were
formatted, which changed the `**Evidence covers**` digest. Sprint 15.50t owes the re-run of this phase's
declared gate — `cabal test all` and the `incus-direct-host` live confirmation from `core/` on the Linux
gate host — and a re-recorded `**Gate evidence**` row.

## Documentation Requirements

**Architecture docs to update:**

- `documents/architecture/build_and_run_model.md` — opaque provider dispatch and prepared effect routing.
- `documents/architecture/hostbootstrap_core_library.md` — realization layer above the generic Lift.
- `documents/architecture/lifecycle_state_model.md` — backend-indexed managed authority and prepared transitions.
- `documents/architecture/ownership_invariant.md` — Incus, share, and alias clause holders.
- `documents/architecture/ownership_seam.md` — the seam's reported face and the claimed object.
- `documents/architecture/readiness.md` — raw discovery, bounded polling, and retained readiness facts.
- `documents/architecture/durable_state.md` — provider/share/alias origin and recovery states.

**Engineering docs to update:**

- `documents/engineering/incus.md` — the baseline prepared provider route and dated native evidence.
- `documents/engineering/lima.md` — common provider discovery and bound execution, with native proof in Phase 26.
- `documents/engineering/wsl2.md` — common provider/alias boundary, with native proof in Phase 28.

**Plan and inventory docs to update:**

- `DEVELOPMENT_PLAN/README.md` — status plus the lowest unfinished Phase 15 sprint.
- `DEVELOPMENT_PLAN/system-components.md` — provider realization and ownership surfaces without copied counts.
- `DEVELOPMENT_PLAN/development_plan_standards.md` §§ L, U, DD, and EE — final provider contract ownership.

**Cross-references:**

- Phase 24 owns the demo call-site adoption and destroy-to-up readback.
- Phases 26–28 own native Lima, NVIDIA/Direct, and WSL2 acceptance respectively.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
