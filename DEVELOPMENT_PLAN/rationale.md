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
shape from returning. Where a guard covers less than the entry argues for, the entry says which part is
enforced.

A bare § letter in this document names a section of
[development_plan_standards.md](development_plan_standards.md). *Substrate*, *frame*, and *cordon* carry
the senses the [glossary](../documents/README.md#glossary) defines, and an entry using a narrower sense
says which. Three further terms recur: a *lane* is one outer-host realization route of § II's table — the
outer host together with the provider that realizes `linux-cpu` on it; a *lift* is the typed crossing
from one frame into a nested one (§ LL); and a *wall* is the resource ceiling a provider enforces for the
plan's budget (§ O).

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

### A GPU is placed, not budgeted

The tempting shape adds a device dimension to `ResourceEnvelope` and to `preflightBudget`/
`preflightHostBudget`, so a run that needs a GPU is refused up front when none is free. Neither half holds.
A budget dimension is something a provider wall enforces, and no wall the providers render — Lima's and
Incus's sizing arguments, the WSL2 `.wslconfig` — carries a device ceiling, so the dimension would be a
budget nothing applies. And a preflight count of devices is an observation taken before scheduling: it
cannot see a GPU another process occupies at the moment the workload starts, so it refuses runs that would
have fit and admits runs that will not.

The budget therefore has exactly three dimensions, CPU, memory, and storage. A GPU request is attached by
the accelerator placement, and an occupied GPU surfaces as that workload's readiness failure, which is
observed at the moment it is true
([the cluster-lifecycle phase](phase-16-cluster-lifecycle-and-cordoning.md), Sprint 16.52).

*Absence guard:* none beyond the type. `ResourceEnvelope` carries exactly the `cpu`, `memory`, and
`storage` fields, so a device dimension is a visible change to a Dhall-facing type rather than a quiet
addition.

### Tests drive the production polling loop

A second polling driver can pass while the loop the binary runs is wrong. Scripted backend observations,
a zero-delay policy, and counted recovery calls exercise `pollUntilReadyWith` itself. Reviewed named
policies use the private validated representation directly; a partial error branch adds no useful runtime
decision to those constants.

*Absence guard:* `ReadinessSpec` rejects the removed test-only driver and partial named-policy builder
as source definitions, while its behavioral cases drive the shipped loop.

### Storage ceilings have one policy

A separate storage-mechanism or unsupported-reason enumeration in each consumer gives one provider
several answers to the same question. Updating a provider's supported wall in one layer can leave another
layer admitting a ceiling it cannot enforce. A capacity preflight cannot resolve that disagreement: free
space is an observation, not a quota.

`Cluster.Cordon.Foundation.storageCordonPolicy` therefore owns the mechanism or unsupported reason for
each storage target. `Cluster.Budget` maps the provider to that target, retains the policy answer, and
renders arguments for the selected mechanism. A Docker node's missing update flag and bare Linux's missing
quota/image-GC wall remain distinct unsupported decisions. This pure answer grants no mutation authority;
the prepared call and backend settlement still own application.

*Absence guards:* `BudgetSpec` compares the actual prepared mechanisms and unsupported refusals with the
canonical policy, including bare Linux's earlier admission refusal. Its all-library source inventory rejects
`StorageWallMechanism` and `StorageWallUnsupported` identifiers, keeping those duplicate vocabularies absent.

### The four ownership clauses do not demand a protected namespace

A natural first formulation of resource ownership is "an OS-protected namespace plus an identity-bound
conditional kernel mutation". **No substrate supplies that.** Under it, alias-backend discovery would
return `Unsupported` on Lima, Incus *and* WSL2 simultaneously, so the typed ownership path would be
unreachable on every provider lane at once and production would be left holding an unowned `ln -s`. A contract no backend can
satisfy is not a strict contract; it is an unimplementable one, and its practical effect is to legitimize
the bypass.

The four **Locked-Origin Identity Ownership** clauses instead demand an OS-released lock, a durable origin
record, identity binding, and identity-conditional release — each of which every substrate can hold with
dependencies already present. One backend then serves every lane: every provider guest is Linux and runs
the project binary the guest bootstrap installed there, and that binary holds the four clauses over the
alias with the guest kernel's own primitives — the protected store's exclusive entry, an origin record in
the host-backed durable target, no-replace publication, binding of the link's own kernel identity, and
release conditional on that identity. The alias therefore closes on WSL2, Lima, and Incus with one
implementation, and no guest interpreter program or discovered locking or identity-reading front end
participates.

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

### Receipt rebinding follows the planned resource

A receipt names the resource key, ownership generation, and acquiring operation. Letting a rebinding
continuation choose an unrelated resource kind or identity turns those verified facts into a new capability
without checking which planned resource it represents. The target's `PlannedResource` therefore supplies
the rebound kind and identity; the public receipt bridge checks its exact runtime key and generation before
delivering the rebound evidence.

The key check is meaningful at the cross-identity bridge. A public same-identity receipt cannot name an
arbitrary different key. A verified durable resource member can carry a different generation of that same
planned resource, so generation mismatch is tested through that genuine ingress. Empty operations are
rejected before receipts exist, at durable-record and journal ingress, rather than checked again on an
unconstructible empty-operation receipt.

*Absence guard:* `ReconcileSpec` pins the absence of `withReboundManagedResourceEvidence` from the
`Reconcile` export list and exercises the planned rebinding and cross-identity receipt bridges. The planned
bridge's phase index remains generic; the [host providers phase](phase-15-host-providers-and-the-lift.md)
owns its phase-specific recovery restriction.

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

Only the provider VM distinguishes the two verbs: `project down` stops it, keeping the guest and its disk,
and `project destroy` deletes it. Its source share (`copy-source`) is retained across `down`, and every
other reversible node releases under both verbs. Kind is the one frame that could be expected to stop, and
it has no reliable stop/restart contract. Modelling a stop it cannot honour produces a cluster that is
neither running nor cleanly absent, so `deploy-kind` deletes the cluster under both verbs.

### Teardown scheduling is two passes, not one

A single depth-first pass re-offers the first failing node forever and starves its siblings. The scheduler
therefore searches twice: first for work not yet attempted, then for failed nodes. A failed node is
attempted once and is never retried within a run; the second pass exists only to detect that a failed node
is all that remains schedulable. The driver stops at that point without re-running the node and returns
every node still outstanding as a non-settled outcome. A permanently failing node therefore keeps its own
parent blocked while unrelated siblings drain, and the run ends with a report of the unsettled nodes rather
than a truncated traversal presented as settled.

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

### Durable record fields preserve exact UTF-8

A durable text field must retain the identity its producer wrote. Char8 narrowing can turn one Unicode
identity into another, while trimming can turn a refused field into an admitted one. Mode's private
field codec therefore encodes UTF-8, decodes it strictly, and preserves every character. Invalid bytes
reach the existing malformed-record refusal instead of a replacement or fallback interpretation.

Field grammar remains separate from transport. Run and invocation-close keys use their bounded ASCII
alphabets; a Mode migration key can carry Unicode without changing on readback. Mode and Session share
one numeric grammar: canonical ASCII unsigned decimal within `Word64`, at most 20 digits before bounded
`Integer` parsing, with a `showWord` round trip. Signs, whitespace, alternate bases, parentheses, leading
zeros other than `0`, and arithmetic wrapping cannot name another generation. Each caller retains its
own positivity check. Session's imported Prepared field transport remains Char8 and is not made UTF-8
by this numeric rule.

*Absence and value guards:* `AuthoritySpec` bounds its source check to the three private field-codec
declarations, rejects Char8 conversion and trimming, and pins their UTF-8 primitives. Its public ingress
cases cover identity and numeric refusal while preserving the affected record. `LifecycleSpec` exercises
existing-bound admission with invalid UTF-8 acknowledgment and migration fields, checks the exact record
keys and unchanged protected image, and independently recovers a legal Unicode migration key unchanged.
The writer's encoding is held by source/primitive evidence; these cases do not claim a public Unicode
writer path or require a new authority producer.

`SessionSpec` separately writes stamped Closing-journal targets and checks exact malformed-number
refusals with the seeded image preserved. Controls for `7` and the maximum `Word64` retain exact values,
while zero is refused by the Closing rule. These journal cases exercise Session's numeric admission;
they do not independently execute fence or gate admission or establish UTF-8 field transport.

### A proof is compared against the plan digest even when the indices match

Phantom type indices alone admit a proof taken over one plan being presented for another whenever the two
share an index. The digest comparison is what makes the pairing a fact rather than a convention.

### Snapshot writers consume canonical plans

A snapshot writer that accepts independently chosen digest text can persist a binding to no represented
plan. The public persistence primitive instead consumes an opaque canonical snapshot and derives its
specification, configuration, plan digest and bytes from that value. Its revision remains explicit.
Configuration digest and canonical bytes form one optional material unit in the protected and verified
carriers; a partial pair has no constructor state. One bounded framed codec writes that unit without an
alternate tab-separated representation or an encoder-only tag.

An absent material unit remains readable in the framed format for compatibility. That readback is a
decoded protected record, not independent authentication of an admitted plan. Indexed admission supplies
the exact plan and compares all canonical bytes and digests. The writer boundary and that semantic join
therefore state different guarantees.

*Absence and value guards:* the authority suite checks the complete library inventory for the absent
free-digest writer and alternate decoder definitions and checks the writer's public export boundary.
The exact sealed export pin holds the same surface. An import of a deleted identifier would fail even
without this boundary, so no such compile-fail fixture stands in for these checks. Runtime cases retain
immutable/idempotent persistence, compare canonical readback projections, refuse ordinary and overflowing
tab-format revisions at their actual keys, and distinguish fresh binding from rebinding. Ordinary revision
`1` establishes format refusal independently of numeric overflow. These controls establish neither
whole-store fresh-root refusal ordering nor the remaining profile-slot admission checks.

---

## Recovery

### Unresolved outcomes are classified explicitly

A recognized phase can still describe an unresolved effect. Treating every decoded constructor as safe
to continue would turn recognition into authority; leaving known outcomes to an unknown-text fallback
would hide an omitted classification arm. Session therefore decodes one private closed vocabulary of
45 names and handles every constructor. Its seven recognized outcome-unknown phases explicitly return
`UnknownDisposition`, while an undecodable spelling reaches that disposition separately. Neither path
grants effect authority.

`Reserved` is continuable before its next backend call, bringing that set to six without asserting that
no earlier effect occurred. The nine-member fenced-retry whitelist stays unchanged; same-identity
ordinary/adopted teardown returns to `Committed`/`AdoptionCommitted`. Observed managed success, repair
target and phase-to success classify as settled with no further effect authority. Classification alone
does not record a commit or mint prior-commit evidence or a receipt.

*Vocabulary guard:* `SessionSpec` states a literal expected class for every name. A shared strict
nullary-data-declaration reader compares the 43 producer rows with the actual
`Reconcile.PersistedJournalPhase` declaration and all 45 rows with private `RecordedPhase`. It reuses
the source blocks and lexer, so comments, strings and another type cannot manufacture coverage, and
missing, ambiguous or unsupported declarations refuse the check. Its semantic fixtures hold that
closed grammar instead of relying on token occurrence. Enum-derived exact decoding and named exhaustive
unresolved arms also receive source review: public `UnknownDisposition` results alone cannot distinguish
successful private decoding from fallback. No testing authority seam is needed for this vocabulary check.

### Recovery runs on a fresh broker generation

Resuming the dead run's generation makes a delayed permit from that run indistinguishable from a live one.
A fresh generation fences the old permits out.

The reopening is not free of writes: it re-records the old run's Harness mode and bound lease under the
fresh generation, and a reopening that then refuses leaves them recorded there. Recovery stays idempotent
because of two facts together. The reopening never writes the records that must survive it — the plan
snapshot and the durable invocation disposition — and no recovery branch reads a retained record's
generation: binding a lease compares generations only for an unbound lease, releasing a mode compares the
mode alone, and a close journal is keyed by its Closing epoch. A second attempt therefore reads the same
state and reaches the same branch. A change that compares generations on a bound lease or a retained mode
breaks that idempotence.

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

### A container closes the lift context

A raw layer list permits a container followed by a VM or another container. Separate readers can then
select different boundaries for dispatch, stdin and the execution frame. Checking one consumer does
not make every other projection agree.

An opaque `VMStack` admits only VM appenders. `vmContext` closes it without a container, while
`inContainer` closes it with one terminal container; neither result can be passed to a VM appender.
The opaque `LiftContext` retains that prefix and optional container as its one representation. Ordinary
`liftLayers` and `liftVMStack` readers expose descriptive state without exporting a record label.
Incoming raw lists pass checked reconstruction before a context exists. Folding, stdin, frame and
delivery consume the retained components, so delivery needs no reparsing or fallback to recover its VM
prefix. These are shape guarantees, not provider readiness or invocation authority.

*Type and absence proofs:* [VMLayerAfterContainer.hs](../core/hostbootstrap-core/test/compile-fail/VMLayerAfterContainer.hs)
first builds a legitimate closed container, then attempts to append a VM.
[RecordUpdateLiftLayers.hs](../core/hostbootstrap-core/test/compile-fail/RecordUpdateLiftLayers.hs)
uses the in-scope ordinary getter as a record label;
the actual earlier record module permits that same fixture, while the closed API refuses it.
[ForgeVMStack.hs](../core/hostbootstrap-core/test/compile-fail/ForgeVMStack.hs) names the real private
constructor with a well-typed container layer.
[ForgeLiftContext.hs](../core/hostbootstrap-core/test/compile-fail/ForgeLiftContext.hs) supplies a valid
VM stack and optional container to the real private context constructor; exposing only that constructor
makes the unchanged fixture compile, identifying privacy as its rejection. Public compiler
checks, exact exports in both facades, and ordinary-reader controls hold these boundaries. Closed-value
tests retain layer order, record-style Show, frame, stdin and delivery behavior; they make no live
provider-execution claim.

### VM crossings share one placement renderer

Working directory, non-interactivity and elevation describe where a command runs; they do not define
a second transport. One `VMPlacement` feeds each provider's renderer for both ordinary and lifecycle
leaves, and one inner fold applies it at every VM layer. Every WSL crossing uses `--exec` so the
requested command vector reaches the guest without default-shell parsing.

The placement fields remain independent. Lima and WSL emit the whole sudo prefix only when elevated,
with `-n` only when also non-interactive; Incus already runs as root. Ordinary Lima enables elevation
to preserve its `sudo -H` behavior, while a direct renderer call with `foldPlacement` does not.
Lifecycle placement requests `/`, non-interactivity and elevation. Sharing its renderer does not
merge the authenticated lifecycle authority channel with ordinary command execution.

*Absence and value guards:* `LiftSpec` rejects `insideLifecycleVM` and placement argument literals in
the generic Lift module. Independent literal vectors in
`LiftContextSpec` cover every combination of the three placement fields and preserve the ordinary
wrappers. Lift cases cover single and nested lifecycle crossings and unchanged metacharacter arguments.
These pure and source controls establish no live provider execution.

### Reverse routes are reconstructed from retained plan edges

A prepared reverse descent retains the exact parent, child, subtree and verb admitted by its rooted
catalog. Its launch route comes from the retained topology edges, collected from the root in plan
order. Checking each fragment separately does not establish the shape of their concatenation, so
checked reconstruction consumes the complete collected list before a context reaches its continuation.
Graph refusals remain primary; an invalid complete shape is a descriptive route refusal. A partial
route or a local fallback would launch different work from the retained edge.

Catalog admission already checks each immediate child context and forbids descent from a container.
The private prepared package therefore cannot lawfully contain a malformed terminal route. Creating
an authority producer solely to manufacture such a test input would weaken the boundary the test is
meant to hold. Public checked-constructor negatives establish shape refusal, while the public recursive
CLI fixture observes real composed crossing arguments and child-first reverse work on its supported
native guest row. Its Windows refusal branch makes no guest-execution claim.

*Absence and flow guards:* the scoped TeardownSpec collector control rejects raw context construction
and a replacement local route, and links complete collection, checked reconstruction and its returned
context. Existing package-privacy controls retain the prepared-descent boundary. RecursiveLifecycleSpec
observes the existing public route rather than a synthetic private producer.

### Container configuration is copied before its entry point starts

The image owns its entry point. Configuration delivery describes a filesystem projection, so an
interpreter that writes a file and selects an executable would introduce a second launch authority.
Native Docker operations express the actual dependency: create the stopped container, copy one regular
ustar entry, then start attached. Every operation crosses the same VM prefix through the existing lift
and resolved-tool boundary. A descriptor that can represent only one command refuses this workflow.

Delivery retains only its write path and projection payload. Canonical binding records that destination
and the payload digest, so changing either changes the binding without recording the raw projection.
This two-field record belongs to canonical snapshot format 8. The versioned parser refuses format 7
rather than interpreting a different record shape under the same version. Tests recover an actual
persisted delivering plan and refuse rehashed incompatible shapes before yielding evidence.

The archive contains the explicit supplied input. UTF-8 byte lengths, checksum, block padding and trailer
belong to the archive encoder; the existing binary pipe preserves them through UTF-8 encoding. Creation
and start receive no projection input. The destination directory must exist, and the container ID must
be admitted before it can name a dependent operation.

Once a usable ID exists, copy/start failure attempts removal only under the requested remove policy.
The original failure remains primary even when cleanup refuses; an auto-removed container can also
refuse removal. An exception propagates unchanged after the applicable attempt. No usable creation ID
means no identity on which this workflow can promise cleanup.

*Absence and flow guards:* `LiftSpec` inspects actual runner commands and stdin, independently checks
archive bytes, and holds ordering, failure propagation, VM crossings and cleanup attempts. Its source
check rejects the config-writing interpreter and override. The exact export inventory pins the actual
public surface. These static controls establish neither live extraction nor the absence of a container.

### The install is a hard link with no replace, never a symbolic link

The inspector that verifies an installed sibling refuses a symbolic link, so a symlink install is
unreachable on every platform *and* leaves a dangling destination behind when it fails. The primitive the
operation needs is create-if-absent hard link.

### Tokens never travel through Dhall, `argv`, or the environment

A *token* here is the one-time authority grant core mints for one handoff, bound to the exact scope, plan
revision, broker generation, edge, payload and config digests, verb, and phase (§ Y). Dhall is durable
configuration that outlives the run. `argv` and the environment are readable by other processes running
as the same user — through `/proc/<pid>/cmdline` and `/proc/<pid>/environ` on Linux, or through container
inspection — and are routinely captured in process listings, logs, and crash dumps. A one-time grant that
leaks before it is consumed is not one-time, so tokens travel only on the private process channel.

The rule covers core-minted grants, not forwarded operator credentials. A registry credential is the
operator's standing login rather than a grant core mints or can make one-time. Its forwarding keeps the
value out of constructed `argv`, Dhall, and image layers, but a project container receives it through its
environment until the in-container binary consumes it;
[registry_credentials.md](../documents/engineering/registry_credentials.md) states that exposure and the
limits of its cleanup.

### Core owns no default config values and no fixed config type

A default is a decision made on behalf of a project that core cannot validate. Every project-owned value
arrives through the project's own codec, so a missing value is a refusal rather than a silent core default.

### Secret references are scope-indexed

If one secret type serves both scopes, a test-only plaintext value is representable in production
configuration and is excluded only by consumer policy. Indexing the type by scope makes it
*unrepresentable*, which is a stronger guarantee than a policy anyone can forget.

The Harness authority's nominal project and run indices bind fixture plaintext to its run. Copying a
descriptive run name into each plaintext reference adds a second value that no reader needs. The narrow
config authority is an opaque token; the root authority retains the descriptive name. Plaintext
construction evaluates the supplied token before returning a reference.

*Absence guard:* `SchemaSpec` inventories library definitions and rejects `harnessConfigRunName`;
the two authority run-coercion fixtures reject re-indexing without a constructor.

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

### `fourmolu` and `hlint` are not a leg of the host static gate

The style contract is committed — `fourmolu.yaml` and `.hlint.yaml` at the repository root — so the style
is a property of the repository rather than of whichever tool version happens to be installed. Neither
tool's version is pinned: the rolling base installs the current compatible release, and a host carries
whatever its maintainer installed. The two tools therefore run where a maintainer or a build has provided
them: the repository's own source gate (`base build` and `base build-and-push`) runs both on the host,
against the committed configuration, before any Cabal leg; and a derived project runs them through its
in-container `check-code` during its image build.

They are not a leg of the host static gate (§ JJ), which must pass on every supported outer host with only
the toolchain the plan pins. The host static gate is therefore not the complete quality gate — a fact
worth stating rather than assuming away. [code_check_doctrine.md](../documents/engineering/code_check_doctrine.md)
is the canonical home for where each tool runs.

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

*Substrate* in this entry means the plan's hardware-context declaration — the `**Substrates**:` header
field (§ II) — not the detected outer host that `SubstrateName` classifies. Two claims are easy to
conflate. "These sources build and self-test on this outer host" is a portability claim; "these effects ran
inside the `linux-cpu` realization" — the native Linux container path, the Lima/Colima VM, or the WSL2 VM
of § II's table — is a substrate claim. Treating a native
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
macOS: read one way it is Linux evidence, read the other it is macOS evidence, and without a separate term
the plan would record it both ways in different places. § JJ's *gate host* names the reading gate
evidence uses: the OS family, architecture, and toolchain of the gate process, so a Linux container on a
Mac is a Linux gate host. Provisioning machinery is not a source of gate hosts: `ensure wsl2`, `ensure
lima`, and the provider reconcilers establish the substrate the project under test runs in, while a WSL2
distribution a developer installs to compile on Linux is a Linux gate host like any other, and how it was
obtained is outside the plan.

*Absence guard:* the substrate budget check, plus the § JJ rule that a phase whose suites do not hold the
harness rules is `Active` until they do.

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

*Absence guard:* `PortabilitySpec` holds that no spec sets or unsets the suite process's own `PATH`, and
that no production module names a transaction crash point. Neither guard covers a fault token or an
execution override, which § NN also excludes from evidence, and the tree carries one execution override:
the Colima toolchain resolver consults a thread-local fixture override before running the real resolver
([the cluster-lifecycle phase](phase-16-cluster-lifecycle-and-cordoning.md), Sprint 16.20). Only a
Cabal-private test component can install it, but it sits in the operator binary's link path, which is the
shape this entry argues against, and no guard names it.

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

*Absence guard:* `PortabilitySpec` holds that no host `os`/`arch` condition in the package description
decides which modules are built (only `build-depends` may be host-conditional); `CoverageManifest` checks
each conditional family's case count against its declared size on every gate host.

### The warning policy belongs to the package, not to the caller

A warning policy supplied as a command-line flag is a policy each caller must remember, and it is weakest
exactly when someone is in a hurry: a plain `cabal build` without the flag accepts what the gate refuses,
and a warning lands unnoticed. Declared in the `common warnings` stanza every component imports, `-Werror`
and `-Wpartial-fields` make a plain build refuse what the gate refuses (§ R). A per-module options pragma
is the same weakening scoped smaller and therefore harder to see.

*Absence guard:* `PortabilitySpec` holds that the `common warnings` stanza carries the required warning
flags and that no production module carries a GHC options pragma.

### A gate prefers the in-tree command, because a covers digest cannot see the program that ran

A `**Gate evidence**` row's digest measures repository bytes under the `**Evidence covers**` paths and
nothing else. A gate driven through a separately installed program — a pipx-installed `hostbootstrap` that
predates the tree, for example — exercises a program the source no longer describes, yet records the same
digest over the same tree as a run of the current source would. The evidence then certifies source the run
never executed, and no later check can tell the two apart.

A gate leg invoking `cabal` or `poetry` against the tree is guaranteed to exercise the source the digest
measures, so a gate prefers it (§ G). Because the repository ships two programs named `hostbootstrap` — the
Python bootstrapper and the bare core executable — a row that names one says which.

*Absence guard:* partial. `checkGateEvidenceLegs` holds that each `**Gate**` leg's tokens appear in a
recorded command; nothing reads which program the command invoked, so the in-tree preference is a rule
rather than a check.

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

*Absence guard:* `EffectSpec` holds that the tree carries no script file, by extension or by `#!` header,
and that the shell quoter, the PowerShell quoter, the process runner (within its declared launch
boundaries), and the effect interpreter each have exactly one definition site; exact-argument cases in
`ProviderSpec`, `LiftSpec`, and `RegistrySpec` pin the crossing shapes. § KK's further requirement, that
interpreter-invocation tokens appear only in the guest bootstrap module, has no guard and does not hold:
production modules outside that module still compose `sh -c` and `bash -lc` programs — the registry
credential lift and programs in the provider backend. § KK is owned by the
[host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md).

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

### A provider builder has a production consumer

An exported argument builder expresses an operation the lifecycle actually selects. An argv fixture
alone proves only that an unused function can produce a list; exports, signatures, and equations do
not prove a production call. A provider row carries no builder solely for that fixture.

WSL stop releases the host-global resource wall and shuts down the shared utility VM. Per-distribution
termination cannot establish that postcondition, so `wslTerminateArgs` has no lifecycle role.

*Absence guard:* `test_provider_surface_has_one_dispatch_and_no_definition_only_builders` counts
expression uses and refuses the unused termination builder.

### A path belongs to the frame that reads it, because derivation says nothing

Asking "is this a host path or a guest path?" by looking at where the string was built gives the wrong
answer often enough to be a trap. A cluster state directory is derived from the canonical project root
with the host's own separator, which looks decisive — and is not, because the path is handed to an
ownership driver running inside the `linux-cpu` realization (the provider guest or container), which is
the only process that will ever
interpret it. The frame that reads a path is the frame whose grammar admits it.

Getting this backwards is expensive in both directions. Validate a guest path with the host's grammar and
the suite fails on an outer host where nothing is actually wrong. Validate a host path with a POSIX
grammar and it silently passes everywhere the author ran it, failing only on the platform nobody tried —
which is the same defect class § JJ exists to catch, arriving through a door § K did not cover.

*Absence guard:* a path validator's grammar matches the frame its value is declared to belong to, and
fixtures respect the same split (§ MM, § JJ).

### A service handler returns a closed effect-indexed program

An opaque role-parameter input does not bound an `IO ()` result. `ProgramServiceHandler` therefore returns
`ServiceProgram payload service effects ()`; the registry retains the declared row and matching payload
backend in the same existential package. Signed admission validates that row and Ready supplies acquired
handles. An unrestricted handler constructor or IO-returning selector would bypass this boundary.
`IOServiceHandler.hs`, the registry ownership guard, and `DocValidatorSpec` reject those shapes.

### Init publishes complete config bytes

An existence check before a write cannot decide an existing-output policy: another writer can take the
name between the check and publication. Refuse and keep therefore publish a flushed temporary through a
create-if-absent hard link; overwrite publishes through a same-directory atomic rename. A reader sees a
complete file, and a refusing or keeping writer never replaces a peer's bytes. Writing the destination in
place would expose truncation or partial output.

Identity provisioning follows publication and has its own failure outcome. A published config remains
available after provisioning fails, and an init rerun with the keep policy completes provisioning.

*Absence guard:* the scoped publisher's complete definition contains no `BS.writeFile`; schema publication
tests pin concurrent refusal, exact winner bytes, all three policies, and temporary cleanup.

## WSL readiness comes from platform status

A platform readiness probe observes the installed platform. WSL's `--status` reports the local
platform's condition; a no-installed-distributions diagnostic still identifies an installed platform.
Virtualization-disabled diagnostics take precedence over an exit-success code or a distribution
message, so the status classifier reads normalized stdout and stderr together.

The online distribution catalogue observes a separate network service. Its availability can change
while the local platform stays ready, and a reachable catalogue does not establish the platform's
virtualization capabilities. The readiness path therefore uses one local status response. Native
prerequisite observations and remediation remain a separate decision over that status.

*Absence guard:* `EnsureSpec` pins the complete `wsl2Ready` definition's one status observation and
rejects the removed `wsl2OnlineListReady` helper and online catalogue argv. Its classifier cases pin
diagnostic precedence and the installed-platform meaning of a no-distributions report.

## WSL prerequisites use native machine observations

Prerequisite decisions consume machine observations through native bindings. A text-producing
interpreter adds executable discovery, process startup, output decoding, and a textual protocol to a
boolean observation. The native boundary reports the value it can observe, or an explicit unsupported
result when the platform or architecture cannot supply it.

Hypervisor presence takes precedence over the firmware feature report. Windows's firmware feature
reports virtualization enabled and available to the operating system; a zero result can also mean the
HAL cannot detect availability. It is not a direct, infallible reading of a BIOS switch. A running
hypervisor therefore makes that flag irrelevant to installation, while an unavailable report without a
hypervisor produces a refusal asking the operator to check BIOS/UEFI and host configuration. See the
[Windows processor-feature contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-isprocessorfeaturepresent).

Successful reconciliation includes the requested default version. The shared install driver may see
readiness change between its caller's observation and its own probe and legitimately skip installing.
Its completion therefore refreshes tool resolution and uses the same default-version action as the
direct-ready path. This also supplies the installed WSL executable when the caller's original host
configuration predates installation.

*Absence guard:* `EnsureSpec` rejects the removed PowerShell probe helpers, the PowerShell tool token,
and `-Command` in `Ensure.Wsl2`. Its complete decision table and production-used ready argv hold the
replacement behavior; a structural guard pins refresh and the common setter after install completion.
`PortabilitySpec` requires the native C source to be registered for every build;
platform guards inside that source provide the supported observation or its explicit refusal.

## Incus convergence observes gaps before executing argv

A host provider daemon is shared with other project operations. Its installer observes actionable
capability and root-daemon gaps before selecting package, initialization, and restart work. Client
installation establishes the executable; daemon initialization belongs to the observed convergence
plan. A usable provider therefore has no package or restart action, and two gaps share one restart.
The admitted absolute Incus path stays bound to the probe and initialization, while installed tools
are re-resolved before later work.

Capability is architectural: QEMU, firmware, and virtiofsd must match the Linux host. Grouped argv
preserves the conjunction between capabilities and the alternatives within firmware or daemon paths.
A configured virtiofsd path is observed as executable too, because a retained resolver entry can outlive
the file. Typed PATH discovery has one owner in the host-tool catalog.

Host setup also depends on each command's result. An absent Docker forwarding chain skips its rules;
a failed rule check alone permits insertion. A module-load exit cannot prove the KVM device exists,
so the ordered attempts each recheck the device. Argument vectors and Haskell control flow retain these
observations without interpreter programs that swallow failures or merge steps.

*Absence and flow guards:* `EnsureSpec` rejects the three removed interpreter programs and pins
architecture-specific argv, observation-driven convergence, refresh, chain-missing skip, and per-attempt
KVM rechecks in the real definitions. `HostToolSpec` pins typed virtiofsd discovery and resolution.
Descriptive convergence facts select setup work; capability admission performs its own configured
observation.


## Incus capability admission performs its own observation

A descriptive status reports facts; it does not establish authority to mint a provider capability.
Even a Ready status returned by the pure classifier describes only its supplied observations. The
capability gate therefore accepts host configuration and runs the configured provider probe itself,
then consumes the descriptive result before minting the existing opaque capability. There is no
public status-to-capability path. Hiding the Ready constructor makes the public status vocabulary
clearer, while the gate's internal observation supplies the actual admission boundary.

The six non-ready statuses remain public so callers can report actionable failures. The descriptive
eliminator preserves their exact refusal text and reads a classifier-derived Ready as success without
creating authority. Daemon permission failure precedes VM and egress failures, and VM failure precedes
egress. The opt-in live harness consumes this same descriptive result for its read-only preflight.

The observation uses the caller-configured tool paths. Admission does not authenticate executable
contents or promise that a daemon remains ready indefinitely. It admits the scoped continuation from
the configured probe's current result, with no callback admitted on refusal.

*Constructor and flow guards:* independent public-only compile-fail fixtures reject the opaque
capability constructor and Ready constructor for their own diagnostics. `EnsureSpec` pins all six
literal refusals, a classifier-derived Ready control, failure precedence, and the actual empty-tool
configuration gate's refusal. Its callback test executes any admitted action before checking that no
callback ran. A balanced-definition guard links the real configured probe, descriptive eliminator,
and sole mint, and requires the reconciler to pass configuration to that gate directly.


## NVIDIA repository publication follows validated fetches

Fetching repository inputs and publishing them under system directories have different failure
boundaries. Both downloads must succeed and their bytes must be read and accepted before a privileged
publication command runs. Owned scratch storage keeps incomplete or refused inputs away from both
destinations and is cleaned after success, ordinary IO refusal, or asynchronous interruption.

A repository list is data, including its literal `$(ARCH)` marker. Haskell rewrites every supported
active HTTPS entry with the fixed signed-by keyring and preserves comments, blank lines, and final
newline behavior. An unsupported active entry refuses rather than remaining unsigned. Strict UTF-8
handling and rejection of absent or empty downloads keep decoding and missing-file failures before
publication too. This boundary does not promise atomic publication of both destination files or
rollback after a privileged command has started, and it does not establish the remote key's trust chain.

The runtime workflow consumes real bootstrap-tool and toolkit-tail command lists around an explicit
scratch stage. A static command vocabulary cannot represent a Haskell rewrite by pretending an
executable performs it. The resolved runner therefore receives only actual Curl and Sudo argument
vectors; the reconciler observes complete satisfaction before doing setup and refreshes installed tools
before using them. Its final nvkind smoke establishes default runtime and volume-mount GPU visibility;
CDI is configured separately and is not proved by that smoke.

*Absence and flow guards:* `EnsureSpec` rejects the removed repository interpreter program and pins
the real bootstrap, fetch, publication, and runtime-tail argv. The production-used scratch workflow's
recording runner supplies bytes only to its requested download paths and checks fetch/content refusal
before any publication, exact successful ordering, and cleanup. Pure list cases pin supported and
refused input bytes. A balanced-definition guard connects the no-op, tool refresh, scratch stage, tail,
and verification. These static controls make no live repository, GPU, or CDI acceptance claim.


## Docker future-login checks observe group and socket permissions

A newly granted group belongs to the user's account database before it belongs to the current
process. `id -nG <user>` observes that future-login membership directly. Haskell compares whole group
names against the actual Docker socket's owning group and requires its group-write bit; a substring,
a different owning group, or missing write permission cannot establish that access route.

The result-producing runner retains exit status and stdout. The shared checked-step callback returns
only completion and cannot supply this observation. Command and socket-metadata failures therefore
refuse explicitly before the existing current-session ACL path. Native POSIX metadata supplies the
group and mode, while native Windows reports an unsupported observation. Ordinary IO failures refuse;
this read-only verification does not mint authority or change host users or socket state.

The reconciler retains its existing group grant before verification. Current-session direct Docker
and ACL work follows successful verification. The check describes group-based socket permissions; it neither executes a
future login nor independently proves daemon connectivity. The Linux package plan refreshes apt
before installation. Every command is an argument vector, with no `sg` interpreter program.

*Absence and flow guards:* `EnsureSpec` pins whole-token and actual-group decisions, the group-write
bit, command and metadata refusals, and the exact `id -nG` observation order through the production-used
verifier. A balanced caller guard links refusal before the real ACL continuation and preserves the
existing direct-info and ACL path. Metadata-source guards pin native group/mode observation and the
explicit Windows refusal. The named absence guard rejects `sg` and interpreter argv, and the Linux
plan case pins apt update before installation. Portable fixture observations make no live-login or
host-permission mutation claim.


## Guest bootstrap steps come from admitted targets

Path admission must survive storage and observation. An opaque GuestPath retains the original spelling
of a POSIX-absolute guest path; target and step payloads carry that proof until argument rendering.
Common path admission precedes role labeling. The target receives six admitted purpose roles and
checks the toolchain pin before the toolchain home, preserving argument bytes and the frame that
interprets each coordinate.

A hidden target constructor alone does not close construction when exported record selectors still
permit updates. Private labels and ordinary readers prevent a caller from replacing an admitted field
outside the factory. Hidden step constructors likewise ensure the public vocabulary's steps come
from an admitted target's plan. The provided driver fixes their order; callers retain descriptive
kind, label, probe, and action readers without unchecked payload construction.

A common GuestPath establishes path validity, not coordinate identity. Six distinct purpose roles
separate the source, project, toolchain, bootstrapper, built-binary and installed-binary coordinates.
Each role is stored in the target and matching step payloads and adopted at the actual demo caller,
with its underlying path eliminated only for predicates or rendering. No raw factory path slot remains.
Toolchain-pin and `.ghcup` target checks retain their order, and presentation remains compatible. A role
labels a planned coordinate; runtime probes observe the properties each step declares.

*Constructor and reader guards:* public-only RepointGuestBootstrapTarget and ForgeGuestBootstrapStep
fixtures use admitted, correctly typed payloads and reject the actual selector or constructor access.
Their payload types match the current signatures so an unrelated type error cannot mask leakage.
The exact export inventory is registered in the real supplemental discovery list and keeps path,
target, and step constructors opaque. GuestBootstrapSpec checks ordinary reader definitions, path
admission, presentation, and the existing complete argument vectors and driver journals. Role controls
pin each coordinate's intended rendering positions; the final binary-role fixture rejects direct
transposition. Static validation makes no claim of bootstrapping a live guest.
