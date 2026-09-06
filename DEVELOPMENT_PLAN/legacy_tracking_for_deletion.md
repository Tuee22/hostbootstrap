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

## Related

- [development_plan_standards.md](development_plan_standards.md) § I defines this ledger and its limits,
  § D the rule that keeps these shapes out of phase narrative.
- [rationale.md](rationale.md) is where a *rejected* alternative is explained; this file is only for one
  that is still present.
