# Legacy Code Tracked For Deletion

**Status**: Non-normative
**Supersedes**: N/A
**Referenced by**: [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Name the code that is still standing in the tree which the architecture does not want, and
> the phase whose completion deletes each piece.

This document is **not normative** and it is **not a work queue**. It schedules nothing: the deleting
phase's own `Remaining Work` is where that work is stated, and this table only records what is still
present in the meantime. It exists because § I distinguishes two different things:

- an **absence guard** asserts that a wrong shape is *gone* and cannot return — a test or validator
  check, never a document;
- this ledger records a shape that is *still here*, together with who removes it.

A phase narrative never mentions any of these shapes. Under § D a phase says what it builds, in present
tense, and a surface the architecture does not want is one no phase introduces. Keeping the two apart is
what stops this file from becoming the repair log § A forbids.

Every row names a **deleting phase**, and the documentation validator refuses a row whose phase does not
resolve — an unowned row is exactly how a ledger rots. A row is removed when its shape is. **An empty
table is the healthy end state**, not a document to keep populated.

## Tracked shapes

| Shape | Location | Why the architecture does not want it | Deleted by |
|---|---|---|---|
| `ProductionCloseRoot` together with `destroyCloseRoot` and `preEffectCloseRoot`, derived from root invocation authority alone | `core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`, re-exported by `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Closure.hs` and consumed by `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs` | Production closure is not a root-only half. Settled destroy and true pre-effect refusal must each combine the exact root with the bound run lease, bound plan snapshot, versioned project-operation state, and their distinct complete closure evidence before mode release is authorized. | [the recovery-and-migration phase](phase-18-recovery-and-migration.md), at Production composite entry and settled Production destroy closure |
| The `classifyAlias` / `planAliasEnsure` guest-probe state machine, and the raw `test -L` / `readlink` / `test -e` probes that feed it | `demo/src/HostBootstrapDemo/Commands.hs` | A durable alias is a clause-holding ownership operation, so it belongs to the prepared-operation route that mints a managed handle and receipt. A hand-rolled classifier over guest probes holds none of the four clauses and cannot produce a receipt teardown can consume. | [the worked-demo phase](phase-24-worked-demo.md), at its guest-alias adoption |
| `clusterSliceOfBudget` and its independently derived descriptive cluster slice | `demo/src/HostBootstrapDemo/Commands.hs` | The cluster consumer must receive the exact constructive `BudgetPartition` / `ResourceSlice` projected from the retained plan and concrete workload, not a separately calculated `Resources` value. | [the worked-demo phase](phase-24-worked-demo.md), at its concrete workload and slice projection |
| `ServiceHandler` returning `IO ()` | `core/hostbootstrap-core/src/HostBootstrap/Service.hs` | A handler's input is least-authority but `IO ()` leaves what it may *do* unbounded, so a web role could spawn a process and an accelerator role could reopen the sibling config. The effect-indexed `ServiceProgram` already exists and makes an undeclared effect a compile error. | [the service-runtime phase](phase-22-service-runtime.md), at its deploy step |
| Frame identity compared as `Text` in the teardown driver (`teardownCursorFrame cursor /= current`) | `core/hostbootstrap-core/src/HostBootstrap/Command.hs` | Whether a node belongs to this frame is a boundary, and § HH makes a boundary a type. A comparison anyone can forget to write is a convention; the closed local/foreign sum with a total eliminator is not. | [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) |

## Related

- [development_plan_standards.md](development_plan_standards.md) § I defines this ledger and its limits,
  § D the rule that keeps these shapes out of phase narrative.
- [rationale.md](rationale.md) is where a *rejected* alternative is explained; this file is only for one
  that is still present.
