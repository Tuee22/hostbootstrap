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
| A third private copy of the architecture alias table | `hostbootstrap/docker_ops.py` | One alias table is the vocabulary; a second and third are two more places a new architecture must be added, and two more that can disagree | [phase 1](phase-1-python-pre-binary-floor.md) |
| An empty `stubs/` directory carried as a check target | `stubs/` | It holds no stubs, so three tool configurations name a path that contributes nothing and one needs a comment explaining why it must be skipped | [phase 1](phase-1-python-pre-binary-floor.md) |
| Seven source-introspection helpers copied across six spec files | `core/hostbootstrap-core/test/SpecIndexSpec.hs` and five peers | The shared guard module exists for exactly these; the copies have already drifted into two different readers of one Cabal field, so guards that believe they enumerate the same modules do not | [phase 2](phase-2-haskell-core-scaffolding.md) |
| A second implementation of outer-host substrate detection | `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs` | It is a port of the bootstrapper's detection and says so; § M gives pre-binary detection to one side, and two implementations of one classification agree only until they do not | [phase 3](phase-3-host-tools-and-substrate-detection.md) |
| A testing seam on the public library surface | `core/hostbootstrap-core/hostbootstrap-core.cabal` | It renders coordinator bytes for the durable store from an exposed module; the comparable provider seam is private for that reason, and no fixture pins that a consumer cannot reach this one | [phase 5](phase-5-installed-identity-and-authority-kernels.md) |
| A raw command leaf that admits an empty argument vector | `core/hostbootstrap-core/src/HostBootstrap/Lift.hs` | Its fold produces a dispatch naming the empty-string executable, which is the bare-command-name shape § K makes unrepresentable one layer down | [phase 8](phase-8-ensure-reconcilers.md) |
| An exported self-reference constructor with exported accessors | `core/hostbootstrap-core/src/HostBootstrap/Lift.hs` | Two adjacent unvalidated paths that can be transposed, in a value that feeds process dispatch; an exported accessor still admits record update, so a handed value can be re-pointed | [phase 8](phase-8-ensure-reconcilers.md) |
| Five `error` calls asserting a validated plan is non-empty | `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs` | The constructor already refuses the empty case; the accessor's return type discards that, so each site rebuilds the fact and crashes on the branch the constructor excluded | [phase 12](phase-12-step-algebra-and-project-plan.md) |
| Five copies of the ownership store adapter | `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs` and four peers | The clause algebra is genuinely shared and the adapter to it is not; two copies are identical apart from three strings and have already drifted in their foreign-record refusal | [phase 14](phase-14-ownership-clauses-and-reservations.md) |
| A second little-endian word reader | `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs` | One wire-format decoder written twice in two unrelated modules, byte-identical | [phase 14](phase-14-ownership-clauses-and-reservations.md) |
| A second guest-VM backend constructor | `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs` | It duplicates its neighbour's guards, shape and failure construction and builds the same specification value; § LL makes a provider a row, not a branch | [phase 15](phase-15-host-providers-and-the-lift.md) |
| A cluster-configuration selector whose value its only consumer discards | `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs` | Two owners decide one thing, so the unexercised one names an accelerator template that exists nowhere in the tree | [phase 16](phase-16-cluster-lifecycle-and-cordoning.md) |
| A second port-range predicate | `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs` | Identical body to the one in the module that owns the reachability vocabulary, so the range is agreed by coincidence | [phase 21](phase-21-composition-and-network-algebra.md) |
| An uncalled flavor selector that maps the Windows accelerator substrate to the CPU base | `hostbootstrap/base_image.py` | No production caller, a mapping every other part of the system contradicts, and a test covering three of five substrates — so the 100% line gate certifies a branch nothing exercises | [phase 23](phase-23-base-image-and-warm-store.md) |
| Two directory-creation locks in the worked consumer | `demo/src/HostBootstrapDemo/Commands.hs` | Exactly the shape the run-ownership module records itself as existing to replace: a hard kill leaves both directories and wedges every subsequent run | [phase 24](phase-24-worked-demo.md) |

## Related

- [development_plan_standards.md](development_plan_standards.md) § I defines this ledger and its limits,
  § D the rule that keeps these shapes out of phase narrative.
- [rationale.md](rationale.md) is where a *rejected* alternative is explained; this file is only for one
  that is still present.
