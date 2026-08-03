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
it does **not** exclude a hostile same-privilege process. No substrate supplies that exclusion, so the
contract no longer claims it. A backend that cannot satisfy a clause returns `Unsupported` and mints no
receipt.

The normative statement is
[development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md); this
document is its canonical explanation and per-substrate realization.

## Current Status

The invariant is defined, the algebra that consumes it exists, and four backends now hold all four
clauses. **One of them is wired into a live call site**; the rest await the plan-driven wiring their
sprints own.

- `HostBootstrap.Reconcile` and `HostBootstrap.Readiness` supply the receipt, prepared-operation, and
  journal types that a satisfying backend settles into. These are implemented.
- `HostBootstrap.Harness.DataRoot` holds all four clauses for the harness durable data root, and is
  **live**: `HostBootstrap.Harness.Ownership` — the bracket every `test run` executes inside — acquires
  and releases `.test_data` through it. The origin record naming the exact prior identity-or-absence is
  published before the directory is created, the created directory's own `device:inode` is bound to the
  receipt, and teardown removes it only after re-observing that identity. This is the first production
  route on the invariant.
- `HostBootstrap.Substrate.Provider.Alias` supplies the typed prepared call/release for the
  provider-guest durable alias, and `discoverStrongAliasBackend` mints a backend that holds all four
  clauses against a real POSIX guest filesystem. The demo still creates the alias with an unowned
  `ln -s`; migrating that call site is open Sprint 11.10 work.
- `HostBootstrap.Cluster.Backend` holds all four clauses for the kind cluster, binding to the
  control-plane node's container ID. The plan-level replacement of the imperative `ensureCluster`
  delete-recreate is open Sprint 5.7 work.
- The WSL2 global `.wslconfig` wall is a portable driver (`Wsl2.GlobalWall.Host`) over a `Posix` and a
  `Windows` backend; the backup-existence (`.bak`) inference is gone. On 2026-08-01 the Windows-gated
  suite exercised the production entrypoint against a temporary `USERPROFILE` and passed all four
  native apply/restore/origin/replacement cases. This is focused adapter evidence, not the full WSL2
  provider lifecycle gate.

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

| Clause | Windows host | POSIX host | Linux guest (WSL2, Lima, Incus) |
|---|---|---|---|
| 1 — exclusive entry | `LockFileEx` byte-range lock | `flock` via `unix` | `flock(1)` |
| 2 — durable origin record | journal under the project state directory: write-temp, fsync, rename | same | same, recorded host-side |
| 3 — identity binding | `getFileInformationByHandle` → `bhfiVolumeSerialNumber` + `bhfiFileIndex` | `deviceID` / `fileID` from `getFileStatus` | `stat -c '%d %i'` |
| 4 — conditional release | re-observe through the retained handle, compare, act | same | `stat`, compare, `unlink` |

Every mechanism above uses a dependency or platform API already present. `Win32` ships with the pinned
GHC; the Windows host backend supplements its public surface with a narrow direct `kernel32` FFI where
exact status preservation is required. This adds no Haskell package, C shim, or Cabal `c-sources`;
`unix` remains the existing conditional POSIX dependency, and the guest column remains coreutils plus
util-linux.

Host **directories** — the harness data root is one — use the same host columns with two refinements.
Clause 1 is the protected store's own OS-released entry (`hLock`, `flock`/`fcntl` on POSIX and
`LockFileEx` on Windows), so the store's compare-and-swap and the directory's mutation share one
bracket by construction. Clause 3 reads the directory's identity without following a link:
`lstat` on POSIX, and on Windows a handle opened with `FILE_FLAG_BACKUP_SEMANTICS` (required to open a
directory at all) plus `FILE_FLAG_OPEN_REPARSE_POINT`.

Guest-side probes obey the probe discipline in [readiness](readiness.md): one observation per probe, no
compound `set -eu`, no nested `"$(…)"`, so they survive the Windows PowerShell → `wsl` → `bash` path.
`stat -c '%d %i'` and `flock` meet that bar; branching and retry stay in Haskell.

## What the invariant excludes

Stating this exactly is part of the contract. Overclaiming here is the defect the previous rule had.

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

## Why the rule changed

The superseded rule required "an OS-protected namespace plus an identity-bound conditional
mutation/delete." That is a statement about a *platform primitive*, and no platform in scope supplies
one for these objects. Three consequences followed:

1. **It was uniformly unmet.** Backend discovery returned `Unsupported` on every substrate, so the
   typed ownership path was unreachable and production kept an unowned bypass. A rule that no backend
   can satisfy enforces nothing.
2. **Satisfying it broke uniformity.** The only serious attempt was a Windows-specific native shim,
   which would have made one substrate authoritative and the others not — the opposite of what a
   uniform contract is for.
3. **It drove unbounded scope.** Because the shim still did not meet the bar, the next step was a
   privileged Windows broker service. That is a large, platform-specific, security-sensitive surface
   bought for a guarantee the contract could not honestly deliver on any substrate anyway.

Restating the rule as a protocol keeps every property that was actually load-bearing — crash recovery,
exclusion of cooperating races, refusal to clobber — expresses them identically on all substrates, and
drops only the claim that a hostile same-privilege process is excluded. That claim was never true.

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
