# Phase 15 — Host providers and the self-reference lift

**Status**: Active
**Depends on**: Phase 8 (ensure reconcilers), Phase 12 (step algebra and plan-owned resource
projections), Phase 14 (the four ownership clauses and host-local reservations)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`,
`cabal build -fprovider-live hostbootstrap-provider-live-linux-cpu --ghc-options=-Werror` from
`core/`, and
`HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test -fprovider-live
hostbootstrap-provider-live-linux-cpu --test-show-details=direct --ghc-options=-Werror` from `core/`
on native Linux/x86_64 with KVM and Incus

> **Purpose**: Add one prepared provider boundary over the lower pure target vocabulary and generic
> self-reference Lift, with Incus and Direct as the baseline realizations.

## Phase Objective

Every frame operation names one closed provider operation. The selected provider descriptor, raw
discovery plan, managed provider authority, durable share, provider-bound guest executor, and guest
alias remain indexed to the same plan resource and backend realization. Incus holds the four ownership
clauses over VM and share mutation; Direct admits an already-local frame without claiming authority over
the host. Lima and WSL2 consume the same lower target and rendering contracts here and receive native
confirmation in their terminal substrate acceptance phases.

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
`core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Represent each provider operation once as pure, total planning data.

#### Deliverables

- `ProviderOperation` names provision, ready, stop, delete, share, alias, and guest routing.
- Provision, readiness, stop, delete, share, and alias planners have one signature across providers.
- Provider selection is data consumed by total folds rather than a consumer-side branch.
- A provider that cannot implement an operation returns a structured `Unsupported` result.
- Direct stop, delete, alias, and guest routes never appear successful.

#### Validation

`ProviderSpec` covers every provider/operation branch and the Direct refusal vocabulary.

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
- A source guard keeps generic Lift independent of the realization.

#### Validation

`Wsl2Spec` covers lifecycle shapes; native Windows confirmation belongs to the Windows and WSL2
acceptance phase.

#### Remaining Work

None.

### Sprint 15.6: Closed raw provider discovery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/architecture/durable_state.md`

#### Objective

Turn raw process results into provider discovery only through a closed provider-owned request plan.

#### Deliverables

- `ProviderProbeRequest` is abstract and has a read-only interpreter view.
- Closed requests cover daemon, permission, VM, egress, and guest-tool observations.
- The injected interpreter returns only exit status, stdout, stderr, or transport failure.
- Private total parsers classify Ready, NotReady, Unavailable, Conflict, and Failure.
- Exactly one bounded report is accepted where a private marker or tool identity is required.
- Only NotReady enters the module-owned bounded poll.

#### Validation

`ProviderSpec` covers request order, every terminal result, malformed and multi-line reports, retry bounds,
and structured provider conflict propagation.

#### Remaining Work

None.

### Sprint 15.7: Managed provider capability [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Retain the exact managed provider generation and discovered facts in one generative capability.

#### Deliverables

- `ProviderCapability` is minted only from a matching managed Running provider and bound executor.
- The capability retains provider kind, generation, and the complete discovery report.
- Guest routes retain the exact lock, stat, Python, and provider-bound executor facts observed.
- Direct capabilities expose no guest executor.
- Backend, provider, generation, and capability indices are nominal and rank-2 scoped.

#### Validation

Positive tests use the retained facts; compile-fail fixtures reject escape, forgery, coercion, and
cross-provider substitution.

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

- `ProviderBackendSpec` is abstract and constructed by total validation functions.
- Incus retains exact resolved Incus, Python, `flock`, state, identity, image, and sizing inputs.
- The Linux Incus ownership route uses one `flock` namespace.
- Direct retains an exact canonical local root, Python, Docker, and egress image declaration.
- Backend execution receives an opaque request with a read-only process view.
- Invalid substrate, unresolved tool, unbounded value, and ambiguous path inputs fail closed.

#### Validation

`ProviderBackendSpec` covers valid descriptions, every validation refusal, and the single-lock-namespace
rule.

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

Mint a generative backend only after its exact realization proves the ownership prerequisites it uses.

#### Deliverables

- `StrongProviderBackend backendId` is introduced only inside a rank-2 continuation.
- Incus proves the exact executable, Python, writable state directory, and `flock` front end.
- Stable semantic and per-realization fingerprints remain distinct and retained.
- One provider origin binds plan digest, resource key, generation, and semantic backend identity.
- Direct is a plan-local reservation and never a physical-host ownership claim.
- Forging and cross-backend use are statically rejected.

#### Validation

`ProviderBackendSpec` covers exact proof admission and refusal; compile-fail fixtures cover backend identity.

#### Remaining Work

None.

### Sprint 15.10: Prepared provider provision [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
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

Reconcile specs cover Created, Repaired, Unchanged-with-proof, Foreign, and every refusal; real-process
backend specs cover concurrent provision and crash recovery.

#### Remaining Work

None.

### Sprint 15.11: Prepared provider readiness [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
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
- Settlement returns only the same backend-indexed Running provider.

#### Validation

Specs cover both legal source phases, invalid phase substitution, NotReady retry, terminal outcomes, Direct
validation, and replacement at every readiness observation boundary.

#### Remaining Work

None.

### Sprint 15.12: Prepared durable share [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Attach one declared durable share through the exact Running provider authority.

#### Deliverables

- `ProviderShareSpec` validates exact absolute host and guest paths.
- `PreparedProviderShare` seals the exact provider dependency and fresh probe.
- Incus publishes a complete share intent, device binding, and sidecar under the provider lock.
- Direct admits only the already-local canonical root identity projection.
- Share settlement returns an opaque provider-indexed managed share or descriptive foreign observation.
- Manifest, sidecar, and device crash windows converge without adoption.

#### Validation

Specs cover attach, repair, unchanged-with-proof, collision, partial manifest/sidecar publication, replacement,
and Direct identity/refusal paths.

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
- Already-stopped success remains bound to the same exact identity.
- A still-running result retains retryable typed failure rather than advancing phase.
- A replacement is Conflict and remains untouched.
- Direct returns `Unsupported` and produces no Stopped authority.

#### Validation

Specs cover stop, idempotence, retry, Direct refusal, malformed reports, and replacement at each observation.

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
- Incus verifies UUID, nonce, stopped state, manifested devices, and exact sidecar bytes before mutation.
- Provider and share origins are released only after exact VM absence is durably reproved.
- Partial multi-sidecar cleanup is restartable.
- Missing, replaced, unmanifested, or reappearing state is preserved as Conflict or retryable Failure.
- Direct returns `Unsupported` and produces no Destroyed authority.

#### Validation

Specs cover conditional delete, exact restart, absent cleanup, orphan refusal, partial cleanup, fsync retry,
replacement, and Direct refusal.

#### Remaining Work

None.

### Sprint 15.15: Provider-bound execution [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

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

Positive tests cover bound discovery and guest execution; negative fixtures reject raw projection,
cross-backend use, generic-handle use, and capability substitution.

#### Remaining Work

None.

### Sprint 15.16: Prepared guest-alias call [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Seal provider, share, alias, operation, and gate identity into one prepared guest-alias call.

#### Deliverables

- `GuestAliasSpec` accepts one canonical absolute POSIX alias and target declaration.
- `PreparedGuestAliasCall` retains matching provider, backend, capability, share, alias, and operation indices.
- The managed share retains the exact provider origin that authorized it.
- Preparation seals the exact share dependency and runs its fresh probe.
- Indexed call results cannot settle another call.
- Settlement exposes an opaque managed alias or descriptive foreign observation.

#### Validation

Alias specs cover preparation, settlement, dependency freshness, and runtime origin defense; compile-fail
fixtures cover every nominal index and generic-handle substitution.

#### Remaining Work

None.

### Sprint 15.17: Strong alias backend admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Narrow one matching provider capability to the exact clause-holding alias backend.

#### Deliverables

- `StrongAliasBackend` is abstract and retains the provider-bound guest executor.
- Admission requires the exact `flock`, stat dialect, and Python executable observed in the guest.
- A different lock namespace cannot authorize the same alias origin.
- Backend, provider, generation, and capability identity remain nominally linked.
- A missing clause returns `Unsupported` before any mutation.
- Independent guest-executor injection is unrepresentable.

#### Validation

Specs cover admitted and unsupported discovery facts; compile-fail fixtures cover forgery, coercion, and
cross-provider execution.

#### Remaining Work

None.

### Sprint 15.18: Guest-alias origin and identity protocol [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Hold locked-origin identity ownership over guest alias acquisition.

#### Deliverables

- One retained guest `flock` spans origin observation, mutation, identity binding, and readback.
- An owner-bound staging file is fully written and flushed before no-replace origin publication.
- The origin records explicit absence, a fresh nonce, complete provider/share/spec binding, and exact bytes.
- Alias publication uses a nonce-named symlink staged and hard-linked into place without replacement.
- The symlink's own device/inode identity is bound durably before ownership settles.
- Prepared, managed, and transition staging crash windows converge without adoption.

#### Validation

`ProviderAliasSpec` exercises real filesystem publication, partial prepared-stage and managed-transition
completion, crashes after origin publication, alias publication, and foreign cleanup, exact readback,
foreign occupancy, and identity replacement.

#### Remaining Work

None.

### Sprint 15.19: Prepared alias acquisition adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Make the prepared alias call and strong alias backend the sole acquisition route.

#### Deliverables

- The owner binding includes exact provider origin, share key/generation, alias key/generation, and paths.
- Only a matching prepared call and strong backend can run the guest ownership protocol.
- Exact single-line backend reports map totally to indexed observations.
- A managed origin without local commit proof settles Repaired rather than adopting pathname shape.
- A prior proof settles the exact managed origin Unchanged.
- A foreign alias unwinds only this origin's exact staging and remains foreign.

#### Validation

Specs cover Created, Repaired, Unchanged, Foreign, malformed reports, outer-provider conflict, and crash-time
foreign unwind.

#### Remaining Work

None.

### Sprint 15.20: Conditional alias release [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

Release an alias only after a durable, version-fenced intent and exact identity re-observation.

#### Deliverables

- `PreparedGuestAliasRelease` accepts only the exact opaque managed alias and observation version.
- Release durably publishes and reads back `releasing` before unlink.
- A managed record with an already-absent alias is Conflict and retains the record.
- A releasing retry accepts only the same fence and either the exact alias identity or durably proved absence.
- Replacement leaves alias and origin untouched as Conflict.
- Final record and alias absence are directory-flushed and reproved before success.
- A different-nonce or malformed alias staging residue is refused before release mutation.

#### Validation

Specs cover stale fences, external unlink, replacement, partial releasing-transition completion, crashes
after intent and unlink, already released, stage residue, malformed reports, and zero-effect refusal;
compile-fail fixtures reject foreign authority.

#### Remaining Work

None.

### Sprint 15.21: Node alias-route adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Adopt the prepared alias boundary at the plan-owned node route.

#### Deliverables

- `reconcileNodeGuestAlias` resolves provider, share, and alias projections from the node descriptor.
- The route consumes the exact carried managed provider and provider-derived share.
- The plan traversal reruns the share probe while sealing preconditions.
- The projected alias gate is taken once for one prepared effect.
- Missing or mismatched dependencies refuse before guest execution.
- The route returns only change or foreign descriptive settlement.

#### Validation

`ProviderAliasSpec` drives the production node route through the real chain interpreter and covers missing,
stale, and cross-origin dependency refusal. The demo call-site adoption remains Phase 24 work.

#### Remaining Work

None.

### Sprint 15.22: Provider-live prepared-route adoption [Active]

**Status**: Active
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

- The component retains its manual flag, Linux/x86_64 restriction, and explicit confirmation guard.
- It constructs validated Incus and Direct specs and admits their generative strong backends.
- Provision, ready, share, stop, and delete use only matching prepared calls and settlements.
- Discovery and guest execution derive only from the matching managed Running provider.
- Alias acquisition and release use only matching prepared alias calls and opaque managed authority.
- Cleanup addresses only exact owned VM, share, alias, and origin identities and reports residue as failure.

#### Validation

From `core/`,
`cabal build -fprovider-live hostbootstrap-provider-live-linux-cpu --ghc-options=-Werror` compiles the
manual Linux/x86_64 component. The `ProviderSpec` source guard rejects raw lifecycle planners, opaque
provider-authority constructor imports, the private/independent guest executor, and any Direct delete path
after the prepared stop refusal.

#### Remaining Work

Build the manual component and run its confirmed live route on the declared native Linux/x86_64 KVM/Incus
host.

## Static Validation Evidence

On 2026-08-08, macOS 26.5 arm64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 1,709 tests passed in 126.71 seconds. The run
included the provider, backend, alias, reconciliation, compile-fail, provider-live source-boundary, and
governed-documentation checks. This closes the static portion of the phase gate; it does not substitute for
the declared native Linux/x86_64 component build or live KVM/Incus run.

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
This phase remains Active and Phase 16 does not begin until that evidence passes.

## Remaining Work

On a native Linux/x86_64 host with readable/writable `/dev/kvm` and a ready Incus daemon, build the
provider-live component with the phase-gate command, run its explicitly confirmed live test, and record the
required host/tool versions, duration, result, and residue checks above. Phase 16 does not begin before that
evidence passes.

## Documentation Requirements

**Architecture docs to update:**

- `documents/architecture/build_and_run_model.md` — opaque provider dispatch and prepared effect routing.
- `documents/architecture/hostbootstrap_core_library.md` — realization layer above the generic Lift.
- `documents/architecture/lifecycle_state_model.md` — backend-indexed managed authority and prepared transitions.
- `documents/architecture/ownership_invariant.md` — Incus, share, and alias clause holders.
- `documents/architecture/readiness.md` — raw discovery, bounded polling, and retained readiness facts.
- `documents/architecture/durable_state.md` — provider/share/alias origin and recovery states.

**Engineering docs to update:**

- `documents/engineering/incus.md` — the baseline prepared provider route and dated native evidence.
- `documents/engineering/lima.md` — common provider discovery and bound execution, with native proof in Phase 25.
- `documents/engineering/wsl2.md` — common provider/alias boundary, with native proof in Phase 27.

**Plan and inventory docs to update:**

- `DEVELOPMENT_PLAN/README.md` — status plus the lowest unfinished Phase 15 sprint.
- `DEVELOPMENT_PLAN/system-components.md` — provider realization and ownership surfaces without copied counts.
- `DEVELOPMENT_PLAN/development_plan_standards.md` §§ L, U, DD, and EE — final provider contract ownership.

**Cross-references:**

- Phase 24 owns the demo call-site adoption and destroy-to-up readback.
- Phases 25–27 own native Lima, NVIDIA/Direct, and WSL2 acceptance respectively.
