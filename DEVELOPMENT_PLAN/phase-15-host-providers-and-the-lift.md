# Phase 15 — Host providers and the self-reference lift

**Status**: Active
**Current sprint**: None — every implementation sprint is statically closed; the phase remains Active
until the declared native Linux/x86_64 KVM/Incus baseline acceptance run below is performed
**Depends on**: Phase 8 (ensure reconcilers), Phase 12 (step algebra and plan-owned resource
projections), Phase 13 (authenticated handoff and the frame-child entry), Phase 14 (the four ownership
clauses and host-local reservations)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/` host-native on every supported outer host
realization,
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

The frame table's rows and the one fold that reaches a frame are this phase's; the seam those rows plug
into is the
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
- Admission bounds the Incus instance name by what the provider's per-device control-socket pathname
  admits, so a declaration whose share device could not attach is refused before discovery.
- A non-zero backend call folds its provider diagnostic into the bounded single-line token vocabulary
  rather than discarding it, so a refusal names the condition it observed.

#### Validation

`ProviderBackendSpec` covers valid descriptions, every validation refusal, the socket-pathname bound, and
the single-lock-namespace rule.

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
- The share device is named from its binding digest inside the bound its provider control-socket pathname
  admits, and the durable manifest accepts only that shape.
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
- The origin directory the guest publishes inside the durable share is observable by the frame that owns
  that share, so the same ownership state is readable from either side of the boundary.
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
- Dropping the last origin record reclaims the origin directory only while it is empty, so a concurrent
  owner's record retains it and the share is otherwise left as it was found.

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
after the prepared stop refusal. The phase's baseline acceptance below records the confirmed live route.

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

- Every host `HostConfig` tool table in the phase's suites builds its paths through the fixture-path
  constructor the [Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns, so the
  same total `AbsExe` constructor production uses admits them on the host that runs them.
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

`ProviderAliasSpec`, `ProviderBackendSpec`, and `ProviderReconcileSpec` each name their host tools as
`fixture*` bindings built by `PlatformPath.hostFixturePath` and hand those exact values to the production
`mkAbsExe`; the Direct Ready request assertion compares the same constructed values rather than a POSIX
literal. The guest side is left alone and is now stated where it is written: the in-VM `which` result,
the guest argument vector, the Incus provider state directory, and the Direct already-local root name
files inside the Linux substrate the provider realizes, so they stay POSIX and the backend's own
POSIX absoluteness check matches them.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal test all --ghc-options=-Werror` from `core/` host-native at 1,877/1,877 in 211.76 seconds,
including every case in the three suites above. Confirming the same gate on the remaining gate host
families belongs to the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md) (§ JJ), not to this sprint.

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
  guard has admitted it — so a row cannot render a delete for a name the guard would have refused.
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

#### Remaining Work

None.

### Sprint 15.25: The shipped ownership row [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Frame.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Add the frame table's third ownership row: the one that runs a transaction where the object is, rather
than where the caller is.

#### Deliverables

- A transaction addressed to a lift context is carried to a process of this same binary at that context
  and interpreted there. An empty context is a local self-fork on this machine; a one-layer context is a
  frame crossing.
- It is a **transport**, not a third implementation of the clauses. Every frame this project reaches is
  Linux, so what executes on the far side is the POSIX row, reached through the same seam producers every
  host-local owner reaches.
- The transaction travels as one value and the receiving process lives exactly as long as the lock it
  holds, so clause 1 stays a kernel fact rather than a release that must be correct on every error path.
  That lock is the protected store's own exclusive entry, taken by the receiving process at the authority
  the transaction names and released by the kernel however that process ends; clause 2 is that store's
  compare-and-swap.
- The transaction's act is a **closed set of four** — observe, take a directory, take a file, give back —
  because those are the four things the seam's producers compose over one object. There is no act that
  runs a command, because a described command travels through the one interpreter (§ KK) and an act that
  could run a string would make this a shell again.
- The argument vector comes from the lift's one fold, so the row adds no rendering of "cross into this
  frame" (§ LL). The crossing itself, its sanitizing, its private protocol channel, and its process-group
  bracket are the [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md)'s,
  which already carries one opaque transaction out and one opaque outcome back and interprets neither;
  this sprint installs the interpreter that entry has always taken as a parameter of the phase that owns
  the object.
- The frame table gains the ownership-primitive column, so a frame declares which row holds its clauses
  beside the tool that reaches it and the grammar its paths obey. The column is a declaration rather than
  a value a caller runs, which is exactly what keeps the shipped row a transport.

#### Validation

The addressing decision, the transaction encoding, and the outcome decoding are pure and are covered by
application over values, including every refusal: every act and every answer round-trips exactly, and an
unknown format, a truncation, a trailing byte, an unknown act, an unknown answer, an unknown refusal, and
a record key the store would not admit are each refused rather than guessed. Every case of the closed
fault sum round-trips, so a refusal that crosses a frame is the refusal that was made.

The empty-context row is exercised against the real kernel through a real child process — the production
classifier, the production child body, and the argument vector the lift fold places at the leaf — and the
object it creates and removes is on the caller's own filesystem, so "the transaction reached another
process" is a property of a program that would not finish if it were false (§ NN).

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

#### Remaining Work

None. The row exists and is reachable; the provider and direct drivers that hold their clauses through it
are the sprint that follows.

### Sprint 15.26: The reported observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Windows.hs`,
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
`core/hostbootstrap-core/test/ProviderReportSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

One total classification from a provider's own output to the observation a clause is held over.

#### Deliverables

- A closed vocabulary names what a provider reports about an instance: the one listing row that names it,
  the two lifecycle states a clause-holding transaction can act from, and one configuration value that
  distinguishes an unset key from an empty one.
- A closed sum names why a report is not a value: a command that produced no child, a provider that ran
  and refused, a success that wrote to standard error, and a report outside the shape this vocabulary
  admits. Each renders once.
- Classification is a total function of the interpreter's own outcome, so the report a driver returns and
  the decision a caller makes are the same value rather than a rendering and a parser.
- The instance listing is reduced to the row naming the exact instance, because the provider matches a
  listing argument by prefix and a sibling name is an absence rather than a hit. The exact name listed
  twice is a refusal rather than a choice between two disagreeing answers.
- A lifecycle state outside the admitted two is refused rather than mapped onto whichever is closer.
- The identity a report carries is admitted through the seam's own producer, so a value outside the
  identity grammar or past the seam's ceiling is a refusal rather than something a release could compare
  against.
- One function joins a listing and an identity read into the `Origin` the seam's reported face is held
  over, and refuses the two ways a provider can contradict itself.
- Nothing in the module executes anything.

#### Validation

Every constructor and every refusal is reached by application over values: an unrun command, a non-zero
exit with and without a diagnostic, a noisy success, a sibling-only listing, a duplicate exact row, a row
of the wrong arity, a row naming no instance, an unadmitted lifecycle state, an over-long line, a control
character, a carriage-return terminator, an unset key, a multi-line configuration answer, an over-long
value, an identity outside the grammar, an identity past the seam's ceiling, and all four joins of a
listing with an identity.

Dated 2026-08-19 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): `ProviderReportSpec`
passed 30/30. Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 2,115/2,115 in 234.17
seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The classification exists and is total; the commands whose outcomes it classifies are the sprint
that follows.

### Sprint 15.28: The described provider commands [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/test/ProviderCommandSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Every outer-host provider effect as a described `HostCommand`, produced by a function that cannot run it.

#### Objective boundary

Every command this sprint renders is interpreted by a process of the **outer host** — the provider's own
client, run where the binary is running. A vector that *crosses into* the instance is not rendered here:
§ LL admits one crossing renderer and it is the lift's own fold, which the
[composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md) owns. The guard the
destructive delete goes through is the frame table's, which Sprint 15.24 built.

#### Deliverables

- Listing, configuration read, device listing, device read, launch, start, stop, and share attachment are
  each a `HostCommand` value naming the frame table's tool for the frame, its exact argument vector, its
  stdio disposition, and the frame whose process reads it (§ KK, § MM).
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

#### Validation

Every argument vector is compared by application over values, which is possible precisely because no
renderer can launch one. The guarded delete's three refusals are exercised through the table rather than
restated, and four shape assertions are total over every command the module renders: each names the frame
table's tool, each lands on the outer host, each carries the described stdio disposition, and none is
empty.

Dated 2026-08-19 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): `ProviderCommandSpec`
passed 18/18. Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 2,133/2,133 in 230.46
seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. Every provider effect is a value; the drivers that compose them with the seam are the sprints that
follow.

### Sprint 15.29: The claimed object [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Primitive.hs`,
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

Every standing and every conflict is reached by application over values, including each combination of an
absent, unbound, and bound record with an absent, matching, and mismatched observation, and each of the
matching, differing, and unset claims. A record another owner wrote is refused for both of its kinds, the
four standings are compared as one list so a missing prefix is a failed equality, and each standing's two
disclosures are total over the four.

Dated 2026-08-19 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): `ProviderResumeSpec`
passed 16/16. Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 2,153/2,153 in 233.28
seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The decision is total; the drivers that act on it are the sprints that follow.

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
- The backend's own report parsers become applications of the total classifier, so the parsing this module
  once owned has one home.
- The suite's cases move from feeding a stand-in runner to applying the classifier to the streams a
  provider produces, so each keeps its subject and loses its stand-in.
- No public or package-private type names an executor, and the source guard that says so is part of the
  sprint.

#### Validation

Every case the injected runner reached is reachable by application, and the source guard proves no
execution seam remains. The declared native Linux/x86_64 KVM/Incus route continues to confirm the live
path.

`ProviderBackendSpec`'s `backendHasNoExecutionSeamCase` is the guard: it asserts that
`Provider/Backend.hs` imports the one interpreter, that it does not import `System.Process`, and that no
production source under `core/hostbootstrap-core/src/` names any of the seven retired executor
identifiers. The lifecycle family beside it drives the production prepared calls end to end against a
real provider client process, so what a case observes is what a provider answered rather than what a
stand-in was handed.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds.

#### Remaining Work

None.

### Sprint 15.32: The provision and readiness drivers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/FakeProvider.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Provision and readiness holding their clauses through the reported face.

#### Deliverables

- Provision enters the protected store the provider's state directory names, records the origin under a
  fresh claim, launches through the one interpreter, classifies the report, and binds the reported
  identity — in that order, because the tokens admit no other.
- Clause 2's publication continuation is idempotent, so a resumed transaction mints its token honestly: a
  first attempt is the store's compare-and-swap from absent, a resumed one is a byte-equality check
  against the record already there, and either way the token asserts the same fact — this record is
  durable.
- Readiness re-observes the bound identity through the report before any dependent mutation.
- The driver runs no interpreter program and parses no report vocabulary of its own, and the prepared
  provision and ready calls consume it in place of the program they ship today.

#### Validation

Every decision is already covered by application through the resumption vocabulary, and the clause-holding
effects are exercised against a real protected store.

The effects run against a real provider client and a real store: `FakeProvider` makes the suite's own
executable the program the one interpreter launches, which is what lets a fixture control the provider
without a seam and without a wrapper the exact argument vector could not survive. The outcome-unknown
window between clause 2 and clause 3 is reached by a client that really performs its launch and then
really dies, and the retry binds the identity without launching a second time. Readiness re-observes
the bound identity across the guest probe, so an instance replaced while the probe ran is a conflict
rather than a readiness.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds. `ProviderBackendSpec` passed 22/22, including the
ten-case lifecycle family this sprint's driver carries.

#### Remaining Work

None for this sprint's own subject. Two coverage items are **owed** and are not this sprint's to close:

- The partial-write, partial-fsync, and partial-unlink crash windows the retired interpreter program
  was patchable at have no instruction point in this driver, because durability is now the protected
  store's. The store's own durability contract is
  [phase 14](phase-14-ownership-clauses-and-reservations.md)'s and is covered by `AuthoritySpec`; what
  is owed is a statement in that phase's terms that the provider driver inherits it, rather than a
  reintroduced patch point here.
- Two rechecks a suite once asserted are not held by this driver and are not claimed: a share does not
  re-observe the *instance* after its device readback, and a delete does not distinguish the same
  identity from a replacement anywhere except after the destructive command. The second is closed by
  Sprint 15.33; the first is named as owed there.

### Sprint 15.33: The share, stop, and delete drivers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

The remaining provider operations on the same face.

#### Deliverables

- A share is an owned object of its own: its device name is derived from the share binding, its origin is
  recorded before the device is attached, and its identity is bound from the device the provider reports.
- Stop and delete re-enter from the durable record, re-observe through the report, act through the one
  interpreter, and forget the record only over a reported absence.
- Delete leaves a same-named replacement untouched, because clause 4 compares the identity rather than the
  name.

#### Validation

Every conflict is reachable by application over values, and the clause-holding effects run against a real
protected store.

Reaching them against a real client found two defects the values alone could not:

- The re-entry every release and every dependent transaction makes republishes clause 2's record, and
  the publication compared *bytes*. A record a previous entry had already bound carries clause 3's
  identity as well, so the comparison refused the transaction's own record as a foreign one and no
  owned instance could be deleted. The publication now compares the kind and the origin — what the
  record says — and treats the binding as the one field a later step of the same transaction adds.
- A delete whose name was taken by a different object between the destructive command and the
  observation after it reported "the exact managed provider remains present". Clause 4 compares the
  identity, so that object is somebody else's: the observation now compares the bound identity and
  reports a replacement, which leaves the object standing and forgets no record.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds.

#### Remaining Work

None. One neighbouring contract this sprint deliberately does not claim — a share re-observing the
*instance's* own standing after its device readback — is carried in the phase's own Remaining Work
below, because it is a property of the boundary rather than of these three drivers.

### Sprint 15.34: Direct canonical-root admission [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

The Direct host's admission as a pure decision over a real observation.

#### Deliverables

- The check that a root is absolute, unfollowed, a directory, and accessible is a total function over an
  observation this binary made, rather than a program delegated to an interpreter.
- Direct still claims no ownership of the host: it publishes no origin, holds no clause, and refuses stop
  and delete.

#### Validation

Every branch of the admission is covered by application over values, and the observation itself is taken
against the real kernel.

`directRootAdmissionCase` hands `admitDirectRoot` the admissible observation and then each of its five
facts negated one at a time, so every refusal is reached by application. `observeDirectRoot` is taken
against the real kernel by the Direct readiness cases: one admits a directory the case created, one
refuses a path under it that does not exist, and one refuses a path that really names the admissible
directory and really is not what this host canonicalizes it to. The symbolic-link refusal is reached by
application rather than by creating a link, because creating one is a privilege some outer hosts
withhold and a case that vanished on those hosts would be a smaller total rather than a failed one
(§ JJ).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds.

#### Remaining Work

None.

### Sprint 15.35: The provider's interpreter program is gone [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
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
- A source guard holds the absence, naming the [rationale](rationale.md) entry that says why a program in
  a string is refused.

#### Validation

The guard fires on a reintroduced program and stays quiet on the legitimate uses elsewhere in the tree.
The declared native Linux/x86_64 KVM/Incus route confirms the whole boundary once more.

What went is the whole of it: the 27KB provider ownership program, the Direct permission program, the
`flock` front end and its discovery, the exclusion-tool vocabulary, and the wire report grammar the
program answered in — together with the `Python3` and `Flock` entries the provider backend resolved
them through. `mkIncusBackendSpec` now resolves `Incus` alone, and the closed `HostTool` set narrows in
[phase 16](phase-16-cluster-lifecycle-and-cordoning.md), where the last driver stops driving an
interpreter.

The opt-in live client follows the boundary it exercises. It audits the Direct realization by taking the
same observation the admission takes and applying the same decision, rather than resolving a program and
comparing its text, and it reads back the protected store's own record rather than the retired sidecar
layout. It also stops spelling its durable intent in POSIX system calls and publishes it through the
ownership row instead, which is the binary's own typed operation over one platform row (§ EE, § LL) — so
the component no longer depends on a POSIX-only package and **every gate host compiles it**. That matters
beyond tidiness: while it could not compile here, nothing on this host type-checked the client against the
boundary it drives, and it had in fact drifted — its backend construction was missing the guard prefix
§ LL requires. It is also what Sprint 2.4 asked for and did not quite get: the suite's own flag is now the
only thing deciding whether the live component is built, where a package dependency was previously
answering "asked for and not built" with a resolver error instead.

The removal has a second, host-portability consequence that § JJ makes a requirement rather than a
bonus. The retired program's suite reached it by nesting a 27KB program inside a 19KB one, which on a
Windows outer host exceeds `CreateProcess`'s 32,767-character command line and fails as
`ERROR_FILENAME_EXCED_RANGE` — reported as "does not exist". Twenty of that suite's cases were
therefore compiled out on Windows behind an `includePosix` guard. Both are gone: the guard is deleted,
the cases are rebuilt against the real provider client, and the whole family runs and is counted on
every gate host.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds.

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
`cabal build -fprovider-live hostbootstrap-provider-live-linux-cpu --ghc-options=-Werror`.

On 2026-08-19, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal test all --ghc-options=-Werror` from `core/`: all 2,153 tests passed in 233.28 seconds, including
this phase's reported-observation, provider-report, described-command, claimed-object, and
resumption-decision families. The same host passed `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231. § II makes this a gate-host record rather than a
substrate declaration: it is the host static gate run natively on a Windows outer host, and it neither
substitutes for the declared native Linux/x86_64 component build nor for the live KVM/Incus run.

On 2026-08-20, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed
`cabal build -fprovider-live hostbootstrap-provider-live-linux-cpu --ghc-options=-Werror` from `core/` —
the first gate host other than Linux on which that component builds at all — and
`cabal test all --ghc-options=-Werror` from `core/`: all 2,227 tests passed in 310.17 seconds,
including this phase's clause-holding provider driver, its Direct canonical-root admission, and the
provider lifecycle family that this phase's final sprints made host-portable. The same host passed
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` at
231. § II makes this a
gate-host record rather than a substrate declaration: it is the host static gate run natively on a
Windows outer host, and it neither substitutes for the declared native Linux/x86_64 component build nor
for the live KVM/Incus run.

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
HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test -fprovider-live \
  hostbootstrap-provider-live-linux-cpu --test-show-details=direct --ghc-options=-Werror
```

Result: `provider-live: PASS — prepared Incus lifecycle/share/alias/restart/delete and mutation-free Direct
refusal`, 1 of 1 test suites passed, 27.75 seconds wall clock on a repeat run from a clean host. The run
confirmed the declared Incus sizing by provider readback (`limits.cpu` 2, `limits.memory` 2GiB, root device
`size` 12GiB), the host-backed share and its guest-visible alias origin, the prepared alias across a stop and
restart, the conditional alias release, and the identity-conditional delete. The Direct route executed
exactly four requests — two canonical-root `lstat`/`realpath` probes and two `docker manifest inspect` egress
probes — and created no provider state. After teardown the run's VM, alias, staging paths, origin records,
and its whole `/var/tmp` root were absent.

## Remaining Work

Every implementation sprint through 15.24 is complete and the baseline acceptance above is confirmed. What
the phase still owes is the rest of its shape rather than its behaviour. § LL makes a provider a **row** over
one closed frame table — the tool that reaches the frame and its argument shape, the frame's path grammar
(§ MM), its sizing renderer, its ownership primitive, and its transfer and share primitives. The guarded
destructive delete is now one computation over that table (Sprint 15.24); the existence probe, the readiness
wait, and the budget-to-wall rendering are already values rather than code paths, each in one module.

The **ownership primitive** is now a column of that table, the third row exists, and the seam has the two
faces a provider needs: Sprint 15.25 supplies the transaction that runs where the object is, and Sprint
15.26 the clause producers over an object whose identity another authority answers for. What is still owed
is the adoption itself. Sprint 15.27 supplies the total classifier that turns a provider's own output
into the observation a clause is held over and Sprint 15.28 the described commands whose outcomes it
classifies. Sprint 15.29 gives the durable record its third kind, so a record can describe an object
another authority owns and carry the claim that closes its outcome-unknown window, and Sprint 15.30 the
resumption vocabulary that decides where a transaction stands.

The adoption itself is now done. Sprint 15.31 moved the backend onto the one interpreter and retired its
injected executor, Sprints 15.32 and 15.33 put every provider operation on the seam, Sprint 15.34 made
Direct's admission a decision this binary applies, and Sprint 15.35 removed the interpreter program the
boundary shipped.

Three things the phase still owes, none of which is a sprint's own subject:

- **the declared live run.** § II makes the static gate a gate-host record, not a substrate
  declaration. The live client now type-checks against the boundary on every gate host, which is what
  caught its drift, but type-checking is not running: the native Linux/x86_64 KVM/Incus baseline
  acceptance below has not been performed against the boundary as it now stands, and it is the only thing
  keeping this phase `Active`.
- **the share's instance recheck.** Attaching a share re-observes the *device* it binds on both sides of
  the attachment, and re-observes the instance's standing before it, but not after the device readback.
  An instance replaced inside that window is caught by the next transaction rather than by that one. No
  record binds an object that was not observed; what is missing is the earlier refusal.
- **the inherited durability statement.** The provider driver's durability is now the protected store's,
  so the partial-write, partial-fsync, and partial-unlink windows the retired interpreter program was
  patchable at have no instruction point here. The store's own contract is
  [phase 14](phase-14-ownership-clauses-and-reservations.md)'s and `AuthoritySpec` covers it; what is
  owed is one statement, in that phase's terms, that this boundary inherits it — rather than a
  reintroduced patch point (§ NN).

Sprints 15.6 through 15.19 describe the mechanism their own boundaries hold today. § A rewrites a phase in
place rather than appending a correction, so those sprints are restated in the same change that moves them
onto the seam — not before it. A plan that described the seam while the code held something else would be
the intended future state rather than the current one, which § C forbids.

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
- `documents/engineering/lima.md` — common provider discovery and bound execution, with native proof in Phase 25.
- `documents/engineering/wsl2.md` — common provider/alias boundary, with native proof in Phase 27.

**Plan and inventory docs to update:**

- `DEVELOPMENT_PLAN/README.md` — status plus the lowest unfinished Phase 15 sprint.
- `DEVELOPMENT_PLAN/system-components.md` — provider realization and ownership surfaces without copied counts.
- `DEVELOPMENT_PLAN/development_plan_standards.md` §§ L, U, DD, and EE — final provider contract ownership.

**Cross-references:**

- Phase 24 owns the demo call-site adoption and destroy-to-up readback.
- Phases 25–27 own native Lima, NVIDIA/Direct, and WSL2 acceptance respectively.
