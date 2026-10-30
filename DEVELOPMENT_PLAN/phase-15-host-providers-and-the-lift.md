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
**Gate evidence**: 2026-09-14 ; `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, KVM readable and writable, Incus 6.0.0, GHC 9.12.4, Cabal 3.16.1.0 ;
`cabal build all` and `cabal test all` from `core/`, then
`HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all
--test-show-details=direct` ; pass ; covers
bf8c604c0a5ca54e70d6927f2ec9c5bbb4542e4d151198f98dd2e91342331018
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`
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

### Sprint 15.2: Uniform provider operation planning [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/Wsl2Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`, `documents/engineering/wsl2.md`,
`documents/architecture/durable_state.md`, `documents/architecture/readiness.md`

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

Closure requires `ProviderSpec` to assert every provider row of each planner: provision, the WSL2 wall order,
stop, guarded delete (`planProviderDelete` for Lima, Incus, and WSL2), the Direct `Unsupported` refusals, share
projection, and probe descriptions; "reboot-to-ready has one result shape" asserts only the `linux` and
`direct` rows. These cases must exist and pass under `cabal test all` from `core/`:

- "reboot-to-ready has one result shape" asserts the exact `RebootReadyPlan` for all four rows, including
  WSL2's empty `rebootStartEffects`, its `rebootCordonReconcile` of
  `Just (ExistsProbe Wsl ["--list", "--running", "--quiet"] WslQuietMember, [hostToolEffect Wsl ["--shutdown"]])`,
  and, for `planProviderRebootReady apple`, exactly
  `RebootReadyPlan {rebootStartEffects = [hostToolEffect Lima ["start", "demo-vm"]], rebootCordonReconcile = Nothing, rebootWaitProbe = WaitProbe Lima ["shell", "demo-vm", "--", "sudo", "-H", "true"]}`
  (the literal argv `Lima.shellVMArgs (LimaVM "demo-vm") ["true"]` produces);
- "stop and guarded delete are explicit" asserts WSL2 delete as
  `[hostToolEffect Wsl ["--unregister", "demo-vm"], ReleaseGlobalWslWall wallBody, hostToolEffect Wsl ["--shutdown"]]`;
- "Incus plans one idempotent disk device" asserts `hpsReconcile linuxShare` (source `/srv/demo/.data`) as the
  literal `ShareReconcile` whose `srMember` is `"hb-share-82a329e0f07a"` and whose `srWhenMissing` is
  `[hostToolEffect Incus ["config", "device", "add", "demo-vm", "hb-share-82a329e0f07a", "disk", "source=/srv/demo/.data", "path=/srv/demo/.data"]]`;
  that `shareReconcileEffects linuxShare "root\nhb-share-82a329e0f07a\neth0\n"` is `[]`; that the listing
  `"root\nhb-share-a017dbabc79b\neth0\n"` (the device for `/srv/other/.data`) yields exactly `srWhenMissing`;
  that the listing `"root\neth0\n"` yields exactly `srWhenMissing`; and that the listing
  `"root\nhb-share-82a329e0f07a-old\n"` yields it too (membership is exact-line, not substring);
- "membership parsers are total" asserts
  `membersOf WslQuietMember (concatMap (\c -> [c, '\0']) "demo-vm\nother\n")` (NUL-interleaved
  `--running --quiet` output, the encoding `Wsl2Spec`'s `utf16ish` builds) as `["demo-vm", "other"]`, and
  carries no `WslRunningMember` row;
- a `ProviderSpec` source guard asserts `Substrate/Provider.hs` names none of `classifyAlias`, `AliasFacts`,
  `planAliasEnsure`, `planAliasRemove`, `planProviderAlias`, and `trimTrailingSlash`.

#### Remaining Work

- Append `hostToolEffect Wsl Wsl2.wslShutdownArgs` after `ReleaseGlobalWslWall body` in the WSL2 row's
  `spDestroy` in `Substrate/Provider.hs`, and update the WSL2 delete assertion in `ProviderSpec`'s "stop and
  guarded delete are explicit" case to the three-effect list.
- In the Incus row's `spShare`, replace the fixed device name `"durable-data"` with the source-derived name
  the Deliverables state, computed by a module-private helper in `Substrate/Provider.hs` itself (importing
  `Crypto.Hash` and `Data.ByteArray.Encoding` from the `crypton` and `memory` packages the library already
  depends on), since `Provider/Backend.hs` imports `Substrate/Provider.hs` and cannot be imported back; use
  the one name for both `srMember` and the `addDiskDeviceArgs` effect; replace the `"durable-data"` literals in
  "Incus plans one idempotent disk device" with the literal assertions Validation states. The row's device
  is reached by `ProviderSpec`, not by production: the demo calls
  `shareReconcileEffects` only through `reconcileDurableShare` in `demo/src/HostBootstrapDemo/Commands.hs`,
  which `runCopySource` reaches only on the non-Incus/Lima (WSL2) route, whose row carries no
  `ShareReconcile` and so yields `[]`; Incus production shares go through `runExactVmShare` and
  `withPreparedProviderShare`, never through this row's `durable-data` device.
- Delete the alias state machine from `Substrate/Provider.hs` — `AliasNodeKind`, `AliasState`, `AliasFacts`, `classifyAlias`,
  `trimTrailingSlash`, `AliasAction`, `planAliasEnsure`, `AliasRemoval`, `planAliasRemove`, and
  `planProviderAlias` with their exports — which no production module calls, together with `ProviderSpec`'s
  alias classifier, alias planner, and alias dispatch cases; add the source guard above.
- Rewrite the alias passages of `documents/architecture/durable_state.md` (the paragraph naming
  `classifyAlias`, `planAliasEnsure`, and `planAliasRemove`, and the `AliasState` ensure/removal table) and
  `documents/architecture/readiness.md` (the `classifyAlias`/`AliasFacts` paragraph and its `text` block) to
  state that guest-alias classification lives only in the prepared alias route: `reconcileNodeGuestAlias` and
  the `AliasCallResultView` that `aliasCallResultView` returns, in `Substrate/Provider/Alias.hs`. Neither
  document names a deleted identifier afterwards.
- In the WSL2 row's `spReconcileCordon`, probe `wsl --list --running --quiet` with `WslQuietMember`
  (`Wsl2.wslListDistros`) instead of `--list --verbose` with `WslRunningMember`, and update the
  reboot-to-ready assertion to the literal above. Delete `WslRunningMember` and its `membersOf` clause from
  `Substrate/Provider.hs`, and `wslRunningDistros` and `wslDistroStates` with their exports from `Wsl2.hs`;
  delete the `membersOf WslRunningMember` assertion from `ProviderSpec`'s "membership parsers are total" and
  add the `WslQuietMember` row Validation states; delete the `wslDistroStates` and `wslRunningDistros`
  assertions from `Wsl2Spec`'s "wsl list parsers handle UTF-16 NULs, the default marker, and the header",
  keeping its `wslListDistros` assertion.
- Extend "reboot-to-ready has one result shape", which asserts only the `linux` and `direct` rows, with
  `planProviderRebootReady windows` and `planProviderRebootReady apple`, each asserted as the whole
  `RebootReadyPlan` literal Validation states (the Lima row is `spStartExisting` and `spWait` of the Lima
  provider in `Substrate/Provider.hs`).

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

### Sprint 15.6: Closed raw provider discovery [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/readiness.md`,
`documents/architecture/durable_state.md`

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
- Private total parsers classify a zero exit as Ready without reading stdout; a non-zero exit whose output
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

Closure requires these cases to exist and pass under `cabal test all` from `core/`:

- `ProviderBackendSpec` drives `discoverProvider` through `withRunningProvider` and `withProviderBoundExec`
  against the `FakeProvider` client: all three guest probes Ready yields an all-Ready guest discovery; a guest
  `true` answering "not found" yields daemon Ready, VM Unavailable, egress Unavailable; a listing answering
  "not found" records no guest invocation; a guest `true` answering "not ready" once and then succeeding is
  Ready after exactly two guest invocations; a guest `true` answering an unclassified failure is invoked once;
  and a `SubstrateProvider` whose VM name differs from the bound backend's returns
  `Left ProviderOperationFailure{providerErrorOperation = ProviderGuestRoute}` with no probe recorded.
- `ProviderSpec` applies the exported probe classifier and conflict-marker parser to values: each NotReady and
  Unavailable prefix, an unclassified non-zero exit (Failure naming the exit code), a zero exit with arbitrary
  stdout (Ready), a well-formed single-line marker (Conflict carrying the three tokens), and a two-line
  marker, a token containing a character outside `[A-Za-z0-9:._/=-]`, a 241-character token, and a
  five-token line (each Failure).
- A compile-fail fixture registered in `CompileFailSpec` constructs `ProviderProbeRequest` through
  `import HostBootstrap.Substrate.Provider` and is rejected.

#### Remaining Work

- Fix `runDiscoveryPlan`/`blockedGuestDiscovery` in `Substrate/Provider.hs` so a Ready prefix is retained as
  observed and only the slots after the blocking probe take its observation; type `propagateObservation`'s
  argument so a Ready observation cannot reach it, deleting its Ready-to-Failure branch.
- Delete the `discoveryPermissions` slot of `GuestProviderDiscovery` and the second `existsRequest` probe
  from `providerDiscoveryPlan`; `discoverStrongAliasBackend` in `Provider/Alias.hs` stops requiring
  "provider permissions". `DirectProviderDiscovery` keeps its permission slot, which is a distinct probe.
- Delete `ProviderSpec`'s "discovery reports are structurally guest or Direct" case: it asserts `x @?= x` for
  each value, so only a broken derived `Eq` could fail it. The `ProviderBackendSpec` discovery cases above
  assert per-slot reports that differ by slot, which is the property it named.
- Export the pure probe classifier (today's private `parseUnit`) and `providerConflictMarker` from
  `Substrate/Provider.hs`, and add the `ProviderSpec` value cases above.
- Add the `ProviderBackendSpec` discovery cases above, extending `FakeProvider`'s guest handler to answer the
  guest `true` probe with a scripted sequence of outcomes.
- Add `test/compile-fail/ConstructProviderProbeRequest.hs` and register it in `CompileFailSpec.hs`.
- Correct two comments to the code: `DirectProbe`'s Haddock in `Provider/Internal.hs` names its one
  constructor and says egress is the separate `ProviderProvisioningEgressProbe` request; `ProviderSpec`'s
  module header names `ProviderBackendSpec` as the home of the discovery cases.

### Sprint 15.7: Managed provider capability [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`, `core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

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

Compile-fail fixtures (`ForgeProviderCapability.hs`, `CoerceProviderCapabilityIdentity.hs`,
`EscapeProviderCapabilityIdentity.hs`, `CrossPlanBudgetProviderCapability.hs`) reject forgery, coercion,
escape, and cross-provider substitution. Closure also requires a `ProviderBackendSpec` case that mints an
Incus capability through `discoverProvider` against the `FakeProvider` client and asserts
`providerCapabilityKind` is `ProviderIncus`, `providerCapabilityGeneration` equals the running handle's
generation, and `providerCapabilityDiscovery` is the guest discovery the probes produced, plus the same
assertions for a Direct capability (`ProviderDirectHost`, a `ProviderDirectDiscovery`). `ProviderSpec`'s
source guard asserts no production source under `core/hostbootstrap-core/src/` names
`ProviderGuestExecutor`, `bindProviderGuestExecutor`, `runProviderGuestExecutor`, or
`providerCapabilityGuestExecutor`. All run under `cabal test all` from `core/`.

#### Remaining Work

- Delete `ProviderGuestExecutor`, `bindProviderGuestExecutor`, and `runProviderGuestExecutor` from
  `Provider/Internal.hs`, the `Maybe ProviderGuestExecutor` field of `ProviderCapability`, the guest-executor
  binding in `discoverProvider`, and `providerCapabilityGuestExecutor` with its exports from
  `Substrate/Provider.hs`; nothing in the source tree runs that executor.
- Delete the `providerCapabilityGuestExecutor` check from `exerciseDirect` in
  `provider-live/ProviderLiveAliasFixture.hs`; the Direct guest refusal it confirms live is the
  `discoverStrongAliasBackend` `Unsupported` check beside it.
- Rewrite `Provider/Internal.hs`'s module header and `ProviderCapability`'s Haddock to the retained fields
  above, and add the positive accessor cases and the source-guard identifiers above.

### Sprint 15.8: Validated backend description [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

Admit only complete, bounded Incus and Direct backend descriptions.

#### Deliverables

- `ProviderBackendSpec` is abstract and constructed by total validation functions.
- Incus retains the instance name, image, the project's destructive-delete guard prefix, the resolved `incus`
  executable, an absolute state directory, and CPU, memory, and storage sizing.
- Direct retains an absolute local root, the resolved `docker` executable, and the egress image.
- Backend execution receives an opaque request with a read-only process view.
- Invalid substrate, unresolved tool, unbounded value, and ambiguous path inputs fail closed.
- Admission bounds the Incus instance name by what the provider's per-device control-socket pathname
  admits, counted in UTF-8 bytes as the `sun_path` budget is, so a declaration whose share device could not
  attach is refused before discovery.
- The Incus instance name and the guard prefix obey the ASCII hostname grammar Incus enforces: `[a-z0-9-]`,
  no leading digit or hyphen, and no trailing hyphen on the name. Memory and storage are ASCII digits with an optional Incus
  unit suffix.
- The executable folded into the realization fingerprint is the one every provider call runs: runtime
  resolves the tool from the stored spec, or refuses a host configuration whose resolved tool differs from it.
- A non-zero backend call folds its provider diagnostic into the bounded single-line token vocabulary
  rather than discarding it, so a refusal names the condition it observed.

#### Validation

`ProviderBackendSpec` covers valid descriptions, the wrong substrate, the socket-pathname bound, an
unresolved tool, a name missing the guard prefix, and the Lima and WSL2 host and kind refusals. Closure
requires one `ProviderBackendSpec` refusal case per remaining guard, each asserting the
`Failure`/`DoNotRetry` reason text: for `mkIncusBackendSpec`, the names `hb_vm`, `hb.vm`, `-hbvm`, `hbvm-`,
and a non-ASCII name (`hbvmé`), an empty or non-portable guard prefix, a name whose character count is within
the socket bound but whose UTF-8 byte count is not, an empty image and an image containing NUL, a relative
state directory, `cpu == 0`, and memory or storage quantities `lots`, `GiB4`, and one carrying a non-ASCII
digit; for `mkDirectHostBackendSpec`, a relative root, a root containing NUL, and an empty egress image and
one containing NUL. A further case runs an Incus call with a `HostConfig` whose `incus` resolves to a
different path from the one admitted and asserts the refusal (or that the admitted path is the one
launched). All run under `cabal test all` from `core/`.

#### Remaining Work

- Add the refusal cases above to `ProviderBackendSpec`.
- In `Provider/Backend.hs`, replace `safeName` for the Incus name and guard prefix with an ASCII hostname
  predicate (`[a-z0-9-]`, first character a letter, last not a hyphen; the prefix may end in a hyphen),
  measure `maxIncusInstanceNameLength` against the UTF-8 byte length, and replace `safeQuantity`'s
  `isAlphaNum` with ASCII digits plus an optional unit from Incus's set (`kB`, `MB`, `GB`, `KiB`, `MiB`,
  `GiB`, `TiB`, and the like); correct the Haddocks that describe these guards.
- Make the Incus runtime use the executable retained in `IncusBackendSpec` (today
  `withOwnedProviderTransaction` binds it as `_executable` and the calls re-resolve the tool from the
  discovery `HostConfig`), or refuse a `HostConfig` whose resolved `incus` differs from it, so the
  realization fingerprint names the tool that runs.
- Correct `mkIncusBackendSpec`'s Haddock in `Provider/Backend.hs`: admission checks only that the state
  directory is absolute, and the protected store establishes it when a transaction enters it; no discovery
  proves the executable or the directory.

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

### Sprint 15.10: Prepared provider provision [Active]

**Status**: Active
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

Reconcile specs cover Created, Repaired, Unchanged-with-proof, Foreign, and every refusal; real-process
backend specs cover concurrent provision and crash recovery. `ProviderReconcileSpec` reaches the answers
through `classifyProviderProvisionCall` and `classifyProviderReadyCall`, which wrap the same
`provisionObservation` and `readyObservation` mappings the prepared calls apply. The foreign-provider case
asserts only the resource key, and the "wrapper retains the provider origin" and Direct owner assertions read
back the prepared binding rather than settlement output. Closure requires, under `cabal test all` from
`core/`: the foreign-provider case asserting that the `ForeignObservation` detail contains `foreign-provider`
and that the settled generation is the foreign identity's; and the origin and Direct owner assertions taken
from the settled `ManagedProviderHandle`, or their messages renamed to say they read the prepared binding.

#### Remaining Work

- Strengthen `ProviderReconcileSpec`'s foreign-provider, wrapper-origin, and Direct-owner cases as Validation
  states.

### Sprint 15.11: Prepared provider readiness [Active]

**Status**: Active
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
- Settlement returns only the same backend-indexed Running provider, and the advance retains the source
  phase it left, so carrying its settlement names the predecessor the transition really had: a boot carries
  from Provisioned, a restart from Stopped, and only a Provisioned-origin advance can be carried as a
  provider created in the same step.
- The running-provider reprobe a dependent runs compares what the provider reports against the managed
  handle: a replaced instance is `Conflict`, and a realization that cannot observe identity (Lima, WSL2)
  answers `Unsupported` for identity-sensitive dependents rather than echoing the handle's generation back.
- A dependency package's consumed nonces outlive its registration: re-registering the exact running-provider
  or provider-share package keeps the nonces already consumed, so a replayed nonce is refused.

#### Validation

Specs cover both legal source phases, invalid phase substitution, NotReady retry, terminal outcomes, Direct
validation, and replacement at every readiness observation boundary. Closure requires a compile-fail fixture
registered in `CompileFailSpec` that applies `carryCreatedRunningProviderSettlement` to a Stopped-origin
advance and is rejected, `CoerceProviderPhaseAdvanceRoles.hs` covering the added index, and the
`ProviderBackendSpec` carry at its runtime-package case passing with the source phase derived from the
advance, all under `cabal test all` from `core/`, plus the demo gate under `cabal test all` from `demo/`.
It also requires two `ProviderBackendSpec` cases on the `FakeProvider` host: a running-provider reprobe after
the instance was replaced under the same name returns `Left (Conflict ...)`; and a running-provider package
registered, invoked with a nonce, registered again identically, and invoked with the same nonce refuses the
second invocation as a replay.

#### Remaining Work

- Index `ProviderPhaseAdvance` in `Provider/Reconcile.hs` by its source phase as well as its target
  (`ProviderPhaseAdvance scope planId backendId providerId fromPhase toPhase`); `settleProviderReady` returns
  the `fromPhase` its `PreparedProviderReady` carried, the stop and delete settlements carry theirs, and the
  Running-advance consumers in `Provider/Backend.hs` take the added index.
- Drop the free `Text` source-phase argument of `carryRunningProviderSettlement` and derive `"provisioned"`
  or `"stopped"` from the advance's index; restrict `carryCreatedRunningProviderSettlement` to a
  `Provisioned`-origin advance. Update the `ProviderBackendSpec` call site and the two demo call sites in
  `demo/src/HostBootstrapDemo/Commands.hs`.
- Add `test/compile-fail/CarryCreatedRestartedProvider.hs` and register it in `CompileFailSpec.hs`.
- In `Provider/Backend.hs`, `settleRunningProbe`'s generation comparison never fires: every producer in
  `probeRunningProvider` (the Direct branch, `readyObservation`, `observeLimaReady`) stamps
  `managedProviderGeneration managed` into the observation it compares with. Carry the observed identity (or a
  generation derived from it) out of `readyOwnedInstance` through `readyObservation`, make `observeLimaReady`
  answer `Unsupported` where identity cannot be observed, or delete the comparison and its `Word64` payloads;
  add the replacement reprobe case.
- In `registerRunningProviderDependencyPackage` and `registerProviderShareDependencyPackage`, stop allocating a
  fresh `usedNonces` `IORef` per registration (an exact re-registration converges in
  `registerStepRuntimeDependencyPackage` but `replaceStepRuntimeDependencyService` installs the new closure,
  forgetting the consumed set): keep the consumed-nonce set in the step runtime keyed by package, or keep the
  closure already registered. Add the replay case.

### Sprint 15.12: Prepared durable share [Active]

**Status**: Active
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

`ProviderReconcileSpec` covers sealing the managed provider and path declaration, Created, Repaired,
Unchanged with matching proof, a failed fresh provider probe refusing preparation, relative-path refusal, and
the Direct prior-proof path. `ProviderBackendSpec` covers attach and restart in its full lifecycle case, the
exact-share idempotence and changed-device conflict (`shareReadbackCase`), and instance replacement after the
device readback and after the activating restart. Closure requires a `ProviderReconcileSpec` case whose share
node's plan declares no dependency on the provider: `withPreparedProviderShare` returns `Left (Conflict ...)`
naming the provider key and prepares no call. The "a failed fresh provider probe refuses share preparation"
case injects `dependencyProbe (pure providerProbe)` rather than the production reprobe, so closure also
requires cases that obtain the probe through `withRunningProviderDependency`: an Incus provider on the
`FakeProvider` host whose ready reprobe fails, and a Direct provider whose `docker` stand-in refuses the egress
probe, each refusing share preparation with the failure that reprobe produced. All run under
`cabal test all` from `core/`.

#### Remaining Work

- Add the two `withRunningProviderDependency`-sourced probe refusal cases above to `ProviderReconcileSpec` (or
  beside the `FakeProvider` fixtures in `ProviderBackendSpec`).
- In `withPreparedProviderShare` (`Provider/Reconcile.hs`), require `resourceHandleKey providerHandle` to be
  among the share descriptor's declared dependency keys before sealing, refusing with `Conflict` otherwise,
  and add the `ProviderReconcileSpec` case above.
- Move the orphaned `{- | Total observation of the provider-side share primitive ... -}` block in
  `Provider/Reconcile.hs` onto `ProviderShareObservation` in `Provider/Observation/Internal.hs`, so
  `ProviderShareSpec` carries only its own Haddock.
- Correct the `shareDevicePrefix` Haddock in `Provider/Backend.hs`: a same-named device carrying a different
  binding is refused as a conflict by the owned share transaction's device readback.

### Sprint 15.13: Prepared provider stop [Active]

**Status**: Active
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

Specs cover the finite stop vector, stop, idempotence, retry, Direct refusal, malformed reports, and replacement
at each observation. `ProviderReconcileSpec`'s "a replacement cannot settle a prepared stop" accepts any
`Conflict` on `core:deploy-vm`, so a conflict raised for another reason passes it. Closure requires that case
to assert that the conflict's observed text contains `replacement-vm` and that its reason names the stop and
the replacement, under `cabal test all` from `core/`.

#### Remaining Work

- Strengthen `ProviderReconcileSpec`'s "a replacement cannot settle a prepared stop" case as Validation states.

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

### Sprint 15.15: Provider-bound execution [Active]

**Status**: Active
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

`ProviderBackendSpec`'s readiness and share cases run guest commands through the bound backend and recheck
the instance identity across them; bound discovery is Sprint 15.6's case set. Negative fixtures reject raw
projection, cross-backend use, generic-handle use, and capability substitution.

No case calls `withProviderBoundExec` (only the compile-fail fixture `GenericProviderHandleAsBoundExec.hs`
names it), and none of `validateProviderOrigin`'s three `Conflict` refusals is produced. Closure requires,
under `cabal test all` from `core/`: a `ProviderBackendSpec` case that obtains a `ProviderBoundExec` through
`withProviderBoundExec` for a Running Incus provider on the `FakeProvider` host and runs a bound request
through it; and three cases that build a `ManagedProviderHandle` through the
`Provider/Observation/Internal.hs` constructor with, in turn, an origin resource key different from the
handle's, an origin generation different from the handle's, and an origin backend binding from another
realization, each returning `Left (Conflict ...)` with the reason `validateProviderOrigin` gives and running
no provider command.

#### Remaining Work

- Add the `withProviderBoundExec` happy-path case and the three mismatched-origin `Conflict` cases above to
  `ProviderBackendSpec`.

### Sprint 15.16: Prepared guest-alias call [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Observation/Internal.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

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

Compile-fail fixtures (`ForgePreparedGuestAliasCall.hs`, `CrossAliasCallResult.hs`,
`CrossBackendAliasCall.hs`, `GenericShareHandleAsAliasAuthority.hs`, `ObservedReadyGuestAlias.hs`) cover the
nominal indices and generic-handle substitution. Closure requires cases that call `withPreparedGuestAliasCall`
over a backend, managed provider, and managed share minted through `ProviderBackendSpec`'s `FakeProvider`
fixtures: a successful preparation; a backend from a different provider generation, a share from a different
provider origin, and a planned alias from a different plan digest, each returning `Left (Conflict ...)`; and a
failing share probe refusing preparation. All run under `cabal test all` from `core/`.

`ProviderAliasSpec`'s descriptor cases also need to be able to fail. Its `rejected` helper accepts any
`Left`, so the relative-alias, relative-target, Windows-alias, and trailing-slash cases still pass when the
guard they name is removed (`guestLexicallyUnambiguous` refuses the same inputs), the NUL guard has no case, and
"distinct canonical absolute POSIX paths are admitted" admits `/srv/hostbootstrap` over
`/srv/hostbootstrap/data`, an alias that is an ancestor of its target. Closure requires each `rejected` case to
match the `FailureDetail` reason it expects (the `validate provider guest alias` label, the guard's reason text,
and `DoNotRetry`); a NUL case (`"/srv/a\0b"`); an ancestor-alias case and an alias inside
`<target>/.hostbootstrap-alias-authority-v1`, each refused; and the admitted case rebuilt over unrelated
paths (for example `/srv/alias` over `/mnt/data`).

#### Remaining Work

- Add the `withPreparedGuestAliasCall` cases above, in `ProviderAliasSpec` or beside the fixtures in
  `ProviderBackendSpec`; a fixture shared by both suites moves into a test-support module.
- In `mkGuestAliasSpec` (`Provider/Alias.hs`), refuse an alias whose segments are a prefix of the target's
  segments, and an alias at or under `<target>/.hostbootstrap-alias-authority-v1`.
- Make `ProviderAliasSpec.rejected` take the expected reason and assert the whole `FailureDetail`, and add the
  NUL, ancestor, authority-directory, and unrelated-paths cases above.

### Sprint 15.17: Strong alias backend admission [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
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

Compile-fail fixtures (`ForgeStrongAliasBackend.hs`, `CrossBackendAliasCall.hs`) cover forgery, coercion,
and cross-provider execution, and `ProviderAliasSpec`'s source guard holds the absence of the guest lock,
stat, and interpreter probes. Closure requires cases that apply `discoverStrongAliasBackend` to capabilities
minted through `discoverProvider` against the `FakeProvider` client: an all-Ready guest discovery admitted
with the capability's generation; a guest `true` answering "not found" refused as `Unsupported` labelled
"provider VM capability"; an egress Unavailable admitted; an egress unclassified failure refused; and a Direct
capability refused as `Unsupported`. All run under `cabal test all` from `core/`.

#### Remaining Work

- Add the `discoverStrongAliasBackend` cases above; they depend on Sprint 15.6's retained-prefix discovery so
  that a blocked VM probe is reported under its own label rather than as a failed daemon.
- Rewrite the `runPreparedGuestAliasCall` Haddock in `Provider/Alias.hs`, which still describes a retained
  guest lock, a fresh nonce, and nonce-named staging, to the shipped transaction it runs.

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

### Sprint 15.19: Prepared alias acquisition adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

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

#### Validation

Closure requires cases that run `runPreparedGuestAliasCall` and `settlePreparedGuestAliasCall` against a
`FakeProvider` guest whose handler runs the shipped argv as a local child of the suite executable, as
`OwnershipShippedSpec`'s empty-context crossing does: a first take settles Created; a second prepared call
for the same alias without a prior proof settles Repaired and with the `PriorCommitProof` of the first
settles Unchanged; an exact-looking unrecorded link settles Foreign and is left in place; a record whose
claim names a different link target settles as a `DoNotRetry` failure; and a shipped answer of
`ShippedRefused (OwnershipConflict _)` (a link replaced after the record bound it) settles as
`Left (Conflict ...)`. All run under `cabal test all` from `core/`; the kernel-backed cases keep the platform
condition `ProviderAliasSpec`'s shipped-ownership cases use.

#### Remaining Work

- Delete `aliasOwnerBinding` and the owner `Text` field from `PreparedGuestAliasCall`,
  `ManagedGuestAliasHandle`, and `PreparedGuestAliasRelease` in `Provider/Alias.hs`: it is computed and
  threaded through settlement and release but never shipped, stored, or compared, and its Haddock says the
  record stores it. Rewrite the Haddocks that describe a stored or compared owner binding — the
  `withPreparedGuestAliasRelease` Haddock (release reuses the owner text) and the `ManagedGuestAliasHandle`
  Haddock (the constructor retains "the exact spec/owner") — to ownership keyed by alias path and target, as
  the record identity above states.
- Add the settlement cases above, including the `OwnershipConflict` mapping case.

### Sprint 15.20: Conditional alias release [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
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

`ProviderAliasSpec` covers release after create and an external unlink converging by forgetting only the
bound record, with a repeated release given back again; `OwnershipShippedSpec` covers a replacement refused
on release and left intact; `ForeignGuestAliasRelease.hs` rejects foreign authority. Closure requires
`withPreparedGuestAliasRelease` cases over a managed alias settled through the Sprint 15.19 fixture: version
`0` returns `Left (Failure ...)` with `DoNotRetry`, a version other than the handle's observation version
returns `Left (Conflict ...)`, and neither reaches the guest; plus a `runPreparedGuestAliasRelease` case over
a replaced link returning `Left (Conflict ...)`. All run under `cabal test all` from `core/`.

#### Remaining Work

- Add the `withPreparedGuestAliasRelease` fence cases and the `runPreparedGuestAliasRelease` replacement
  case above.

### Sprint 15.21: Node alias-route adoption [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
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

No spec calls `reconcileNodeGuestAlias`: `ProviderAliasSpec` holds only the descriptor cases and the shipped
row's kernel cases. Closure requires `reconcileNodeGuestAlias` cases driven through the real chain interpreter
over a node descriptor whose provider, share, and alias projections come from the `FakeProvider` fixtures
the Sprint 15.16 cases use: a node whose dependencies are all present settles a managed alias change; a
node missing its provider or share dependency, a node carrying a stale provider generation, and a node whose
share was derived from another provider origin each refuse before any guest call (the fake provider records
no `exec`); a provider handle, and separately a share handle, whose resource key is not the planned
resource's key each return the `Conflict` naming both keys before any guest call; a node whose alias path
holds an unrecorded exact-looking link settles as the descriptive foreign observation; and a second run over
a node whose alias the first run created settles as `GuestAliasReconciled` with the repaired change view, not
created and not foreign. All run under `cabal test all` from `core/`. The demo's call
site in `demo/src/HostBootstrapDemo/Commands.hs` is the worked-demo phase's.

#### Remaining Work

- Add the `reconcileNodeGuestAlias` cases above to `ProviderAliasSpec` (or beside the `FakeProvider`
  fixtures in `ProviderBackendSpec`), each asserting the exact `ReconcileError` constructor and, for the
  refusals, that the fake provider's recorded mutations and guest execs are empty.
- Rewrite the `reconcileNodeGuestAlias` Haddock in `Provider/Alias.hs`, which says provider and share are
  resolved through `withNodeResourceOfKind` and that the share handle is the one carried through
  `withCarriedManagedResource`, to say what the function checks: the caller supplies both, this function
  compares keys, and `withPreparedGuestAliasCall` checks generation and origin.
- In `settlePreparedGuestAliasCall`, delete the `AliasCallAlreadyExact` generation-mismatch branch, which
  compares the handle's generation with the same generation `shippedAliasObservation` stamped from that
  handle and so never fires, and drop the `Word64` payloads of `AliasCallObservation`. Correct the
  `AliasCallObservation` Haddock ("a compatible link without prior commit proof is explicitly foreign") to the
  settlement the code makes: a retained exact link settles Repaired without a prior commit proof and Unchanged
  with one. Add the rerun case listed in Validation.

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

From `core/`, `cabal build all --ghc-options=-Werror` compiles the component on every host. The
`ProviderSpec` source guard rejects raw lifecycle planners, opaque
provider-authority constructor imports, the private/independent guest executor, and any Direct delete path
after the prepared stop refusal. The phase's baseline acceptance below records the confirmed live route.

Closure requires the fixture changes in Remaining Work, compiled by `cabal build all` from `core/` on every
gate host, and a passing `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host cabal test all
--test-show-details=direct --ghc-options=-Werror` run on the native Linux/x86_64 KVM/Incus host, recorded in
the phase-level baseline acceptance.

#### Remaining Work

- In `ProviderLiveAliasFixture.continueProvisioned`, run the initial `readyProvider` through
  `attemptReconcile` so a thrown `fail` from `gateFor` (protected store open, record key, or durable record) or
  an `IOException` from the ready call becomes a `Left` that takes the existing `recoverProvisioned` path; wrap
  `recoverProvisioned` in `attemptReconcile` as the later `cleanupProvider` call already is.
- Make `combineBodyRelease` report both failures when the body and the release both fail, in the
  `"body failure: ...; release failure: ..."` form `combinePrimaryCleanup` uses, so a failed restart is not
  hidden behind the alias release it caused.
- In `ProviderLiveRunner.assertAliasOriginState`, count staging residue as entries containing `.rec.tmp-` (the
  protected store's staging grammar) instead of `.prepared-`, which no production writer produces; prefer a
  staging-name predicate exported from `HostBootstrap.Protected` so the gate reads the writer's own grammar.
- In `ProviderLiveRunner.assertProviderRecordForgotten`, flag every entry that starts with `<vm>.` (instance
  record, share records `<vm>.<device>.rec`, and their `.rec.tmp-` staging), not only `<vm>.rec`.
- In `ProviderLiveRunner.verifyOwnedState`, list with `-c ns` and assert the state of the one row whose name
  equals `vmName`, as `observeIncusPresence` already selects by exact name, because `incus list <name>` matches
  by prefix and a preserved `hostbootstrap-provider-live-12345` VM breaks a run whose token is `1234`.
- In `runProviderLiveGate`, run `buildHostConfig`, `requireIncusPreflight`, and the collision check before
  `createTempDirectory` (or remove the root on any failure before `writeDurableIntent`), and print
  `cleanupRemedy`'s preserved-intent text only after `writeDurableIntent` has succeeded; a failure before it
  names no VM.
- Make `ProviderLiveAliasFixture.liveStepPlan` an `Either` and pass it to `withLiveProjectPlan`'s builder
  callback, which already takes an `Either`, instead of `error . show` on a `mkStepPlan` refusal.
- Rewrite the `runLiveIncusRoute` Haddock to name all three callbacks: `prepareGuest` runs after the share
  settles and before the alias is claimed (no release follows a failure there), and `beforeRestart` and
  `afterRestart` run while the alias is held. Move the guest-self-path paragraph above `runProviderRoute` to
  `liveGuestSelfPath` in `ProviderLiveRunner.hs`, and give `runProviderRoute` its own Haddock.

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

### Sprint 15.24: The one guarded destructive delete [Active]

**Status**: Active
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

Closure requires the Haddock rewrite below, with the guarded-delete group and the three import guards still
passing under `cabal test all` from `core/`.

#### Remaining Work

- Rewrite the `guardedDeleteArgs` Haddock in `Substrate/Frame.hs`, which says "a provider module cannot render
  a delete for a name the guard would have refused", to say that the row receives only the admitted name and
  that passing it through is the rows' convention, which the types do not enforce.

### Sprint 15.25: The shipped ownership row [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Frame.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`, `core/hostbootstrap-core/test/Spec.hs`
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
- It is a **transport**, not a third implementation of the clauses. What executes on the far side is this
  binary's own host row for that frame — the POSIX row in a Linux guest, and the outer host's own row
  (Darwin publishes a symbolic link by `renamex_np(RENAME_EXCL)`, Windows answers `OwnershipUnsupported` for
  the symbolic-link acts) under an empty context — reached through the same seam producers every host-local
  owner reaches.
- The transaction travels as one value and the receiving process lives exactly as long as the lock it
  holds, so clause 1 stays a kernel fact rather than a release that must be correct on every error path.
  That lock is the protected store's own exclusive entry, taken by the receiving process at the authority
  the transaction names and released by the kernel however that process ends; clause 2 is that store's
  compare-and-swap.
- The transaction's act is a **closed set of six** — observe, take a directory, take a file, give back, and
  the guest-alias owner's symbolic-link take and give-back — because those are the things the seam's
  producers compose over one object. There is no act that runs a command, because a described command
  travels through the one interpreter (§ KK) and an act that could run a string would make this a shell
  again.
- The authority root, the target object, and a symbolic link's target are three distinct path types, each
  produced only from a non-empty absolute POSIX path in the far frame's grammar; the transaction decoder
  refuses an empty or relative one as `OwnershipMalformed`, so transposing two roles is a type error and a
  relative path never reaches the far side's working directory.
- A retried take answers Taken only when the stored record's kind is the act's kind (a directory, or a file
  carrying this payload's digest) and the target re-observes as the bound identity; an unbound record an
  interrupted take left behind is resumed when the target is absent and refused as a conflict when something
  stands there, so no key is wedged. The near side keeps a crossing failure, an outcome it cannot decode, and
  a frame refusal as three distinct values.
- The argument vector comes from the lift's one fold, so the row adds no rendering of "cross into this
  frame" (§ LL). The crossing itself, its sanitizing, its private protocol channel, and its process-group
  bracket are the [authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md)'s,
  which already carries one opaque transaction out and one opaque outcome back and interprets neither;
  this sprint installs the interpreter that entry has always taken as a parameter of the phase that owns
  the object.
- The frame table gains the ownership-primitive column, so a frame declares which row holds its clauses
  beside the tool that reaches it and the grammar its paths obey. The column is a declaration rather than
  a value a caller runs, which is exactly what keeps the shipped row a transport: no production module asks
  it whether to ship, so the module exports no `frameOwnsLocally` decision and its Haddock claims none.

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

Closure requires these cases in `OwnershipShippedSpec` (and `HandoffSpec` where named), under
`cabal test all` from `core/`:

- `shipOwnedTransaction` over a context whose crossing cannot be made (a one-layer Incus context with a
  `HostConfig` that resolves no `incus`) returns the crossing-failure value, and an
  answer the near side cannot decode returns the undecodable-outcome value, each distinct from a frame
  refusal;
- `HandoffSpec`'s decode-refusal crossing decodes its answer with `decodeShippedOutcome` and asserts
  `ShippedRefused (OwnershipMalformed _)` rather than a non-empty body;
- `runShippedOwnership` with an authority beneath a regular file refuses at store open;
- hand-built wires refused as `OwnershipMalformed`: a field width of `0x00400001`, invalid UTF-8 in a text
  field, a conflict body with origin tag `2`, an identity of zero bytes and of 65 bytes, and an empty or
  relative authority, target, and symbolic-link target;
- take file A then file B under one key, and take a directory over a key holding a file record, each refused
  with the existing object left in place; a retry after the owned directory was removed out of band is
  refused rather than answered Taken;
- an unbound directory record planted through `compareAndSwapProtectedRecord` with the target absent lets the
  take complete, and with the target present refuses as `OwnershipConflict`, for `ShipTakeDirectory` and
  `ShipGiveBackObject`;
- a compile-fail fixture under `test/compile-fail/` registered in `CompileFailSpec` that passes a target path
  where the authority root is expected and is rejected;
- a path producer applied to a `FilePath` carrying a surrogate escape (a non-UTF-8 byte, for example
  `"/tmp/\xDC80"`) refuses it rather than encoding U+FFFD;
- `ProviderAliasSpec`'s "create, exact retry, and release" case asserts `assertRecordPresent frame False`
  after `ShippedObjectGivenBack`, then takes again and expects `ShippedSymbolicLinkCreated`;
- "an object already there is refused, and nothing is recorded" matches `ShippedRefused (OwnershipOccupied _)`
  (not `expectRefusal`, which admits any refusal), then removes the operator's file, runs `ShipTakeFile` again
  on the same frame, and asserts `ShippedObjectTaken`, so a record leaked by the refused take (which would
  answer the unbound-record refusal instead) fails the case;
- "a replaced object is refused, and left intact" and "a replacement symbolic link is refused on release and
  left intact" each match `ShippedRefused (OwnershipConflict ConflictReport{..})` with `conflictSubject` equal
  to the frame target (as text), and the directory case also asserts `conflictExpected == OriginPresent owned`,
  where `owned` is the identity the first take returned;
- "an absent object is reported absent, and nothing is created" checks the target with `doesPathExist` rather
  than `doesDirectoryExist`, and asserts the staging name
  `frameTarget frame <> ".hostbootstrap-shipped-" <> <record key>` is absent;
- "a file is published with its payload, and given back" asserts that same staging name is absent after the
  take and after the give-back, so a take that skips the staging unlink after `link(2)` fails;
- the case named "a directory is taken under all four clauses, and given back" is renamed "a directory is
  taken, bound to its identity, and given back", because it observes only the identity binding (clause 3) and
  the record (clause 2); clause 1's exclusion is `AuthoritySpec`'s entry probe and clause 4's parent sync the
  POSIX row's;
- the crossing child in `test/Spec.hs` routes through the production `interpretFrameTransaction`, and a source
  guard asserts `test/Spec.hs` names neither `interpretShippedOwnership` nor `interpretShippedClusterExposure`,
  so the routing the shipped binary performs is the routing both crossing cases run.

#### Remaining Work

- In `Ownership/Shipped.hs`, replace the `FilePath` fields of `ShippedOwnership` and the argument of
  `ShipTakeSymbolicLink`/`ShipGiveBackSymbolicLink` with three newtypes (authority root, target path,
  symbolic-link target) whose constructors are private and whose producers admit only a non-empty absolute
  POSIX path; export the record abstractly with a validating producer; validate the three in
  `decodeShippedOwnership`; update `Provider/Alias.hs`'s transaction producer. Add the transposition
  compile-fail fixture.
- Make `shipOwnedTransaction` return a closed failure sum that separates a crossing failure, an undecodable
  outcome, and a frame refusal (`OwnershipFault`), and update `Provider/Alias.hs`'s mapping so only a frame's
  own `OwnershipMalformed` is a `DoNotRetry` failure; correct the `shipOwnedTransaction` Haddock to the
  values it returns.
- In `takeObject`, refuse a stored record whose `originRecordKind` is not the act's kind (or whose file
  payload digest differs) and re-observe the target as the bound identity before answering
  `ShippedObjectTaken`; resolve an unbound record by observing the target — absent resumes the take,
  present refuses as `OwnershipConflict` with a recovery message — for both the take and `ShipGiveBackObject`.
- Make the three path producers refuse a `FilePath` that is not Unicode scalar text (GHC's surrogate escapes
  for non-UTF-8 bytes), since `encodeShippedOwnership` and the link-target claim encode paths as
  `encodeUtf8 (Text.pack path)`; rewrite the `encodeShippedOwnership` Haddock ("a target path and a payload
  are arbitrary bytes") to say paths travel as UTF-8 text and only the payload is arbitrary bytes.
- Rewrite the `shippedFieldCeiling` Haddock to describe the one 4 MiB ceiling `getSized` applies to every
  field, pathnames included, and that the encoder does not check it, so an over-ceiling payload is refused by
  the far side as `OwnershipMalformed`.
- Rewrite the module header ("because every frame this project reaches is Linux"), which contradicts the
  empty-context row, to the per-frame row the second deliverable states: the POSIX row in a Linux guest, and
  under an empty context the outer host's own row (Darwin's `renamex_np(RENAME_EXCL)`, Windows'
  `OwnershipUnsupported` for the symbolic-link acts); rewrite the `ShipObserveObject` Haddock ("mutate nothing") to say that observation records
  nothing but `runShippedOwnership`'s `openProtectedStore` creates the authority store's directories and
  identity file when they are absent.
- Delete `frameOwnsLocally` from `Substrate/Frame.hs` and its `OwnershipShippedSpec` cases (only that suite
  calls it), and rewrite the `frameOwnershipRow` Haddock to call the column a declaration no production
  module consults.
- Export `interpretFrameTransaction` from `HostBootstrap.CLI` (its definition beside `runCLI`), delete the
  verbatim copy in `test/Spec.hs`, and have the test child's `runFrameChildEntry (frameInterpreter ...)` call
  the exported one; add the `test/Spec.hs` source guard Validation states. Correct `OwnershipShippedSpec`'s
  module header, which calls the child "the production child body", if any part of the routing stays in
  the suite.
- In `OwnershipShippedSpec`, replace `expectRefusal` in the occupied, replaced-directory, and
  replacement-symbolic-link cases with the exact constructor matches Validation states, add the leaked-record
  rerun, the `doesPathExist` and staging-name assertions, and the rename; delete `expectRefusal` if no case
  still uses it.
- Add the cases listed in Validation.

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

### Sprint 15.27: The provider report [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Report.hs`,
`core/hostbootstrap-core/test/ProviderReportSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`

#### Objective

One total classification from a provider's own output to the observation a clause is held over.

#### Deliverables

- A closed vocabulary names what a provider reports about an instance: the one listing row that names it,
  the two lifecycle states a clause-holding transaction can act from, and one configuration value. The
  provider prints the same empty line for an unset key and for a key set to the empty string, so both are
  `ProviderConfigUnset` and a `ProviderConfigValue` carries non-empty text only.
- A closed sum names why a report is not a value: a command that produced no child, a provider that ran
  and refused, a success that wrote to standard error, and a report outside the shape this vocabulary
  admits. Each renders once.
- Classification is a total function of the interpreter's own outcome, so the report a driver returns and
  the decision a caller makes are the same value rather than a rendering and a parser.
- The instance listing is reduced to the row naming the exact instance before any row's state or arity is
  judged, because the provider matches a listing argument by prefix and a sibling row is not about this
  instance: a sibling in any state, or a malformed sibling row, is an absence rather than a refusal. The
  exact name listed twice is a refusal rather than a choice between two disagreeing answers.
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

Closure requires these `ProviderReportSpec` cases under `cabal test all` from `core/`: a listing of
`demo,RUNNING\ndemo-gpu,FROZEN` classified for `demo` answers the `demo` row; the same listing classified for
`demo-gpu` is refused as an unadmitted state; a listing whose only malformed row names a sibling answers the
exact row; a successful configuration read whose output is one empty line (`"\n"`) is
`ProviderConfigUnset`; a listing line of exactly `providerReportLineBound` characters and a value of exactly
`providerConfigValueBound` characters classify successfully beside the existing `bound + 1` refusals; the
`ProviderCommandExited` rendering for exit code 2 contains `2`; a configuration value carrying U+202E or
U+0085 is refused as `ProviderReportUnreadable`, and a non-zero exit whose diagnostic carries an escape
sequence renders with that character removed. The case "the seam's producer is the only admission", which
applies `mkObjectIdentity` rather than `classifyProviderIdentity`, is deleted; the preceding over-long
identity case is that property's evidence.

#### Remaining Work

- In `Provider/Report.hs`'s `classifyProviderListing`, split each row into its name field first, keep only
  the rows whose name equals the requested instance, and only then apply `runState` and the arity check, so
  a frozen, errored, or malformed sibling no longer refuses the exact instance's observation.
- Make `ProviderConfigValue` carry non-empty text only (an empty-line answer is `ProviderConfigUnset`, which
  is what `classifyProviderConfigValue` already returns), and rewrite the `unclaimedInstance` Haddock in
  `Provider/Resume.hs`, which says "carries nothing" and "carries the empty string" are different reports, to
  say the provider answers both the same way.
- Rewrite the `providerConfigValueBound` Haddock, which calls 240 "the same ceiling the identity grammar
  uses" (that ceiling is `identityByteCeiling`, 64 bytes), to say 240 bounds owner tags and device
  properties and that an identity is bounded again by `mkObjectIdentity`.
- In `reportLines`, refuse every `isControl` character and every `generalCategory` `Format` character (C1
  controls and bidi overrides as well as C0 and DEL), and strip the same characters from `firstLine`'s
  diagnostic before it reaches `ProviderCommandExited` or the noisy-success message.
- Add the cases listed in Validation.

### Sprint 15.28: The described provider commands [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
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

Every argument vector is compared by application over values, which is possible precisely because no
renderer can launch one. The guarded delete's three refusals are exercised through the table rather than
restated, and four shape assertions are total over every command the module renders: each names
`ToolTarget Incus`, each lands on the outer host, each carries the described stdio disposition, and none is
empty.

Dated 2026-08-19 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): `ProviderCommandSpec`
passed 18/18. Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 2,133/2,133 in 230.46
seconds; `poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

Closure requires the Haddock rewrite below, with `ProviderCommandSpec`'s existing stop and restart vectors
(`["stop", name, "--force"]`, `["restart", name, "--force"]`) still passing under `cabal test all` from
`core/`.

#### Remaining Work

- Rewrite the `stopInstanceCommand` and `restartInstanceCommand` Haddocks in `Provider/Command.hs`, and the
  `stopOwnedInstance` Haddock in `Provider/Ownership.hs`, which call the stop "not destructive", to state that
  `--force` kills the VM without a clean guest shutdown and can lose unflushed guest writes, and that the stop
  carries no name guard because it runs only inside a transaction that re-observed the exact owned instance.
- Rename `ProviderCommandSpec`'s "every command names the frame table's tool for this frame" case to say it
  names the Incus tool, since it compares against the literal `ToolTarget Incus`.

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

### Sprint 15.30: The provider resumption decisions [Active]

**Status**: Active
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

"Each renders once, naming both sides" is checked only by distinctness and non-emptiness, plus an
`isInfixOf` over the two claims of `InstanceUnderAnotherClaim` that does not say which claim is which; swapping
the record's and the instance's claim in the rendering, or dropping the observed identity from
`InstanceReplaced`, passes. Closure requires `ProviderResumeSpec`'s "every conflict names both sides" case to
assert each of the six `providerStandingConflictMessage` renderings in full with `@?=` (or, at least, that
each carried identity's `objectIdentityText` appears in its message and that each claim follows its own role
words, the instance's after "carries the claim" and the record's after "this record's"), passing under
`cabal test all` from `core/`.

#### Remaining Work

- Strengthen `ProviderResumeSpec`'s "every conflict names both sides and reads as itself" case as Validation
  states.

### Sprint 15.31: The backend takes the one interpreter [Active]

**Status**: Active
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

The guard does not yet hold the spawners: `Provider/Backend.hs` already imports `HostBootstrap.Effect.Run`,
which exports `runCaptured`, `runBoundedGrouped`, and `runBoundedGroupedWithInput`, and a direct call to any of
them would pass all three assertions; the identifier scan also walks `src/` and not `internal/`. Closure
requires `backendHasNoExecutionSeamCase` to assert that `Provider/Backend.hs`'s import of
`HostBootstrap.Effect.Run` names exactly `CapturedRun` and its fields, that `runCaptured`,
`runBoundedGrouped`, and `runBoundedGroupedWithInput` are named zero times in `Provider/Backend.hs` and
`Provider/Ownership.hs`, and that the retired-executor scan covers `core/hostbootstrap-core/internal/` as well
as `src/`, all passing under `cabal test all` from `core/`.

#### Remaining Work

- Extend `ProviderBackendSpec.backendHasNoExecutionSeamCase` with the import-list, spawner-identifier, and
  `internal/` assertions above.
- Enumerate the retired-executor scan's sources through `SourceGuard.listHaskellSources` over `src/` and
  `internal/`, and delete the private `listProductionSources` walker from `ProviderBackendSpec`.

### Sprint 15.32: The provision and readiness drivers [Active]

**Status**: Active
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

`FakeProvider` declares three behaviours, but the suite builds it only with `ProviderAnswers`, and its
recognized vectors succeed against an absent or wrong-state instance where real Incus refuses. Closure
requires these `ProviderBackendSpec` cases under `cabal test all` from `core/`:

- a fixture built with `ProviderDaemonUnavailable` refuses discovery and provision with the daemon refusal and
  records no provider mutation; one built with `ProviderEgressUnavailable` answers the provisioning-egress
  probe as unavailable;
- a provision over an instance the record binds under a different owner claim returns the standing conflict,
  not `ProviderProvisionAlreadyOwned`, and launches nothing;
- a guest probe that fails outright (a non-"not answering" exit) ends Ready after exactly one probe, and
  `readyObservationReplacementCase` asserts exactly one probe as well;
- `guestOutcome` applied to a `RefusedForeign` and to an `OwnershipConflict` from
  `replacedUnderGuestCommand` yields a marker that `providerConflictMarker` in `Substrate/Provider.hs` parses
  back to a `ProbeConflict` carrying both identities, and a token with a non-ASCII letter is refused by
  emitter and parser alike.

#### Remaining Work

- In `Provider/Ownership.hs`'s `provisionOwnedInstance`, answer `ProvisionAlreadyOwned` only when the
  `InstanceOwned` claim equals `ownedInstanceClaim owned`; otherwise return the `InstanceUnderAnotherClaim`
  standing conflict.
- In `Provider/Backend.hs`, render the marker's observed field as a space-free token (for example
  `identity=<id>` from `objectIdentityText`) rather than `foreignDetail`'s prose, render a conflict's two sides
  the same way, and replace `validWireToken`'s `isAlphaNum` with the ASCII predicate the parser's
  `validConflictToken` uses, exported once and used by both.
- In `test/FakeProvider.hs`, apply the daemon check to every vector, and refuse as Incus does: a mutating
  verb, `exec`, or a device read against an absent instance exits 1 with "Instance not found"; `launch` over
  an existing name, `start` on RUNNING, and `stop` on STOPPED refuse; `exec` refuses unless the instance is
  RUNNING. Make `retainedReverseCase` compare the whole recorded mutation list, so the stop-before-delete
  order is asserted.
- In `test/FakeProvider.hs`, mint each launched instance's identity from a counter kept in the fixture root
  (`instance-<name>-<n>`) rather than `"instance-" <> name`, so a delete-then-relaunch under one name yields a
  new identity; make `withFakeProviderClient` restore the variable's previous value rather than unset it;
  delete the unused `["list", name, ..., "-c", "s"]` row and `recordedGuestInvocations` export, and the
  `"alias:"` role routing in `Spec.hs` with `ProviderAliasSpec.aliasGuest`; and rewrite the module header to
  name only the vectors it serves (it does not serve the lift's `exec <vm> --cwd / -T --` leaf).
- In `ProviderBackendSpec.concurrentProvisionCase`, wrap each forked `provisionCall` in `try` and put the
  `Either` into the `MVar`, so a thrown failure surfaces with its message rather than as
  `BlockedIndefinitelyOnMVar`, and state in its comment that the store's exclusive entry serializes the two
  calls, so the case proves convergence of two entries and `AuthoritySpec` holds the exclusion itself.
- In `Provider/Ownership.hs`, move the clause-2 publication Haddock now attached to `interpret =
  interpretHostCommand` to `withRecordedClaim`, which calls `publishFreshRecord`, and delete the orphaned
  "Forget one durable record, whatever version the store currently holds" comment, which documents no
  definition.
- Add the cases listed in Validation.

### Sprint 15.33: The share, stop, and delete drivers [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

The remaining provider operations on the same face.

#### Deliverables

- A share is an owned object of its own: its device name is derived from a digest of the share binding's
  UTF-8 bytes, its origin is recorded before the device is attached, and its identity is bound from the
  device the provider reports.
- The share's instance is observed on **both** sides of the device readback, exactly as a guest crossing
  observes it on both sides of the command it runs. A device readback answers for the device and for
  nothing about whose instance now carries it, so the standing re-taken before the binding is what refuses
  an instance replaced inside the attachment.
- Stop and delete re-enter from the durable record, re-observe through the report, act through the one
  interpreter, and forget the record only over a reported absence.
- Delete leaves a same-named replacement untouched, because clause 4 compares the identity rather than the
  name: the instance is observed afresh immediately before the guarded delete, after the share
  bookkeeping, and that fresh observation is what clause 4 compares.
- A delete interrupted after the instance is gone resumes: a bound record whose instance the provider no
  longer lists is, for the forward and the retained delete alike, a removal whose bookkeeping did not finish,
  so its share records and then its instance record are forgotten under a clause-4 token over the observed
  absence.
- A share record is releasable with its instance only when its device is exactly the identity the record
  bound or is already absent (the instance's removal takes every device with it); a device replaced under
  the same name is a conflict that leaves the device, the record, and the instance alone.
- A record whose instance carries this record's claim but was never bound (a run that died between launch
  and bind) is released by binding the observed identity first, so teardown needs no re-provision.

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
- A share whose *instance* was taken between the attachment and the binding bound anyway, because the
  readback that followed the attachment asked about the device. The device is still there and still
  answers for the three properties the declaration names; the instance around it is somebody else's.
  The standing is now re-taken after the readback, and `shareObservationReplacementCase` reaches that
  window the only way it can be reached — the provider client itself puts a different instance at the
  name after the `device-add` it accepted, because the transaction holds the store's exclusive entry
  throughout and nothing outside it can act inside that window (§ NN).

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,229/2,229 in 305.82 seconds, including
`shareObservationReplacementCase`.

Closure requires these `ProviderBackendSpec` cases through the `FakeProvider` client, under `cabal test all`
from `core/`:

- a delete whose provider client removes the instance and then exits non-zero, followed by a second forward
  delete, settles removed with the instance record and every share record gone; the same for
  `runRetainedProviderDelete`; and a provision under the same key afterwards launches normally;
- a provider client that replaces the instance after the share bookkeeping and before `delete` leaves the
  replacement standing and returns the replacement conflict, with the fake recording no `delete`;
- a share device repointed to another source before the instance delete returns the share conflict, deletes
  nothing, and forgets no record;
- a share device removed out of band before the instance delete lets the delete complete and forgets the
  share record with the instance record;
- a provision whose client launches and dies before the bind, followed by a forward delete and by a retained
  delete, removes the instance carrying this record's claim and forgets its record rather than refusing with
  "does not yet bind an instance this run owns";
- `deleteReplacementLeftStandingCase` runs over a post-delete replacement that carries the deleted
  instance's owner claim, so only the identity differs and the case fails if clause 4 compares the claim;
- two share bindings that differ only in one non-Latin-1 character (U+0151 against `Q`) name different
  devices.

#### Remaining Work

- In `Provider/Ownership.hs`'s `deleteOwnedInstance` and `deleteRetainedOwnedInstance`, accept the
  `InstanceVanished` standing as an unfinished removal: re-mint the clause tokens from the record and forget
  the share records and then the instance record under a clause-4 token over `OriginAbsent`, answering
  `DeleteRemoved`.
- In `removeInstance`, call `observeInstance` after `releasableShares` and immediately before the guarded
  delete, and pass that fresh origin to `reobserveReportedIdentity` in place of the identity just bound.
- In `observeShareRecord`, compare the observed device identity with the bound one and return
  `shareConflict bound (OriginPresent observed)` on a mismatch; treat an absent device as releasable; and
  forget share records through `releaseReportedObject` with a releasable token rather than a raw
  `forgetRecord`, or correct the Haddock that calls them made releasable.
- In `deleteOwnedInstance` and `deleteRetainedOwnedInstance`, treat the `InstanceCreated` standing (the
  instance carries this record's claim but was never bound) by binding the observed identity with the step
  provision uses for `ProvisionRecovered` and then continuing into the clause-4 release, instead of
  `notYetOwned`.
- Correct the `DeleteAlreadyRemoved` Haddock ("no record to forget"): `forgetUnboundRecord` returns it after
  forgetting an unbound clause-2 record, so it reads "no instance to remove; an unbound record may have been
  forgotten", or give that path its own outcome constructor.
- In `Provider/Backend.hs`'s `shareDeviceName`, hash `TextEncoding.encodeUtf8 (preparedShareBinding prepared)`
  rather than `ByteString.pack (Text.unpack ...)`, which keeps only each character's low byte and makes the
  Haddock's "a different binding never addresses it" false.
- In `test/FakeProvider.hs`'s `replaceIfArmed`, give a replacement placed after `delete` (the `Nothing` branch)
  the deleted instance's owner claim, read before the delete or passed to `armReplacementAfter`, so it
  differs from the deleted instance only by identity.
- Add the cases listed in Validation.

### Sprint 15.34: Direct canonical-root admission [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
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

Two Direct guarantees have no case: only the matching-root share is exercised, and the recording `docker`
tool logs only its own name, so "validates the exact egress image" never observes which image was probed.
Closure requires, under `cabal test all` from `core/`: a `ProviderReconcileSpec` case on `withDirectBackend`
declaring a share whose source is a sibling of the admitted root and asserting settlement yields
`Left (Conflict d)` with `conflictResource d == "direct-host-share"`; and `directReadyValidationCase` with a
recording tool that appends its full argument vector, asserting the log equals
`["docker manifest inspect images:ubuntu/24.04"]` (the spec's image). `directRootAdmissionCase`'s `refuses`
also takes the expected reason fragment and asserts the `Left` text contains it, so each of the five facts
is shown to report its own reason; the case that runs Ready against `root </> "absent"` is named and
worded as the absent-root refusal it is, with the accessibility clause covered by application only; the
canonical fact applied to a canonicalization that could not be taken answers false; and `ProviderReconcileSpec`'s
`withRealHostTools` `docker` stand-in exits 0 only for `manifest inspect alpine:3.22` and non-zero otherwise.

#### Remaining Work

- Add the sibling-root Direct share refusal case to `ProviderReconcileSpec`.
- Make `ProviderBackendSpec`'s recording `docker` fixture append its argument vector, and assert the exact
  `manifest inspect <image>` vector in the Direct Ready cases.
- In `Provider/Backend.hs`'s `observeDirectRoot`, observe canonicalization as a `Maybe` (`Nothing` when
  `canonicalizePath` throws) and set `directRootCanonical` false for `Nothing`, instead of falling back to
  `root` and comparing it with itself; write the fact as a pure function of the root and that `Maybe`, and
  add a case applying it to `Nothing` that answers false.
- Give `directRootAdmissionCase`'s `refuses` the expected reason fragment, rename the `root </> "absent"`
  Ready case and its failure message to the absent-root refusal, and make `ProviderReconcileSpec`'s `docker`
  stand-in refuse any argument vector other than `manifest inspect alpine:3.22`.

### Sprint 15.35: The provider's interpreter program is gone [Active]

**Status**: Active
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

The provider ownership program, the Direct permission program, the `flock` front end and its discovery,
the exclusion-tool vocabulary, and the wire report grammar that program answered in are absent from the
tree, together with the `Python3` and `Flock` entries the provider backend resolved them through.
`mkIncusBackendSpec` resolves `Incus` alone, and the closed `HostTool` set narrows in
[phase 16](phase-16-cluster-lifecycle-and-cordoning.md), where the last driver stops driving an
interpreter.

Two programs in strings remain and no guard holds the absence. `Provider/Backend.hs`'s
`observeGuestVmShare` runs `["bash", "-lc", "test -d \"$1\" && test -w \"$1\"", "--", target]` and
`runBoundLima` answers `ProviderProvisioningEgressProbe` with
`["bash", "-lc", "getent hosts archive.ubuntu.com >/dev/null"]`, both through `runGuestVm`. The only guard of
this shape is `ClusterBackendSpec.sourceCases`, which reads `Cluster/Backend.hs`; `ProviderBackendSpec`'s
`backendHasNoExecutionSeamCase` forbids no interpreter token and cites no rationale entry. Closure requires a
`ProviderBackendSpec` source-guard group over `Substrate/Provider/Backend.hs` and
`Substrate/Provider/Ownership.hs` that fails on any of `"bash"`, `"sh"`, `"-c"`, `"-lc"`, `Python3`, `Flock`,
and `Lockf`, asserts that both modules still reach `interpretHostCommand` and the described commands of
`Provider/Command.hs`, and cites the rationale entry in its Haddock, passing under `cabal test all` from
`core/` with the two probes rewritten.

The opt-in live client follows the boundary it exercises. It audits the Direct realization by taking the
same observation the admission takes and applying the same decision, rather than resolving a program and
comparing its text, and it reads back the protected store's own record rather than the retired sidecar
layout. It publishes its durable intent through the ownership row, the binary's own typed operation over
one platform row (§ EE, § LL), rather than through POSIX system calls, so the component depends on no
POSIX-only package and **every gate host compiles it**, which is what type-checks the client against the
boundary it drives (its backend construction carries the guard prefix § LL requires). The
`hostbootstrap-provider-live-linux-cpu` stanza carries no flag and no `buildable` condition: the component is
always compiled, and its runtime platform check and confirmation guard decide whether the live subject runs,
as Sprint 2.4 requires.

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

- Replace the guest-VM share reprobe in `observeGuestVmShare` with argv-only guest commands (`test -d <target>`
  and `test -w <target>`, each its own `runGuestVm` call) and the provisioning egress probe in `runBoundLima`
  with an argv-only command (`getent hosts archive.ubuntu.com`), sent through `runGuestVm` with no shell.
- Add the `ProviderBackendSpec` source-guard group described in Validation, modelled on
  `ClusterBackendSpec.sourceCases`, over `Provider/Backend.hs` and `Provider/Ownership.hs`.

### Sprint 15.36: The inherited durability statement [Active]

**Status**: Active
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

The guard is an assertion over the sources themselves, so it fires on a reintroduced write rather than on
a fixture's cooperation. Over `Ownership.hs` and `Backend.hs` it names the mutating set exactly — the writers, the renamers, the unlinkers, the
directory creators, and the handle openers and flushers — and leaves the read-only observations the Direct
admission takes unguarded, because a `getPermissions` changes nothing on disk.

The positive half matters as much as the negative one: a guard that only forbade writes would stay quiet
over a driver that had stopped publishing anything at all. It asserts it in two hops: `Ownership.hs` names
`publishFreshRecord`, `publishBoundRecord`, and `forgetRecord` and names neither compare primitive, and the
record tape `Ownership/Tape.hs` names both.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,229/2,229 in 305.82 seconds.

`ProviderSpec`'s "the provider driver publishes every durable byte through the protected store" reads only
`Ownership.hs` and `Backend.hs` against a closed list of eighteen call names, and its positive half counts a
name's mere mention, an import list included; a `writeFile` added to `Provider/Reconcile.hs` or `Alias.hs`,
or a write through an unlisted handle helper, passes. Closure requires that case to enumerate
`Substrate/Provider.hs` and the `Substrate/Provider/` tree with `SourceGuard.readHaskellSources`, to fail on
any import of a mutating `System.Directory` or `System.IO` name (by `SourceGuard.moduleImportTokens`, with
the read-only `getPermissions`, `doesDirectoryExist`, `pathIsSymbolicLink`, and `canonicalizePath` the
Direct admission takes admitted by name), and to require that each publication is applied rather than only
imported (`countHaskellIdentifier` exceeds its import-list count), passing under `cabal test all` from
`core/`.

#### Remaining Work

- Extend `ProviderSpec`'s durability guard to the whole provider module tree, the import-based mutating-name
  check, and the applied-not-merely-named positive half, as Validation states.

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

### Sprint 15.38: One guest-VM backend row [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

§ LL says the substrate axis is a lift, not a fork: adding a provider adds a row, not a branch. Two of
the backend constructors are the same function written twice — identical guard sequence, identical
shape, identical failure construction — differing in a host guard, a provider kind, a tool, and four
labels. They are so nearly the same that both already construct the same backend specification value,
which is the two substrates agreeing in code that they are one realization while the module spells them
apart.

#### Deliverables

- A guest-VM backend constructor takes the host guard, provider kind, tool and label as parameters.
- The Lima and WSL2 constructors become applications of it.
- The invalid-input and tool-requirement helpers that all four backend constructors redefine are hoisted to one definition parameterised by label.
- Adding a guest-VM provider is a new application, not a new copy, and every function that routes on the
  guest-VM provider kind matches each kind explicitly, so a new kind is a compile error at each route rather
  than a silent Lima route.

#### Validation

`mkGuestVmBackendSpec` holds the guard sequence, and `limaRealization` and `wsl2Realization` are values
naming the five things that actually differ: the host guard, the host the refusal asks for, the closed
provider kind, what the realization calls the thing it names, and the tool with its own spelling.
`mkLimaBackendSpec` and `mkWsl2BackendSpec` are one-line applications. `invalidBackend` and
`requireBackendTool` are hoisted, so all four constructors — Incus and Direct included — refuse through
one pair.

Every refusal string is byte-for-byte what it was, including WSL2's "distro name" against Lima's
"instance name" and WSL2's tool spelled `WSL` where its constructor is `Wsl`. That is what makes the
provider backend suite evidence: its 31 pre-existing cases pass unchanged, plus the two source guards below
(33 in all), and the ones pinning each constructor's substrate guard, provider-kind guard, share guard and
unresolved-tool refusal pin the shared row.

**The module is 34 lines longer, not shorter.** The duplicated function is gone, but the record that
replaced it carries a documented field per axis of difference. That is the trade this sprint accepts:
the cost of a third guest-VM provider drops from a copied function to one value, and the line count is
not the thing § LL asks about.

Two new source guards keep it that way. One asserts `mkGuestVmBackendSpec` is named four times — its
signature, its definition, and one application per realization — and each realization value three times.
The other asserts the refusal helpers are named five times each, once per remaining constructor body.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `cabal test all` from
`core/` passed with the provider backend suite at 33/33; the header's 2026-09-14 **Gate evidence** row
re-ran the phase gate over this tree.

`providerBoundRouteFor` matches `ProviderLima` and `ProviderWsl2` and sends every other kind to
`ProviderBoundLimaRoute` through a wildcard, so a third guest-VM kind would route through `limactl`
without a compile error. And `ProviderBackendSpec`'s `wslSpec /= limaSpec` holds through the two specs'
different executables alone, because the realization fingerprint includes the executable path, so dropping
the provider kind from both fingerprints passes. Closure requires the route rewrite below and that
assertion rebuilt over two host configurations that resolve the same executable path, so only the
realization kind differs, passing under `cabal test all` from `core/`.

#### Remaining Work

- In `Provider/Backend.hs`'s `providerBoundRouteFor`, replace the `_ -> ProviderBoundLimaRoute` wildcard with
  explicit `ProviderIncus` and `ProviderDirectHost` alternatives that cannot produce a guest-VM route (or make
  `LimaBackendSpec` carry a closed guest-VM kind so the match has only the two cases).
- Rebuild `ProviderBackendSpec`'s WSL2-versus-Lima identity inequality over host configurations that resolve
  one executable path for both tools.

### Sprint 15.39: One runtime-dependency coordinate opener [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`
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
package` suite passed 10/10 under `cabal test all` from `core/`; the header's 2026-09-14 **Gate evidence**
row re-ran the phase gate over this tree.

#### Remaining Work

None.

### Sprint 15.40: The retained provider opens as well as closes [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`
**Production modules**: `HostBootstrap.Substrate.Provider.Backend` (1; cap 3)
**Sprint budget**: one retained operation beside the two that exist, no new type; at most 35 production
Haskell lines.
**Substrates**: linux-cpu

#### Objective

The retained-record boundary had two operations — stop and delete — and no way to open a provider it had
closed. That is only half a reverse: a `down` stops the provider and leaves its children retained inside
it, and the `destroy` that follows has to reach those children through a frame that is no longer running.
The worked demo's live gate found the gap exactly there, with `Error: Instance is not running` and every
in-guest node reported unsettled.

#### Deliverables

- One retained operation that re-observes the record, starts the instance when it is stopped, and asks the
  guest itself whether it answers.
- It derives claim and identity from the durable record alone and refuses a replacement, exactly as its two
  peers do; no caller-supplied generation or owner is accepted.
- An instance that is running but not yet answering is polled rather than assumed ready.
- Direct and Lima answer the declared `Unsupported` refusals their peers already answer.

#### Validation

The new operation's own effect on a real guest is observable one level up, in the
[worked demo](phase-24-worked-demo.md)'s live `project destroy`, which opens the retained provider before
unwinding the children inside it.

On 2026-09-14 the host static gate passed 2,546/2,546 in 200.71 seconds and the live component reported
`PASS — prepared Incus lifecycle/share/alias/restart/delete and mutation-free Direct refusal`, both on the
host the header's **Gate evidence** row names. Neither leg calls the retained operations beyond the happy-path
`runRetainedProviderDelete`: no case calls `runRetainedProviderReady` or `runRetainedProviderStop`, the
provider-live runner calls no `runRetainedProvider*` function, and `retainedProviderFault` is never produced.

Closure requires these `ProviderBackendSpec` cases on the `FakeProvider` host, under `cabal test all` from
`core/`:

- a retained stop of a running provisioned provider records exactly one `stop` and settles stopped, then a
  retained ready records exactly one `start` and settles running;
- a retained ready over a guest that answers "not answering" twice and then answers polls three times and
  settles running, and one over a guest that fails outright returns the failure after one probe;
- an instance replaced under the same name between provision and each of retained stop, ready, and delete
  returns `Left (Conflict ...)` from `retainedProviderFault`, leaves the replacement standing, and records no
  mutation against it;
- a retained stop over an instance that does not stop maps `StopStillRunning` to a failure, not a success;
- for a Direct backend and a Lima backend, all three retained operations return `Left (Unsupported ...)`.

#### Remaining Work

- Add the retained stop, ready, replacement, still-running, and `Unsupported` cases above to
  `ProviderBackendSpec`.

### Sprint 15.41: The shipped symbolic-link row settles every crash window [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`, `core/hostbootstrap-core/test/OwnershipShippedSpec.hs`
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

Kernel-backed cases (same platform condition as `ProviderAliasSpec`'s shipped-ownership cases) under
`cabal test all` from `core/`:

- `ProviderAliasSpec` and `OwnershipShippedSpec`: with no record, an exact-looking link and separately a
  regular file at the alias each answer `ShippedRefused (OwnershipOccupied _)` to `ShipGiveBackSymbolicLink`
  and survive.
- `ProviderAliasSpec`: unbound record (via `publishUnboundRecord`), with and without a staging link, then
  `releaseTransaction`: assert the exact outcome and the resulting record and stage state.
- Bound record with the stage present and alias absent, and (Linux) bound record with stage and alias both
  linking the published inode, then give-back: `ShippedObjectGivenBack` and no stage remains.
- After a take, remove the alias and recreate it with the same link target (new inode): a take retry and a
  give-back each answer `ShippedRefused (OwnershipConflict r)` with expected `OriginPresent <bound>` and
  observed `OriginPresent <new>`, and the link survives.
- Take target A, then take and give back naming target B under the same authority and key:
  `ShippedRefused (OwnershipMalformed _)`, A's link and record survive; a planted
  `originRecord (ReportedObject claim) (OriginPresent x)` is refused the same way.
- Unbound record plus an exact link at the staging path: take answers Retained and the stage is removed;
  unbound record plus a regular file at the staging path: Occupied and the file kept; bound record plus a
  replaced stage: Conflict.
- The 'resumes that exact inode' case returns the staged identity from `publishBoundStaging` and asserts
  `resumed @?= ShippedSymbolicLinkRetained staged`, that the alias is a symlink to `frameLinkTarget` whose
  (device, inode) equals the staged identity; the 'resume after origin publication' case asserts the alias
  exists and points at the target, the record is now bound to the returned identity, the stage is absent, and
  a following release answers `ShippedObjectGivenBack`.

#### Remaining Work

- In `Ownership/Shipped.hs`'s `releaseSymbolicLink`, call `cleanupSymbolicLinkStage` for the bound identity
  before forgetting the record on the `SymbolicLinkAbsent` and `SymbolicLinkExact` branches; correct the
  Haddock near `cleanupSymbolicLinkStage` to state the recovery path.
- Pass the expected identity and link target into `removeExactSymbolicLink`, re-run `observeSymbolicLink`
  immediately before `removeLink`, unlink only on `SymbolicLinkExact current | current == identity`, otherwise
  return `symbolicLinkIdentityConflict`.
- Replace the `Right Nothing -> OwnershipMalformed "the symbolic-link record has no identity binding"` give-back
  arm with the unbound-record policy in Deliverables.
- Add the cases listed in Validation.

### Sprint 15.42: The guest-VM backend row is exercised and adopts only what it owns [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`

#### Objective

The Lima and WSL2 realization (`StrongLimaBackend`) is driven in the static gate against fake `limactl` and
`wsl` clients, classifies its outcomes through the same total classifier the Incus driver uses, never
adopts a same-named VM it cannot prove it created, and starts its own stopped Lima instance on the forward
route.

#### Deliverables

- `runLimaProvision` answers `ProviderProvisionAlreadyOwned` only for a VM carrying this project's ownership
  marker (written at creation, or a protected-store record keyed by the VM name); a same-named VM without it is
  `ProviderProvisionForeign` (or `Conflict`), as the Incus row refuses an instance under no record.
- `runGuestVm`, `observeLimaExists`, `observeGuestVmShare` and `runBoundLima` reach their decisions through
  `classifyProviderReport` (or a `Provider/Report.hs` classifier for membership), so a noisy success and a
  control character are refused on the guest-VM row as on the Incus row, and `firstDiagnosticLine` is deleted.
- The WSL2 existence probe reads a host with no installed distributions as an empty member list:
  `wsl --list --quiet` exits non-zero there with "has no installed distributions", which
  `Ensure.Wsl2.wslReportsNoInstalledDistributions` already recognises, so the first provision on a fresh
  Windows host is not refused.
- The guest-VM fingerprint covers the host root of the retained writable share as well as the guest path and
  envelope.
- The forward Lima readiness starts a listed instance whose reported status is Stopped through the row's
  `spStartExisting` (`limactl start <name>`) before it polls `limactl shell <name> true`, so `project down`
  followed by `project up` restarts the same instance rather than polling a stopped one to `NotReady`.

#### Validation

Fake `limactl` and `wsl` host tools written with `Fixture.newFakeTool` (or a `FakeProvider`-style client),
with cases under `cabal test all` from `core/`: provisioning a fresh VM settles Created; a pre-existing
same-named VM without the marker is refused as foreign and launches nothing; one with the marker settles
AlreadyOwned; a failed launch is a failure; a readiness timeout returns NotReady after the bounded poll; a
share whose declared source or target differs from the retained share is `ProviderShareConflict`; a guest
command that exits 0 with stderr output is refused as noisy; a `wsl --list --quiet` that exits non-zero with
the no-installed-distributions text observes the VM as absent, while any other non-zero exit is a failure;
`runBoundLima` refuses a different host tool and a Direct probe; the forward stop and delete return
`Unsupported`; a forward ready over an owned Lima instance the fake reports Stopped records exactly one
`start` and then settles Running, and one over a Running instance records no `start`.
`ProviderBackendSpec`'s Lima fingerprint case adds a spec built with
`limaShare{hpsHostPath = hostFixturePath "/other-share"}` and asserts it differs from the baseline.

#### Remaining Work

- Add the ownership marker check to `runLimaProvision` and the foreign refusal.
- Route the guest-VM row's outcomes through the report classifier and delete `firstDiagnosticLine`.
- In `observeLimaExists`, map a non-zero exit that `wslReportsNoInstalledDistributions` recognises to an empty
  member list for the WSL2 row.
- In `Provider/Backend.hs`'s forward Lima readiness (`pollLimaReady`), observe the listed instance's status
  and run the row's `spStartExisting` effects for a Stopped instance before the poll.
- Add the fake `limactl`/`wsl` fixtures and the cases listed in Validation, plus the changed-host-root
  fingerprint case and the stopped-instance start case.

### Sprint 15.43: A carried provider handle's phase comes from fresh evidence [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
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

#### Remaining Work

- In `Reconcile.hs`, change the continuation type of `withPlannedReboundManagedResourceEvidence` so the
  rebound handle's phase is the old handle's `oldPhase`, and add the package-private fresh-generation
  producer of the `Running` and `Provisioned` handles.
- In `Provider/Reconcile.hs`, route the three call sites (the carried provider dependency, the carried
  provider-share dependency, and `withFreshRunningProviderHandle`) through that producer after
  `invokePackageProbe`, deleting the inline generation comparisons it replaces.
- Add the compile-fail fixture and the generation-mismatch case listed in Validation.

### Sprint 15.44: The fake host tools render one answer on every host [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/Fixture.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

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

#### Remaining Work

- In `test/Fixture.hs`, hoist `escapeCmdEcho` to the top level and apply it, with `echo(`, in the Windows
  `fakeToolProgram` and `exhaustingToolProgram`; replace the POSIX `show` quoting in all the generators with
  a single-quote quoter.
- Delete `newRefusingFakeTool` and `refusingToolProgram` and their export.
- Rewrite the three fake-tool Haddocks as Deliverables states.
- Add the round-trip cases and the source guard listed in Validation.

### Sprint 15.45: An existing provider instance is held to the declared sizing [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/lima.md`,
`documents/engineering/wsl2.md`

#### Objective

A provision that finds its own instance already standing answers for the sizing the plan declares now
(§ O's "applied everywhere or typed refusal"). Today a new Lima, Incus, or WSL2 resource is sized from the
budget when it is created, while an existing Lima or Incus VM is started with the sizing it was created
with and an existing WSL2 distro keeps the VHDX size it was installed with: a changed declaration is
neither compared, applied, nor refused. This sprint makes it compared, and refused when it differs.

#### Deliverables

- Incus: on the owned-instance path of `provisionOwnedInstance` in `Provider/Ownership.hs`, the instance's
  `limits.cpu`, `limits.memory`, and root-device `size` are read through `Provider/Command.hs`'s
  configuration and device reads and classified through `Provider/Report.hs`; equal to the declaration is
  `ProvisionAlreadyOwned`, different is a `Conflict` naming the declared and observed quantities, with
  destroy-and-reprovision as the remedy.
- Lima: the owned-instance path of `runLimaProvision` in `Provider/Backend.hs` reads the instance's CPUs,
  memory, and disk from the provider's own listing and refuses a different declaration the same way.
- WSL2: the VHDX size a distro is installed with is recorded with the ownership marker Sprint 15.42 adds,
  because `wsl.exe` reports no VHDX size; a later provision whose storage declaration differs is refused the
  same way.
- The three rows refuse through one `Conflict` shape naming the three declared and observed quantities.

#### Validation

Closure requires these `ProviderBackendSpec` cases under `cabal test all` from `core/`: on the
`FakeProvider` host, a provision over an owned Incus instance whose reported limits equal the declaration
settles `ProviderProvisionAlreadyOwned` and records no launch, and one whose reported `limits.memory`
differs returns `Left (Conflict ...)` naming both quantities and records no mutation; on the fake `limactl`
and `wsl` clients of Sprint 15.42, the same equal and changed pair for the Lima row and for the WSL2
storage declaration.

#### Remaining Work

- In `Provider/Ownership.hs`'s `provisionOwnedInstance`, read and compare the three Incus quantities on the
  `InstanceOwned` path before answering `ProvisionAlreadyOwned`.
- In `Provider/Backend.hs`'s `runLimaProvision`, compare the Lima listing's sizing on the existing-instance
  path, and record and compare the WSL2 VHDX size beside the ownership marker.
- Add the equal and changed cases listed in Validation for all three rows.

### Sprint 15.46: One Incus argument vocabulary [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/test/IncusSpec.hs`, `core/hostbootstrap-core/test/ProviderSpec.hs`
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

#### Remaining Work

- In `Substrate/Provider.hs`, rewrite the Incus row onto the `Provider/Command.hs` commands and make its
  launch answer the prepared-route refusal.
- Delete `createVMArgs`, `startVMArgs`, `stopVMArgs`, `deviceListArgs`, `addDiskDeviceArgs`, and
  `destroyVMArgs` from `HostBootstrap.Incus` with their exports and `IncusSpec` cases, and move
  `ProviderSpec`'s guarded-delete Incus row to `deleteInstanceCommand`.
- Add the row cases and the source guard listed in Validation.

### Sprint 15.47: One crossing renderer is held by a repository-wide guard [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

§ LL admits one rendering of "cross into this frame": the lift's fold, `foldLeaf` in `HostBootstrap.Lift`,
and the per-provider crossing primitives it composes in `HostBootstrap.Lift.Context` (`execVMArgs`,
`shellVMArgs`, `wslExecArgs`). This phase owns the frame table and the rule; no guard holds it across the
repository today, and only `RegistrySpec` checks that one module derives its crossing from `foldLeaf`.

#### Deliverables

- A `ProviderSpec` source guard over every module under `core/hostbootstrap-core/src/` and
  `core/hostbootstrap-core/internal/` asserts that the set of modules naming `execVMArgs`, `shellVMArgs`,
  or `wslExecArgs` is exactly `Lift/Context.hs` (their definition), `Lift.hs` (the fold), the three
  realization re-exports `Incus.hs`, `Lima.hs`, and `Wsl2.hs`, and the two provider consumers
  `Substrate/Provider.hs` (the readiness probe rows) and `Substrate/Provider/Backend.hs` (`runGuestVm`).
- The same guard asserts that no module outside `Lift.hs` and `Lift/Context.hs` carries an `"exec"` or a
  `"shell"` string literal, the leading elements of the Incus and Lima crossing vectors.
- The guard's Haddock cites § LL and the rationale entry whose absence guard is "one crossing renderer".

#### Validation

Closure requires the guard to exist and pass under `cabal test all` from `core/`, plus a case applying the
guard's pure predicate to a constructed module list in which a further module names `shellVMArgs`, and to
one in which a further module carries an `"exec"` literal, each refused.

#### Remaining Work

- Add the crossing-renderer source guard and its pure predicate to `ProviderSpec`, with the
  negative application case listed in Validation.

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
lifecycle/share/alias/restart/delete and mutation-free Direct refusal`. This is the run the header's
**Gate evidence** row records.

## Remaining Work

- Sprint 15.2: WSL2 delete shutdown, source-derived Incus share device, locale-independent WSL2 running probe, deletion of the unused alias state machine, and the reboot (WSL2 and Lima rows) and share listing cases.
- Sprint 15.6: retained-prefix discovery, collapsed permission slot, exported probe classifier, behavioural discovery cases, and the reflexive discovery case deleted.
- Sprint 15.7: delete the unused provider guest executor and add capability accessor cases.
- Sprint 15.8: ASCII hostname and quantity grammars, UTF-8 socket bound, retained-executable fingerprint, and a refusal case per admission guard.
- Sprint 15.10: settlement-output assertions for the foreign, wrapper-origin, and Direct-owner provision cases.
- Sprint 15.11: source-phase-indexed advance, an identity-bearing running reprobe, and consumed nonces that survive re-registration.
- Sprint 15.12: undeclared-provider refusal, production-sourced share probe refusals, and Haddock corrections.
- Sprint 15.13: the replacement-stop case asserts the replacement and the stop it names.
- Sprint 15.15: `withProviderBoundExec` happy path and the three origin-mismatch `Conflict` cases.
- Sprint 15.16: ancestor and authority-directory alias refusals, reason-matching descriptor cases, and `withPreparedGuestAliasCall` cases.
- Sprint 15.17: `discoverStrongAliasBackend` cases and the `runPreparedGuestAliasCall` Haddock.
- Sprint 15.19: delete the unused alias owner binding, correct its Haddocks, and add the settlement cases.
- Sprint 15.20: release fence and replacement cases.
- Sprint 15.21: `reconcileNodeGuestAlias` cases through the chain interpreter, its Haddock, and the vacuous generation guard deleted.
- Sprint 15.22: provider-live cleanup under the exception boundary, exact residue and owned-state checks, and pre-intent failure handling.
- Sprint 15.24: the `guardedDeleteArgs` Haddock states the convention the types do not enforce.
- Sprint 15.25: typed path roles, a closed crossing-failure sum, exact take retries, unbound-record resolution, Haddock corrections, `frameOwnsLocally` deleted, the production frame-transaction routing shared with the test child, and exact refusal, leaked-record, and staging-name assertions.
- Sprint 15.27: exact-name listing reduction, non-empty configuration values, control and format character refusal, and bound cases.
- Sprint 15.28: `--force` Haddocks and the Incus-tool case name.
- Sprint 15.30: full assertions of the six conflict renderings.
- Sprint 15.31: the execution-seam guard covers spawners, the `Effect.Run` import list, and `internal/`, read
  through `SourceGuard`.
- Sprint 15.32: own-claim AlreadyOwned, the shared conflict-marker token grammar, a realistic `FakeProvider`, and single-probe failures.
- Sprint 15.33: resumable vanished-instance delete, fresh pre-delete observation, share identity comparison, unbound-claim release, and UTF-8 device digest.
- Sprint 15.34: sibling-root share refusal, exact egress image assertion, and fail-closed canonicalization.
- Sprint 15.35: argv-only guest-VM probes and the `ProviderBackendSpec` interpreter-token source guard.
- Sprint 15.36: the durability guard covers the whole provider module tree.
- Sprint 15.38: explicit guest-VM routing and a kind-only fingerprint inequality.
- Sprint 15.40: retained stop, ready, replacement, still-running, and `Unsupported` cases.
- Sprint 15.41: shipped symbolic-link give-back cleans its stage, re-observes before unlink, and resolves unbound records.
- Sprint 15.42: guest-VM row ownership marker, report classification, no-distro WSL2 probe, forward start of a stopped Lima instance, and fake-client cases.
- Sprint 15.43: a rebound carried handle keeps its phase, and the Running and Provisioned indices come from the fresh package probe.
- Sprint 15.44: fake host tools escape their text on both hosts, the unused refusing tool is deleted, and their Haddocks call them stand-ins.
- Sprint 15.45: an existing Incus or Lima instance and an existing WSL2 VHDX are compared with the declared sizing and a changed declaration is refused.
- Sprint 15.46: the Incus row renders through `Provider/Command.hs` and the six duplicate `HostBootstrap.Incus` builders are deleted.
- Sprint 15.47: a repository-wide source guard holds § LL's one crossing renderer.

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
