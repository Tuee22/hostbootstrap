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

The table is populated. That is the honest state after a review that read the tree against the
architecture: these shapes are present, the architecture does not want them, and each has a phase whose
completion removes it. Each row's deleting phase carries the sprint that does the work — the ledger
schedules nothing on its own, and a row is deleted when its shape is.

| Shape | Location | Why the architecture does not want it | Deleted by |
|---|---|---|---|
| A second port-range predicate | `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs` | Identical body to the one in the module that owns the reachability vocabulary, so the range is agreed by coincidence | [phase 21](phase-21-composition-and-network-algebra.md) |
| An uncalled flavor selector that maps the Windows accelerator substrate to the CPU base | `hostbootstrap/base_image.py` | No production caller, a mapping every other part of the system contradicts, and a test covering three of five substrates — so the 100% line gate certifies a branch nothing exercises | [phase 23](phase-23-base-image-and-warm-store.md) |
| Two directory-creation locks in the worked consumer | `demo/src/HostBootstrapDemo/Commands.hs` | Exactly the shape the run-ownership module records itself as existing to replace: a hard kill leaves both directories and wedges every subsequent run | [phase 24](phase-24-worked-demo.md) |

## Related

- [development_plan_standards.md](development_plan_standards.md) § I defines this ledger and its limits,
  § D the rule that keeps these shapes out of phase narrative.
- [rationale.md](rationale.md) is where a *rejected* alternative is explained; this file is only for one
  that is still present.
