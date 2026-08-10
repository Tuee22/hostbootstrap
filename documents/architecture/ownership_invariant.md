# Ownership Invariant

**Status**: Authoritative source
**Supersedes**: the platform-primitive ownership rule that admitted a backend only with an OS-protected
namespace plus an identity-bound conditional kernel mutation, and returned `Unsupported` otherwise
**Referenced by**: [lifecycle state model](lifecycle_state_model.md), [durable state](durable_state.md),
[readiness](readiness.md), [WSL2](../engineering/wsl2.md),
[applied cordon](../engineering/applied_cordon.md), [Incus](../engineering/incus.md),
[Lima](../engineering/lima.md), [documents index](../README.md)

> **Purpose**: Define the one ownership invariant every substrate must satisfy before mutating shared
> state — its four clauses, its per-substrate realization, and the exact guarantee it does and does not
> provide.

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
  journal/cursor admission, `authorizeProjectUp`, Chain interpretation, observations, and current-frame
  reverse work under that identity. No Production plan-only authority, raw-step descriptor, alternate
  forward interpreter, or reverse-plan producer exists. This exact representation does not itself mint
  `down`/`destroy` authority; nested lifecycle entry fails closed and
  [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
  owns the proof-complete operator/descent gates. The
  [test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
  owns direct Harness interpretation.
- `HostBootstrap.Harness.DataRoot` holds all four clauses for the harness durable data root, and is
  **live**: `HostBootstrap.Harness.Ownership` — the bracket every `test run` executes inside — acquires
  and releases `.test_data` through it. The origin record naming the exact prior identity-or-absence is
  published before the directory is created, the created directory's own `device:inode` is bound to the
  receipt, and teardown removes it only after re-observing that identity. This was the first production
  route on the invariant.
- `HostBootstrap.Harness.GeneratedConfig` holds all four clauses for the run's generated sibling
  `<project>.dhall`, and is **live** on the same bracket. It is the same protocol over a file: the
  origin record naming the recorded absence *and the intended payload digest* is published before the
  file is created, the file is published create-if-absent, its own identity is bound to the receipt, and
  release unlinks only on an exact re-observed identity **and** payload. Both share
  `HostBootstrap.Harness.Identity`, so the directory and file realizations cannot drift. Recording the
  payload digest before the write is what makes the crash window between the record and the identity
  binding resolvable without ever adopting bytes the record does not name. No pathname sidecar participates
  in that authority.
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
- `HostBootstrap.Cluster.Backend` holds all four clauses for the kind cluster, binding to the
  control-plane node's container ID. The plan-level cluster interpreter belongs to the
  [cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
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

## Per-substrate realization

The clauses are uniform; the mechanism that supplies each is per-platform. All three provider guests run
the same Ubuntu image, so the guest column is one implementation, not three.

| Clause | Windows host | POSIX host | Shell-invoked frame (provider guest, project container) |
|---|---|---|---|
| 1 — exclusive entry | `LockFileEx` byte-range lock | `flock` via `unix` | the provider/alias routes admit only util-linux `flock(1)` over the `flock(2)` namespace; a discovered `lockf(1)` remains descriptive `Unsupported` |
| 2 — durable origin record | journal under the project state directory: write-temp, fsync, rename | same | create-if-absent record with a fresh 256-bit nonce inside the host-backed durable target; file and directory fsync plus exact readback before the alias effect |
| 3 — identity binding | `getFileInformationByHandle` → `bhfiVolumeSerialNumber` + `bhfiFileIndex` | `deviceID` / `fileID` from `getFileStatus` | `stat -c '%d:%i'` (GNU coreutils) or `stat -f '%d:%i'` (BSD); neither follows a symlink |
| 4 — conditional release | re-observe through the retained handle, compare, act | same | under the retained lock, `stat` the symlink itself, compare exact device/inode, unlink only on equality, flush the parent, then conditionally remove the exact managed record |

Every mechanism above uses a dependency or platform API already present. `Win32` ships with the pinned
GHC; the Windows host backend supplements its public surface with a narrow direct `kernel32` FFI where
exact status preservation is required. This adds no Haskell package, C shim, or Cabal `c-sources`, and
`unix` remains the existing conditional POSIX dependency.

The shell-invoked column is **discovered, never assumed**. A backend's closed discovery plan asks the frame
it will actually run in which front ends it has; the injected executor returns only raw command outcomes,
and a private total parser retains the answer on the opaque discovery value. The bracket therefore cannot
be built from a tool the frame was never shown to have, and an unrecognized report is
`Unsupported` rather than a guess. Selecting from the build host's `os()` would be wrong in the ordinary
case, not the exotic one: a macOS host drives a Linux guest, so the host's userland says nothing about the
guest's. On Linux, `flock(2)` locks and the POSIX record locks commonly used by `lockf(1)` are distinct
kernel namespaces and do not mutually exclude one another. Provider discovery may retain `GuestLockf` as
a descriptive observation, but the strong alias backend refuses it as `Unsupported`; the Incus ownership
backend likewise requires one resolved `Flock` executable. This prevents two nominally supported front ends
from guarding the same origin record with non-interoperating locks.

The provider-guest alias record is keyed by a SHA-256 digest of an injective owner binding containing the
exact provider origin, share key/generation, alias key/generation, alias, and target; the complete binding
is also stored and checked, so the digest is only a bounded filename. Its `prepared` state records explicit
absence plus a fresh 64-hex-digit nonce before the first alias mutation. A nonce-named staging symlink is
flushed and published at the final pathname with `link(..., follow_symlinks=False)`, which is atomic
no-replace and preserves the staging symlink's device/inode. The `managed` record is then written and
fsynced separately, atomically replaces the prepared record, and is read back after directory fsync.
Release first persists and reads back a version-fenced `releasing` record, then conditionally unlinks the
same identity and durably proves record/alias absence. A retry after any boundary resumes only the exact
`prepared`, `managed`, or `releasing` state and nonce; a correct-looking foreign symlink with no matching
durable record is reported foreign. No pathname sidecar participates in ownership.

Publishing a file under a name that must not already exist uses the platform's atomic **no-replace
link**: `link(2)` on POSIX and `CreateHardLinkW` on Windows. A hard link publishes the written bytes under
the final name in one kernel operation and fails when the name is taken. A *symbolic* link is not a
substitute: it publishes a reference rather than the bytes, and a destination that reads as a link is
refused by the same inspector that enforces "reparse points and symlinks at the target are rejected rather
than followed". `rename(2)` is not a substitute either, because it replaces the destination. The WSL2
global wall was the first user of this primitive (`link` then identity-conditional `unlink` of the
source); the authenticated sibling config is the second.

Host **directories** — the harness data root is one — use the same host columns with two refinements.
Clause 1 is the protected store's own OS-released entry (`hLock`, `flock`/`fcntl` on POSIX and
`LockFileEx` on Windows), so the store's compare-and-swap and the directory's mutation share one
bracket by construction. Clause 3 reads the directory's identity without following a link:
`lstat` on POSIX, and on Windows a handle opened with `FILE_FLAG_BACKUP_SEMANTICS` (required to open a
directory at all) plus `FILE_FLAG_OPEN_REPARSE_POINT`. The harness's generated sibling config — a
**file** — uses the identical columns through the same `HostBootstrap.Harness.Identity` seam, and adds
the payload digest to its origin record, because a file's bytes are part of what "the object this run
owns" means. A found object there is refused rather than adopted: a generated config cannot share a
path with a config that is already present.

Guest-side probes obey the probe discipline in [readiness](readiness.md): one observation per probe, no
compound `set -eu`, no nested `"$(…)"`, so they survive the Windows PowerShell → `wsl` → `bash` path.
`stat` and the lock front end meet that bar; branching and retry stay in Haskell. Where a private marker,
tool path, identity, or backend report is required, success means exactly one LF-terminated stdout line and
empty stderr. Extra lines, carriage returns, missing newlines, unexpected arity, and unknown tags are typed
failure rather than partially accepted evidence.

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
requires a uniform gate, so the ownership suite runs on every substrate.

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
