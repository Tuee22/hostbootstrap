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

### A free-port probe is not a port allocation

Selecting a conventional host port in source or Dhall makes independent project/run owners contend for one
global name. Replacing that number with a scan for an unused port does not repair the ownership problem: the
probe must close its socket before another launcher binds the candidate, and any process may take it in that
gap. A launcher that interprets zero by performing the same probe has the same race even if its configuration
looks dynamic.

The process that retains the binding must choose the number. The cluster backend therefore asks the container
runtime to publish an owned relay listener on loopback without a host-side number; runtime creation binds the
port atomically, and exact inspection turns the resulting mapping into a plan-/cluster-/service-indexed
resolved exposure. Dhall describes semantic service targets because those are replayable intent. The selected
host port is an observed fact tied to a live resource and belongs in authenticated dependency carriage, not in
configuration or canonical cluster bytes.

This also keeps stable cluster-internal ports distinct from host publication. A Kubernetes Service or relay
target may retain a fixed internal port without reserving that number on the provider/host namespace.

*Absence guard:* no production Dhall/Haskell/demo manifest supplies a host-port number; no allocation path
scans or retries candidates; only authenticated inspection of the identity-bound runtime relay mints a local
endpoint.

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

### A shared lifecycle-authority mount is not a recursive transport

A shared directory does not provide one portable protected-store transaction domain. Direct processes on
one kernel may share a lock and rename implementation, but Incus, Lima, and WSL cross filesystem and VM
boundaries whose lock, atomic-rename, cache-coherence, ownership, and failure semantics are not one contract.
An architecture that relies on those semantics therefore changes its authority guarantee with the selected
lift. Mounting the authority namespace also gives the nested process raw access to records it has no reason
to name or mutate.

Durable lifecycle authority consequently stays at the topology root. The root owns the protected store,
bound lease and snapshot, frame catalog, and per-frame journals; a nested executor receives one exact rooted
grant, performs the selected local probe or effect, and returns an observation.

### A generic protected-store RPC cannot stand in for rooted coordination

A read/list/compare-and-swap service lets a nested caller choose record keys, expected versions, and new
bytes. That is durable authority, not a narrow execution grant. Restricting the methods does not repair the
identity mismatch: the global lease and acquisition snapshot are bound to the root plan digest, while an
independently reconstructed projected child plan has its own digest and local identity. Treating the root
journal as if it were a child-plan journal either fails the exact binding checks or silently relabels one
authority as another.

The root instead projects the target plan and operation set into an immutable catalog, selects each frame
transition itself, records Unknown before the effect, and settles only the observation for that exact grant.
The executor never chooses a snapshot, journal row, operation set, or compare-and-swap payload.

### An ephemeral child key does not authenticate the child to its launcher

The launcher can generate, retain, and pass any ephemeral private key the child would use. A signature from
that key therefore proves possession of launcher-supplied bytes; it does not prove that an independently
identified physical child produced the request, and an immediate parent can impersonate the same key.
Authenticating that stronger claim requires an independently provisioned per-frame identity or platform
attestation.

The recursive protocol has a narrower, explicit threat boundary. Root signatures authenticate coordinator
responses, while sealed package-private request construction plus exact requester path, stage, ordinal,
nonce, and predecessor digest prevent accidental substitution, cross-edge confusion, malformed traffic, and
stale replay among cooperating interpreters. They do not defend against a malicious same-privilege launcher
or intermediate process. Claiming only that boundary keeps the type-level guarantee honest.

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

---

## Gates and validation

### A source-byte guard reads bytes, because a locale-decoded read freezes the wrong thing

A frozen source digest exists to say "this module has not drifted". Computing it by decoding the file to
text through the process locale and re-encoding makes the digest a property of the host's active code
page as much as of the file: the same bytes hash differently on a UTF-8 host and a legacy-code-page one,
and on Windows the read additionally strips carriage returns, so a guard meant to freeze a module instead
freezes a console setting and a newline convention, and the failure it reports names the wrong culprit.
Reading the bytes removes both. The suite driver still fixes the encoding once, because the same
reasoning covers a golden comparison over captured command output, and fixing it centrally is what stops
each spec fixing it locally and differently.

A frozen digest also has a subject, and the subject is what the sprint owns. Freezing a whole shared
package description instead of the stanza a sprint claims couples every later sprint to that evidence:
adding a test module to the file falsifies a digest owned by phases that have nothing to do with the
change, and § A's numerical order has no edge to express that (§ C).

*Absence guard:* the suite asserts that no spec derives a frozen digest from a locale-decoded read, and
that the driver **applies** the locale fix rather than merely importing it (§ JJ).

### A host fixture is absolute on its own host, because a POSIX literal asserts a platform

A `HostConfig` tool table names executables the **outer host** resolves and invokes, and § K requires
every one of them to be an absolute path admitted by one total constructor. A fixture that writes
`/usr/bin/python3` into that table is not stating the contract; it is stating that the developer's host
is POSIX. On Windows the same value is drive-relative and the constructor correctly rejects it, so the
suite reports a broken contract where there is none — while the actual guard, that no bare command name
can be invoked, was never in question.

The split that makes this safe already exists in the architecture: a guest path names a file on a
different machine, reached through one host-provider command, and stays POSIX. Only the host side is a
host path.

*Absence guard:* the suite asserts that no host tool-path fixture bypasses the fixture-path constructor,
and that repo-relative module allow-lists are compared separator-neutrally (§ JJ).

### Outer-host portability is not a substrate, and a static gate is not a substrate gate

Two claims are easy to conflate. "These sources build and self-test on this outer host" is a portability
claim; "these effects ran inside the realized Linux substrate" is a substrate claim. Treating a native
static run as a substrate gate would let a phase claim provider, container, and POSIX-process coverage it
never exercised. Treating outer-host portability as a *substrate* would be the opposite error: every
phase would appear to declare `windows` merely for compiling there, exhausting the one-substrate budget
that exists to keep acceptance obligations legible.

Keeping them apart is what makes § N honest. A binary the plan builds host-native on every substrate is
built from sources that compile and self-test on every supported outer host; a repository whose own
suites only run on POSIX cannot claim that.

A third term is needed to say either sentence without ambiguity. § II's *outer host* pairs a physical
machine with the provider it realizes a hardware context through, because that pairing is what selects a
substrate and what an acceptance phase confirms. But a gate run is evidence about the machine the gate
*process* ran on, whatever created it — which is why the same words could not describe a container run on
macOS: read one way it is Linux evidence, read the other it is macOS evidence, and the plan already
records it both ways in different places. § JJ's *gate host* names the second reading, so provisioning
machinery stops looking like a source of gate hosts: `ensure wsl2` establishes the substrate the project
under test runs in, and a distribution a developer installs to compile on Linux is a development machine
that the plan has no opinion about.

*Absence guard:* the substrate budget check, plus the § JJ rule that a phase whose suites do not hold the
harness rules is `Active` until they do.

---

## Effects, frames, and paths

### A script is a fork of the binary, and it is the fork nothing can check

A `.sh` or `.ps1` file in the tree is host-level logic the binary is supposed to own, written in a
language with no types, no tests, no access to the prepared-operation and authority machinery, and one
copy per platform. Its failure modes are the ones the Haskell surface was built to make unrepresentable:
an unquoted argument, a bare command name resolved against ambient `PATH`, an effect that runs twice
because a retry could not tell whether the first attempt landed. It also splits the operator surface —
some capabilities are verbs and some are files you must know to run — which is exactly what § P's fixed
command tree exists to prevent.

Compiled-in interpreter text is the same fork with the file inlined. A Python program in a string literal
is not more typed for living inside a Haskell module; it still parses its own protocol, still reimplements
the invariants the caller already states, and still has to be read in two languages to be reviewed. Where
it exists because the host capability looked unreachable — locking, descriptor passing, process groups,
no-follow opens, atomic replace — the platform binding was always there, and the host-wall backend proves
it by using it.

The one place the argument does not reach is a frame the binary has not been established in yet, because
§ N forbids copying a binary across hosts and a fresh guest has no toolchain. That bootstrap is small,
ordered, and finite, so it is a closed vocabulary with one owner rather than a licence (§ KK).

*Absence guard:* the tree carries no script file; interpreter-invocation tokens appear only in the guest
bootstrap module; exactly one shell quoter, one process runner, and one crossing renderer exist.

### A provider is a row, not a workflow, because two copies drift where no gate looks

The tempting shape is a module per provider: `Lima.hs`, `Incus.hs`, `Wsl2.hs`, each owning "how this
provider does the lifecycle". It reads well and it is wrong, because almost none of the lifecycle is
per-provider. The guarded destructive delete, the existence probe, the readiness wait, the budget-to-wall
rendering, and the four ownership clauses are one computation each, and writing them once per provider
produces copies that pass their own tests while disagreeing with each other — which is undetectable,
since no gate compares two providers' answers to the same question.

The guarded delete shows the shape of the failure exactly. Three copies each asked whether the name carries
the project's prefix, and each was tested by asking whether a differently-prefixed name refused. None of
them was asked what an **empty** prefix does, under which the guard is a prefix of every name and removes
whatever it is pointed at. One computation can be asked that question once; three copies have to be asked it
three times, by someone who thought to.

What genuinely differs is small and enumerable: the tool that reaches the frame, its argument shape, the
frame's path grammar, its sizing vocabulary, and its ownership primitive. That is a table, and a table has
the property the modules do not: a new provider cannot silently omit a behaviour, because a missing row
entry is a type error rather than an absent file.

WSL2 is where the cost is clearest. A WSL2 distribution is a Linux machine; treating it as a fourth
platform means writing Linux behaviour a fourth time and maintaining it against three others. Treating it
as a Windows-owned frame onto Linux leaves exactly one genuinely new problem — a single utility VM every
distribution shares, so its wall is host-global — which is a real, and realistically sized, module.

*Absence guard:* one crossing renderer; no per-substrate `case` outside the frame table and the detector;
no second implementation of an ownership clause.

### A fake is a symptom of an effect that swallowed a decision

A suite reaches for a stand-in binary when the logic that decides what to do with that binary's output
lives inside a subprocess, and for an injected executor when the classification that follows a command
lives beside the command. In both cases the fake is not the problem; it is the only way left to test a
decision that has nowhere else to be called from.

That is why "remove the fakes" and "lift the logic into pure functions" are one task rather than two.
Once the decision is a total function over a closed sum, the test applies the real function to real
values, and the stand-in has nothing left to stand in for. What remains impure is a short enumerated list
of kernel operations, and those are tested against the real kernel in a temporary directory — because a
fake `open` proves nothing that the real one would not prove more cheaply.

The failure this prevents is specific and quiet. A gate that drives a stand-in proves the stand-in works.
When the real tool changes behaviour, or the real kernel refuses where the fake agreed, every test still
passes and the number at the bottom of the run is unchanged. A seam whose only production instance lives
in an opt-in component has the same shape: the ordinary gate exercises the substitute, and the thing it
claims to cover is covered somewhere nobody runs.

*Absence guard:* no spec writes an executable into a directory it then places on `PATH`; no production
module carries a crash point, a fault token, or an execution override.

### A skipped case is worse than a failing one, because the total does not change

A conditional that changes an *expectation* keeps the evidence: the row is real, the host differs, and the
case still runs. A conditional that removes the case removes the evidence and leaves nothing behind that a
reader could notice — the suite reports a smaller number, and a smaller number looks exactly like a
smaller suite.

This is the most complete form of spoofing available, because it requires no bad faith at all. A module
excluded by a Cabal `os` condition is not compiled, so nothing about it is asserted; a group behind a
platform `#ifdef` is not counted, so its absence is invisible. A gate can report every test passing while
the whole subject of the phase went untested on that family.

Platform rows are therefore compiled everywhere and stubbed to a total refusal where they cannot apply,
and the suite reports what it did not run so the gate can compare that against a declared expectation.
The point is not to run impossible cases; it is to make an unrun case say so.

*Absence guard:* no `if os(...)` module stanza in the package description; the skip manifest matches the
declared per-family expectation.

### A path belongs to the frame that reads it, because derivation says nothing

Asking "is this a host path or a guest path?" by looking at where the string was built gives the wrong
answer often enough to be a trap. A cluster state directory is derived from the canonical project root
with the host's own separator, which looks decisive — and is not, because the path is handed to an
ownership driver running inside the realized Linux substrate, which is the only process that will ever
interpret it. The frame that reads a path is the frame whose grammar admits it.

Getting this backwards is expensive in both directions. Validate a guest path with the host's grammar and
the suite fails on an outer host where nothing is actually wrong. Validate a host path with a POSIX
grammar and it silently passes everywhere the author ran it, failing only on the platform nobody tried —
which is the same defect class § JJ exists to catch, arriving through a door § K did not cover.

*Absence guard:* a path validator's grammar matches the frame its value is declared to belong to, and
fixtures respect the same split (§ MM, § JJ).
