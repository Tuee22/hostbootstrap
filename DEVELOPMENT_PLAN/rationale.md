# Design Rationale

**Status**: Non-normative
**Supersedes**: N/A
**Referenced by**: [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Explain *why* the architecture has the shape the phases build, including the shapes it
> deliberately does not have, so a reader does not reintroduce one.

This document is **not normative**. The phases say what to build; the standards say how the plan is
organized; this says why the design is what it is. It is the one place in `DEVELOPMENT_PLAN/` permitted to
name a shape the project does not use (§ D), because naming the rejected alternative is the entire point.

Every entry is written in the present tense as justification, not as a chronicle. There are no dates and
no "we used to" — an entry says *this shape is wrong and here is the failure it produces*, which is the
part that stays true.

Each entry names an **absence guard** where one exists (§ I): the mechanical check that stops the wrong
shape from returning.

---

## Ownership and reservations

### The four ownership clauses do not demand a protected namespace

A natural first formulation of resource ownership is "an OS-protected namespace plus an identity-bound
conditional kernel mutation". **No substrate supplies that.** Under it, alias-backend discovery returns
`Unsupported` on Lima, Incus *and* WSL2 simultaneously, so the typed ownership path is unreachable on
every provider lane at once and production is left holding an unowned `ln -s`. A contract no backend can
satisfy is not a strict contract; it is an unimplementable one, and its practical effect is to legitimize
the bypass.

The four **Locked-Origin Identity Ownership** clauses instead demand an OS-released lock, a durable origin
record, identity binding, and identity-conditional release — each of which every substrate can hold with
dependencies already present. One backend then serves every lane: all three provider guests run the same
Linux image, so `flock`, a host-side origin record, and `stat` identity binding close the alias on WSL2,
Lima, and Incus together.

A consequence worth stating plainly: no privileged Windows broker service is needed, and no `.c` shim is
retained. Both existed only to reach the unimplementable bar.

### A bare exclusive create is not ownership

`createDirectory`, `O_EXCL`, or compare-then-unlink **binds a pathname and satisfies none of the four
clauses.** It cannot distinguish a crashed predecessor from a live one, cannot attribute the object to the
run that made it, and cannot refuse to remove a stranger's object. The failure it produces is concrete: an
interrupted run leaves both the object and a sibling lock behind, the next run refuses, and an operator
must remove both by hand.

A receipt therefore requires the OS-released lock, the durable origin record, the identity binding, and the
conditional release **together**. A backend that cannot hold a clause reports `Unsupported` and mints no
receipt, rather than minting a weaker one.

*Absence guard:* no module exposes a config-owner lock path or an owner-suffixed lock directory.

### The origin record names the payload before the object exists

Recording only "the path was absent" leaves the crash window between the origin record and the identity
binding unresolvable: recovery finds an object it cannot attribute and must either adopt content of unknown
provenance or refuse forever. Recording **the digest of the payload this run intends to install** makes the
window resolvable, because the record names the bytes.

### A run settles its owned objects before closing its lease

The abandoned-run sweep enumerates incomplete **leases**. Any ownership record still standing when its own
run's lease closes is therefore unreachable by every later sweep — and the file it names survives too, which
is exactly what the next run's existence check refuses on. The result is an operator-visible refusal that no
operator caused and no recovery path can resolve.

So the release order is: settle every owned object, *then* close the lease.

### Mode is released after the lease, never before

A crash between the two must leave the mode **held** and the run recoverable. The reverse order leaves the
mode cleared with work outstanding, which lets a fresh run take a project that still has live resources.

### The harness sweep does not touch the reserved Production lease

A live Production invocation's lease is structurally indistinguishable from an abandoned harness run's —
unbound, open, carrying no generative identity. Reading it as abandoned closes a **live** invocation's
lease and discards the evidence Production's own bound recovery reads.

Skipping it opens no hole, because Production closes its lease *before* releasing its mode. An open
Production lease therefore implies the Production mode is still held, so the harness is refused by the
stated mode exclusion — a stated refusal rather than a sweep that quietly resolves another profile's state.

The distinction must be structural rather than a convention two call sites could disagree about: run
identities are minted in one generative form, so the reserved name cannot collide with one.

### Run liveness is established before the sweep, and held for the whole run

Without a liveness primitive the sweep cannot tell a dead predecessor from a live owner. A starting run
then sweeps a **live** run's lease, releases its mode, and takes ownership — and two runs both believe they
own the project. The kernel-released lock is what makes the sweep sound, and it must be held across the
sweep *and* the run, not just the sweep.

### A close authority records its project name

The `projectId` type index belongs to the **config family**, so two projects carrying the same family
share it and the type alone cannot separate them. Without a recorded project name, a close authority minted
for one project closes another's run — reading absent records, reporting success, and leaving the real run's
lease and mode held behind a vacuous success.

### Only a proven pre-effect refusal takes the short close

A settled destroy released real resources, so its close must persist a Closing epoch before the terminal
projection runs and resume that epoch after a crash. Routing settled evidence through the short close skips
the epoch entirely and leaves a half-finished close indistinguishable from a live run. Closure evidence is
therefore checked, not accepted.

---

## Plans, steps, and effects

### A step's action receives its own node, not a bare host config

An action typed `HostConfig -> IO ()` has to *reconstruct* which node it is — its operation key, frame, plan
digest, and dependency set — and anything it reconstructs can disagree with the plan. It also cannot reach
a prepared operation, so it cannot mint a managed handle for the resource it is acquiring, which forces
every real acquisition through an unowned bypass.

The plan therefore mints the descriptor: an action is `forall scope planId. StepExecution scope planId ->
IO result`, carrying the plan digest, the step's own operation key and frame, and its exact ordered edge
set. A step names its node instead of deriving it.

### One plan, not three views of one

Forward ordering, per-frame descent, and reverse teardown are the same resource set seen three ways. Held as
three independent structures — a step list, a topology table, and a teardown hook — they can disagree, and
the disagreement is silent: teardown releases a resource the forward pass never acquired, or misses one it
did.

So a step declares its own frame boundary and its own reversing effect, and both teardown verbs are
*projections* of that one validated plan. The row that announces a child config is the node that carries it.

### `deploy-kind` deletes under both verbs

Every other frame distinguishes stop from delete, but kind has no reliable stop/restart contract. Modelling
a stop it cannot honour produces a cluster that is neither running nor cleanly absent.

### Teardown scheduling is two passes, not one

A single depth-first pass re-offers the first failing node forever and starves its siblings. Fresh work is
therefore scheduled before retries, so a permanently failing node keeps its own parent blocked while
unrelated siblings still make progress — and the forest never completes, which is the correct end state
rather than a truncated traversal presented as settled.

### Foreign and refused observations are not failures

A conflict or a safety refusal means *this* resource is not ours to touch. Treating it as a failure aborts
the run's other owned cleanup, which is strictly worse: the run then leaks resources it does own. Both
settle their node without touching the object and are recorded separately from failures.

### A truncated traversal cannot be a settled destroy

Settlement is checked against the projection's own node set, not against "the traversal finished". Otherwise
a one-frame run mints settled-destroy evidence for nodes it never visited.

### Generative handles are never serialized

Recovery reconstructs the same plan **identity** under a new in-process handle. Serializing a handle,
journal, or receipt would let a value outlive the process that can validate it, and a delayed one then
becomes indistinguishable from a live one.

### A proof is compared against the plan digest even when the indices match

Phantom type indices alone admit a proof taken over one plan being presented for another whenever the two
share an index. The digest comparison is what makes the pairing a fact rather than a convention.

---

## Recovery

### Recovery runs on a fresh broker generation

Resuming the dead run's generation makes a delayed permit from that run indistinguishable from a live one.
A fresh generation fences the old permits out. Nothing that must survive a reopening — the plan snapshot,
the durable invocation disposition — is written by the reopening itself, so a second attempt reads the same
state and reaches the same branch.

### Reopening rechecks the lease it was handed

The sweep observes leases at an earlier store version. Between that observation and the reopening, a lease
may have been closed by a competing resolver or bound to a different snapshot. Without the recheck the
reopening proceeds past classification on a dead run and then fails later with a misleading cause — naming
a missing mode rather than the closed lease that is the actual state.

### A recovered run gets destroy authority and nothing else

Recovery exists to settle what a predecessor left. Given `up` authority it could start new work under a
plan it did not build; given harness planning authority it could hand a project a fresh profile. It
therefore receives the destroy root, the already-bound lease, the old snapshot, and the narrow close
authority — and no fresh profile, no harness authority, and no unbound lease to rebind.

### The sweep rechecks after its callbacks

A fold that resolved nothing must not report a vacuous success. Re-reading the incomplete set after the
callbacks is what makes "every abandoned run is settled" an observation rather than a claim.

---

## Configuration and delivery

### A child config is written in place at the frame that announces it

A build-then-copy path and a mount path are two representations of one delivery, and they can disagree
about which bytes the child actually reads. In-place delivery at the announcing node makes the announcement
and the bytes the same fact.

### The install is a hard link with no replace, never a symbolic link

The inspector that verifies an installed sibling refuses a symbolic link, so a symlink install is
unreachable on every platform *and* leaves a dangling destination behind when it fails. The primitive the
operation needs is create-if-absent hard link.

### Tokens never travel through Dhall, `argv`, or the environment

All three are readable by any process on the host and are captured in logs and crash dumps. A one-time
grant that leaks is not one-time.

### Core owns no default config values and no fixed config type

A default is a decision made on behalf of a project that core cannot validate. Every project-owned value
arrives through the project's own codec, so a missing value is a refusal rather than a silent core default.

### Secret references are scope-indexed

If one secret type serves both scopes, a test-only plaintext value is representable in production
configuration and is excluded only by consumer policy. Indexing the type by scope makes it
*unrepresentable*, which is a stronger guarantee than a policy anyone can forget.

---

## Builds and the base image

### One host-compatible Cabal project, not a container-only freeze

The base image's Cabal store is an **opportunistic cache**, not a solver API. A container-only project file
or a base-owned freeze fragment turns a cache miss into a hard failure, and it hides drift between the
repository and the published base. With one host-compatible project, a miss simply resolves and builds.

### The base is rebuilt and republished, never replayed from a lock

A rebuild's purpose is to discover the *current* compatible upstream versions. Replaying a committed input
lock produces a base that no longer reflects what consumers will actually resolve against, so the published
tag stops being useful evidence.

Building the base locally and testing derived projects against the un-republished local image hides exactly
the drift the rebuild exists to surface.

### `fourmolu` and `hlint` run only in the container

Their host versions are not the canonical ones, so a host pass proves nothing about the gate consumers
actually face. They belong to the in-container `check-code`, which means the host static gate is not the
complete quality gate — a fact worth stating rather than assuming away.

### A declared project name equals the invoked executable identity

Otherwise one binary can present itself as another project and read that project's configuration and state.

---

## Phase organization

### Substrate confirmation is owned by a terminal phase, not by the phase that wrote the code

If a phase stays open until it has been confirmed on hardware it names, then a phase naming four lanes is
unclosable on any single machine — and under numerical order it blocks everything after it. Worse, the
lanes are not substitutable: a run on one provider or architecture validates only that lane, so no amount
of running one closes another.

Splitting confirmation into terminal per-substrate phases keeps every building phase closable on the
baseline, and keeps the confirmation obligation explicit instead of dropping it.

### Sprints are budgeted because unbudgeted sprints absorb whole phases

A sprint with no size limit becomes the place all remaining work accumulates: its remaining-work section
grows into a chronicle, its dependencies become the union of everything it bundles, and bundling is what
manufactures dependency cycles between sprints that individually have none.
