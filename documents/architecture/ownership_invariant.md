# Ownership Invariant

**Status**: Authoritative source
**Supersedes**: the platform-primitive ownership rule that admitted a backend only with an OS-protected
namespace plus an identity-bound conditional kernel mutation, and returned `Unsupported` otherwise
**Referenced by**: [ownership seam](ownership_seam.md), [lifecycle state model](lifecycle_state_model.md),
[durable state](durable_state.md), [readiness](readiness.md), [WSL2](../engineering/wsl2.md),
[applied cordon](../engineering/applied_cordon.md), [Incus](../engineering/incus.md),
[Lima](../engineering/lima.md), [documents index](../README.md)

> **Purpose**: Define the one ownership invariant every substrate must satisfy before mutating shared
> state — its four clauses and the exact guarantee it does and does not provide.

## TL;DR

Ownership is a **protocol** requirement, not a platform-primitive requirement. A backend may mint an
ownership receipt when it holds all four **Locked-Origin Identity Ownership** clauses: an OS-released
exclusive lock, a durable origin record written before the first mutation, identity binding to the
object's stable kernel identity rather than its pathname, and conditional release on exact identity
match. This **excludes** crash/retry and concurrent cooperating runs and **detects** foreign mutation;
it does **not** exclude a hostile same-privilege process. No substrate supplies that exclusion, and the
contract makes no such claim. A backend that cannot satisfy a clause returns `Unsupported` and mints no
receipt.

The normative statement is
[development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md); this
document is its canonical explanation and per-substrate realization.

## Current Status

The nouns the four clauses are written in are stated once, without effects, in
`HostBootstrap.Ownership.Object`: the kernel's identity answer, the bytes a run intends to install and
their digest, what is owned and what was there before, the durable origin record with its one canonical
codec, and the closed fault sum with its total eliminator. See
[ownership seam](ownership_seam.md#the-vocabulary) for what each carries and why.

The invariant is defined and the algebra that consumes it exists. The prepared Incus provider/share and
provider-guest alias implementations encode all four clauses, and the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
carries both its static and its native Linux/x86_64 KVM/Incus closure evidence. The demo
still uses its compatibility
provider/alias call site; adopting the sealed route belongs to the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md), which is where that call site's
native validation lives.

- `HostBootstrap.ProjectPlan` is the sole whole-plan producer of `PlannedResource` and `PlannedEdge`.
  Its facade takes an opaque admitted `OperationKey` plus a closed `PlannedResourceKind`, generates the
  resource and frame identities under a rank-2 continuation, and admits a typed edge only when the exact
  resources remain open and the dependency exists in the same plan. `HostBootstrap.Reconcile` consumes
  that vocabulary through the public facade. Its exact, total `stepExecutionFor` producer accepts one
  `ProjectPlan scope specDigest planId configId cfg`, a matching `StepRuntime scope planId`, and one
  `PlannedStep scope planId configId (cfg scope)`. The resulting `StepExecution scope planId` retains the
  stable plan digest, admitted configuration digest, stable node identity, frame, operation key, ordered
  dependency prefix, and projected operation keys. The shared `scope`, `planId`, and `configId` inputs make
  a node from another admission a type error; no caller supplies an identity or asks a membership question.
  `HostBootstrap.Reconcile` exposes no constructor for the plan, planned resource, or canonical snapshot.
  Its resource-narrowing and guest-alias adapters consume the same exact descriptor projections.

  `StepRuntime scope planId` contains the interpretation's `ResourceCarrier scope planId`, so a managed
  resource carried from a projected node can be read only within the same scope and plan. Every phantom
  parameter on the opaque lifecycle-plan, execution, runtime, carrier, handle, receipt, authority,
  descriptor, dependency, prepared-call, reconcile-result, journal-proof, and phase-evidence types has an
  explicit nominal role. Equal runtime representations therefore cannot use `coerce` to relabel a scope,
  plan, resource, operation, phase, attempt, or journal identity.

  Public `HostBootstrap.Chain` now consumes one exact `ProjectPlan` and its non-empty `forward`
  projection together with a matching execute-phase `CommandAuthority` and `LifecycleCursor`. Before it
  begins I/O, it checks that the authority belongs to the supplied `ProtectedStore`, and it compares the
  cursor's retained store plus decoded acquisition project/store/broker origin with that authority. It
  also compares the retained frame, verb, and phase terms before opening the journal or performing any
  durable transition. The authority's broker epoch and invocation identity drive the operation session,
  each exact `PlannedStep` enters the total `stepExecutionFor` producer, and descent comes only from the
  plan's `DerivedTopology`. The term-level origin check makes even a hostile package substitution fail
  before durable state is opened rather than relying only on nominal indices. Every later protected
  entry revalidates the cursor's exact acquisition source and current durable row under that same
  exclusive entry before its dependent journal/session/prepare/settle/close action. An execute cursor
  advanced to teardown therefore cannot be reused through a stale in-memory value.

  The step callback's raw `StepObservation` is deliberately plan-independent and grants no ownership.
  The public plan facade immediately wraps that result under the projected scope, plan, and configuration
  indices as opaque nominal `PlannedStepObservation scope planId configId`; a caught safety refusal is
  wrapped through the same call-site `PlannedStep`. Chain classifies, reports, and acknowledges only this
  indexed wrapper, so an
  observation from another scope, plan, or configuration cannot enter the node's settlement path through
  `coerce`.

  Production `HostBootstrap.Command` retains or reconstructs one exact plan and keeps render/persist,
  root-refined lifecycle-context admission, fixed root-Up entry interpretation, observations, and current-frame
  reverse work under that identity. The Cabal-private `LifecycleEntry` producer alone derives the
  journal/current cursor, invokes generic `authorizeRootProject`, and supplies the raw lower Chain inputs. No
  Production plan-only authority, raw-step descriptor, alternate
  forward interpreter, or reverse-plan producer exists. This exact representation does not itself mint
  `down`/`destroy` authority; nested lifecycle entry fails closed and
  [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
  owns the proof-complete operator/descent gates. The
  [test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
  owns direct Harness interpretation.
- `HostBootstrap.Harness.DataRoot` holds all four clauses for the harness durable data root **through the
  one seam**, and is **live**: `HostBootstrap.Harness.Ownership` — the bracket every `test run` executes
  inside — acquires and releases `.test_data` through it, against the row `ownershipRowForHost` selects.
  The origin record naming the exact prior identity-or-absence is the canonical `OriginRecord`, published
  before the directory is created; the created directory's own identity is bound to it; and teardown
  re-enters the object from that record and removes it only after re-observing the identity. What stays
  the data root's own is its policy rather than its mechanism: the parent is scaffolding that is created
  if missing and never owned, a directory the run merely found is preserved, and a confirmed generation's
  content is cleared *after* clause 4's re-observation and before the seam removes the directory itself.
  This was the first production route on the invariant.
- `HostBootstrap.Harness.GeneratedConfig` holds all four clauses for the run's generated sibling
  `<project>.dhall` **through the same seam**, and is **live** on the same bracket. It is the same
  protocol over a file: the canonical `OriginRecord`, whose file case names the recorded absence *and the
  intended payload digest*, is published before the file is created; the payload is staged and then
  published through the row's atomic no-replace primitive, so a target that already exists is refused
  rather than replaced; the created file's own identity is bound to the record; and release re-enters the
  object from that record. Because both owners consume one seam and one row, the directory and file
  realizations cannot drift, and the record one writes is the record the other reads. What stays the
  generated config's own is its policy rather than its mechanism: a found object is refused before any
  record is written and is never adopted, and release compares the bytes against the recorded digest
  *after* clause 4 has confirmed the identity — so an edited file is left intact even though it is the
  same object. Recording the payload digest before the write is what makes the crash window between the
  record and the identity binding resolvable without ever adopting bytes the record does not name. No
  pathname sidecar participates in that authority.
- `HostBootstrap.Substrate.Provider.Backend` and `Provider.Reconcile` supply the prepared Incus
  provision/readiness/share/stop/delete route. The opaque nominal `ManagedProviderHandle` and
  `ManagedProviderShareHandle` retain the exact backend origin rather than exposing their generic
  handle/receipt components. Incus publishes an explicit-absence fresh-nonce origin before launch, binds
  the VM UUID and owner nonce, records share intent/device identity durably, and revalidates those facts
  before every later mutation or guest execution. Direct uses the same prepared algebra only for a
  plan-local reservation and identity share; it publishes no physical-host origin and cannot produce
  successful stop/delete authority.
- `HostBootstrap.Substrate.Provider.Alias` supplies the typed prepared call/release for the
  provider-guest durable alias. Its `StrongAliasBackend` is derived only from the capability for the exact
  managed Running provider and accepts the exact opaque managed share authority. `ManagedGuestAliasHandle`
  hides the generic handle/receipt authority after settlement. The whole-plan alias projection yields its
  opaque alias resource and typed alias-to-share edge only when the durable-share node both depends on the
  provider and declares the derived `<provider>/<share>/guest-alias` operation. The demo still creates the
  alias through its compatibility pathname route; migrating that call site belongs to
  [the worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).
- `HostBootstrap.Cluster.Backend` holds all four clauses for the kind cluster. Its canonical
  `prepared`/`executing`/`managed` records self-bind their own inode under the retained state/lock identities;
  every state binds the exact cluster name/owner/nonce; `executing` binds the exact config digest/inode and
  private kubeconfig inode before Kind; and `managed`
  binds the complete declared node-name-to-container-ID map. Cordon mutates immutable IDs, while readiness
  and cleanup re-observe every retained node. Production tool discovery starts from typed
  `HostConfig`/`HostTool`; raw executor injection and result constructors are Cabal-private. The exact
  packages and interpreter belong to sprints 16.1–16.11 of the
  [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
- The implemented direct-Colima backend applies the four clauses to one 128-bit plan/lifecycle namespace, not to
  a caller-selected profile. Its reusable global lock contains only its own self-bound profile/lock identity
  and remains synchronization-only across owners. A fresh self-bound nonce record publishes absence before
  the isolated Colima home or Docker config is created; descriptor-relative transitions retain the exact
  acquisition invocation, root/data wall, machine/context, record/namespace/disk objects, directory chain,
  and complete Colima/Lima artifact manifest. The sole pre-call `prepared` state cannot adopt a present
  profile after an outcome-unknown start; only a matching managed stage can recover it. Live Docker
  reacquires that exact binding. Cleanup carries a distinct journal invocation, enters `releasing` before
  `colima delete --force --data`, and proves profile/data/context absence before conditionally removing only
  manifest-listed namespaces and origin evidence. This source boundary belongs to the
  [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
  and remains non-closing until that phase's focused and full gates pass.
- The WSL2 global `.wslconfig` wall is a portable driver (`Wsl2.GlobalWall.Host`) over a `Posix` and a
  `Windows` backend; the backup-existence (`.bak`) inference is gone. On 2026-08-01 the Windows-gated
  suite exercised the production entrypoint against a temporary `USERPROFILE` and passed all four
  native apply/restore/origin/replacement cases. This is focused adapter evidence, not the full WSL2
  provider lifecycle gate.

The plan projections above are descriptive identity and topology evidence, not ownership receipts or
mutation authority. They prevent a caller from supplying a plan digest, frame text, resource identity, or
dependency edge independently; the selected backend must still satisfy all four clauses below before it
may mutate the named object or mint ownership evidence.

Phase and sprint ownership is in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md). Where a clause below has no live
consumer yet, it is a target contract for the named sprint rather than a current claim.

## The four clauses

A backend satisfies the invariant only when it holds all four. Partial satisfaction is `Unsupported`,
not a weaker receipt.

### 1. Exclusive entry

A kernel-held lock is acquired before any mutation and retained across the whole
observe/mutate/settle bracket. The lock must be released by the operating system on process death, so
a crashed run cannot strand it. A lock held only by cooperating library code, or one that requires an
orderly unlock, does not satisfy this clause.

### 2. Durable origin record before the first write

Before the first mutating call, the backend durably records either the exact original bytes **or** an
explicit absence marker, keyed by a generative nonce. Absence is a recorded fact, never an inference
from a missing backup. This clause is what makes restore correct after a crash between the first write
and the run's completion — without it, a retry can record generated content as the original and
teardown then restores that content instead of the user's state.

### 3. Identity binding, never pathname

Every operation after the first binds to the object's stable kernel identity — the
`(volumeOrDevice, fileIndexOrInode)` pair — rather than the name it was reached by. A pathname is
evidence of nothing between two operations: another process can rename, replace, or redirect the name
in that window. Reparse points and symlinks at the target are rejected rather than followed.

### 4. Conditional release

Restore and delete re-observe the recorded identity and act only on an exact match. Any other
observation is a structured `Conflict` carrying expected and observed identity, and the object is left
untouched. The invariant never removes state because its pathname matched.

## How the clauses are realized

The clauses are uniform; the mechanism that supplies each belongs to a **row** of the frame table, and the
transaction they compose is written once above those rows. [Ownership seam](ownership_seam.md) is the
canonical home for that structure: the seam of kernel primitives, the two platform rows, the row that runs
a transaction at the frame owning the object, the atomic no-replace publication, and what each individual
owner adds on top.

Two consequences belong here rather than there, because they are properties of the contract rather than of
its realization. A backend that cannot supply a clause returns `Unsupported` and mints no receipt — never a
weaker receipt. And the clause *order* is not a convention a reviewer checks: a mutation consumes the
recorded origin and a release consumes the bound identity, so performing either out of order has no term.

## What the invariant excludes

Stating this exactly is part of the contract; any stronger claim is unsupported.

| Scenario | Outcome |
|---|---|
| A run crashes between the origin record and the first write | Recoverable. The next run reads the origin record and restores exact bytes or absence. |
| A run crashes after the first write | Recoverable, same mechanism. |
| Two concurrent `hostbootstrap` runs target the same state | Excluded. The second blocks on clause 1, then observes clause 3's identity. |
| A cooperating peer replaces the object between two operations | Detected. Clause 3 reports `Conflict`; clause 4 refuses release. |
| A hostile same-privilege process ignores the lock and replaces the object | **Not excluded.** Detected on the next identity observation, never silently overwritten. |

The last row is the honest boundary. An advisory lock can be ignored by a process that chooses to, and
no substrate in scope offers a mandatory one for these objects. The contract detects that case and
refuses to act; it does not prevent it.

## When a backend returns `Unsupported`

`Unsupported` is a real outcome, not a failure to try. A backend returns it — and mints no receipt —
when a clause is unsatisfiable on the host:

- the filesystem cannot report a stable object identity (clause 3). On Windows the 64-bit file index is
  unique and stable on NTFS; a non-NTFS volume is `Unsupported` rather than assumed.
- the lock cannot be taken because the platform or filesystem does not support it (clause 1).
- the state directory is not writable, so no origin record can be made durable (clause 2).

`Unsupported` carries the attempted operation and the reason. It is distinct from `Conflict` (an
identity mismatch), `SafetyRefusal` (a policy decline), and `Failure` (an IO fault); observation is
total, so these never collapse into one branch. See
[lifecycle state model](lifecycle_state_model.md) for the full error algebra.

## Why all four clauses are required

An "OS-protected namespace plus an identity-bound conditional mutation/delete" is a statement about a
*platform primitive*, and no platform in scope supplies one for these objects. It is not the governing
contract for three reasons:

1. **It is uniformly unavailable.** Backend discovery would return `Unsupported` on every substrate, so a
   typed ownership path could not be reached. A rule that no backend
   can satisfy enforces nothing.
2. **A platform-specific shim breaks uniformity.** A Windows-only native shim would make one substrate
   authoritative and the others not — the opposite of what a
   uniform contract is for.
3. **A privileged broker has unbounded scope.** Such a service is a large, platform-specific,
   security-sensitive surface bought for a guarantee the contract cannot honestly deliver uniformly.

The four-clause protocol keeps the load-bearing properties — crash recovery, exclusion of cooperating races,
and refusal to clobber — and expresses them identically on all substrates. It does not claim exclusion of a
hostile same-privilege process.

## Validation

The invariant is proved by the criteria below. They are not `os(windows)`-gated: a uniform contract
requires a uniform gate, so the ownership suite runs on every substrate, and a case whose subject is
unavailable on the gate host asserts the refusal its row declares rather than disappearing. What counts as
evidence for each criterion — and what cannot — is in [testing](../engineering/testing.md).

1. An adversary replaces the object between observation and mutation. The backend reports `Conflict`
   with structured expected/observed identity, does **not** clobber the object, and mints no receipt.
2. Release is refused when the observed identity does not match the receipt's.
3. A second entry attempt is excluded while the lock is held, and succeeds after the holding process is
   killed (proving the OS released it).
4. A kill between the origin record and the first write leaves recoverable state, including the
   **absent-original** case: the next run restores absence rather than treating generated content as
   the original.
5. A clean-path run reaches absence, creates the object, and reruns to `Unchanged` with the same
   verified receipt on every supported substrate.
6. An unsatisfiable clause returns `Unsupported` with its reason, and no receipt is minted.

Validation status and scheduling belong to
[the development-plan index](../../DEVELOPMENT_PLAN/README.md); dated evidence lives with the sprint
whose gate produced it.

## Related

- [ownership seam](ownership_seam.md) — the one transaction, the seam beneath it, and the rows that
  supply each clause's mechanism.
- [lifecycle state model](lifecycle_state_model.md) — the handle/receipt/phase algebra a satisfying
  backend settles into, and the total error branches.
- [durable state](durable_state.md) — the provider-guest durable alias, the first consumer.
- [WSL2](../engineering/wsl2.md) — the global `.wslconfig` wall, the second consumer.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the kind cluster, the third consumer, whose
  clause-3 identity is the control-plane node container ID.
- [harness workflow](harness_workflow.md) — the run's `.test_data` root, the fourth consumer and the
  first one wired into a production route.
- [Incus](../engineering/incus.md), [Lima](../engineering/lima.md) — peer provider lanes that gain
  clauses 2–4 from this contract.
- [development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md) — the
  normative statement.
