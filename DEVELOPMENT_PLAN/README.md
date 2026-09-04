# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[rationale.md](rationale.md)

> **Purpose**: Name the phases in execution order and carry the single cross-phase status table.

## How to read this plan

The plan is a **build recipe**. Phases 0 through 28 construct `hostbootstrap` from nothing, and the numbers
*are* the order: at phase *n* only the artifacts of phases ≤ *n* exist. Nothing later contradicts or reverses
anything earlier, so following the numbers in order and validating each phase as you go is the supported way
to develop the project.

`linux-cpu` is the universal baseline substrate, not a requirement that the outer host be Linux and not the
only context an application may target. `hostbootstrap` lifts an arbitrary application into its declared
hardware context: native
Linux realizes it directly, Apple Silicon through Lima/Colima, and Windows through WSL2. The host-native
bootstrap selects and owns that realization, then runs project work and baseline gates inside the resulting
Linux/container environment. A selected Metal, NVIDIA, or Windows CUDA context adds genuine typed
capabilities and placement beyond that floor. Phases 0–24 and 28 close on the invariant or on pure-static
gates. Phases 25–27 are **acceptance phases** for Apple/Metal, NVIDIA-accelerated, and Windows/WSL2/CUDA
contexts: each confirms the universal floor through its provider and the behavior unique to that context.
Nothing depends on those additional acceptance dimensions.

[development_plan_standards.md](development_plan_standards.md) § A states the doctrine and § II the substrate
rule. [rationale.md](rationale.md) explains why the architecture has the shape these phases build, including
the shapes it deliberately does not have.

## Current Phase Status

This table is the **sole cross-phase status source of truth**. Each phase file's own `**Status**` must match
its row here.

| # | Phase | Status | Substrate | Open |
|---|-------|--------|-----------|------|
| 0 | [Governance and documentation standards](phase-0-governance-and-documentation-standards.md) | Done | — | — |
| 1 | [Python pre-binary floor](phase-1-python-pre-binary-floor.md) | Done | linux-cpu | — |
| 2 | [Haskell core scaffolding](phase-2-haskell-core-scaffolding.md) | Done | — | — |
| 3 | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) | Done | linux-cpu | — |
| 4 | [Protected store](phase-4-protected-store.md) | Done | linux-cpu | — |
| 5 | [Installed identity, operator verification, and authority kernels](phase-5-installed-identity-and-authority-kernels.md) | Done | — | — |
| 6 | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) | Done | — | — |
| 7 | [Dhall configuration and the generic project model](phase-7-dhall-configuration-and-project-model.md) | Done | — | — |
| 8 | [Ensure reconcilers](phase-8-ensure-reconcilers.md) | Done | linux-cpu | — |
| 9 | [Lifecycle modes and run leases](phase-9-lifecycle-modes-and-run-leases.md) | Done | linux-cpu | — |
| 10 | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md) | Done | linux-cpu | — |
| 11 | [Prepared operations](phase-11-prepared-operations.md) | Done | linux-cpu | — |
| 12 | [Step algebra and the project plan](phase-12-step-algebra-and-project-plan.md) | Done | linux-cpu | — |
| 13 | [Authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) | Done | linux-cpu | — |
| 14 | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) | Done | linux-cpu | — |
| 15 | [Host providers and the lift](phase-15-host-providers-and-the-lift.md) | Done | linux-cpu | — |
| 16 | [Cluster lifecycle, budgets, and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) | Done | linux-cpu | — |
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Done | linux-cpu | — |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Done | linux-cpu | — |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Done | linux-cpu | — |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Done | linux-cpu | — |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Done | linux-cpu | — |
| 22 | [Service runtime](phase-22-service-runtime.md) | Done | linux-cpu | — |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Done | linux-cpu | — |
| 24 | [The worked demo](phase-24-worked-demo.md) | Done | linux-cpu | — |
| 25 | [Apple Silicon substrate](phase-25-apple-silicon-substrate.md) | Done | **apple-silicon** | — |
| 26 | [NVIDIA GPU substrate](phase-26-nvidia-gpu-substrate.md) | Done | **nvidia** | — |
| 27 | [Windows and WSL2 substrate](phase-27-windows-and-wsl2-substrate.md) | Active | **windows** | 27.3 recovery and acceptance re-run |
| 28 | [Host-portability acceptance](phase-28-host-portability-acceptance.md) | Planned | — | 28.1 Windows warning-clean build and run; 28.2–28.3 macOS and Linux runs |
| 29 | [Documentation reconciliation](phase-29-documentation-reconciliation.md) | Planned | — | all |

## The current frontier

The lowest-numbered open phase is **27**, the Windows and WSL2 substrate. Phase 26's native Linux/NVIDIA
acceptance is complete: the pristine Direct/nvkind Harness matrix reported `10/10 passed` in about 42 minutes
across four fresh cluster generations, honoured an exact one-GPU request on an RTX 5090, proved same-run durable
recreation through retained-record teardown, and left no managed runtime or active Harness ownership behind.
Phase 25's Apple Silicon acceptance is also complete: its pristine Apple/Lima Harness matrix reported `10/10
passed` in about 79 minutes across four
fresh guest generations, root-signed post-handoff Metal activation, far-frame relay observation, same-run
durable recreate, and terminal cleanup. Its focused native direct-Colima lane derived and cleaned one
isolated exact-plan profile, refused an incompatible same-plan wall, left the shared `default` profile
unactivated and unchanged, and left no isolated namespace behind. Kind stages its initial kubeconfig
platform-locally and publishes the exact readback before node binding, while recursive lifecycle entry refuses
a retained reverse failure without selecting it again. Far-frame exposure is re-observed through the exact
provider frame.

The 2026-09-04 Windows acceptance attempt passed all five `hello-world` cases and observed the real Windows
accelerator daemon, distro destroy, global-wall release, and `.wslconfig` restoration. Its `hello-universe`
bring-up failed while Docker extracted a freshly pulled published-base layer whose gzip CRC32 was corrupt; the
run reported `5/11 passed`, five `BROKEN` cases, and one `LEAKED?` teardown row with retained reverse work. A
durable retry exited 1 immediately after `Up to date` without an acceptance report. Phase 27 therefore remains
active at recovery of that retained lifecycle state followed by a pristine durable `10/10` rerun and end-state
audit; the failed run is not completion evidence.

Phase 24's host-resident accelerator reopens the exact owned provider frame and re-observes the recorded relay
there; no cluster live package is expected to survive child-frame closure. The warning-clean core graph passes
2,478/2,478. Host publication is an owned runtime
relay, concrete clients consume only resolved exposures, the pristine guest consumes the closed bootstrap
vocabulary, and its durable alias is a shipped ownership-row transaction with identity-conditional destroy.
The service-runtime
phase is closed with an activation-only, measured, effect-indexed `service run`. § KK's invocation half is closed — the
[host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md) carries one
quoter, one process runner, one closed command vocabulary, and one interpreter for it — and the
[ensure-reconcilers phase](phase-8-ensure-reconcilers.md) closed the guest bootstrap vocabulary and § LL's
re-cut of reconcilers as frame rows, so `HostFrame` is the closed three-constructor frame axis every
routing fact derives from. The
[Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) is closed with § JJ's fifth rule:
every platform row is now compiled on every gate host and stubbed to a total refusal where it cannot
apply, the package description decides no module by host, and `CoverageManifest` declares each
host-conditional family's size so a case that vanished is a failed count rather than a smaller total.

That the frontier advanced beyond 3 is the result of settling **who owns which half of § K**. The
`HostTool` boundary — that the set is closed, that entry is by construction, that resolution is absolute
— is the host-tools phase's, and it is built. *Which* tools are in the set is a description of what the
binary drives, so it is settled by the phases that drive them; the enumeration narrows when the last
driver stops driving a name, and that driver is the
[cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md)'s. Written
the other way round, the fourth phase of thirty waited on the sixteenth, which is the claim § A forbids
outright — and which nothing checked, because a `Depends on` field never sees a sentence.

The **ownership seam** is now built and consumed. § EE's four clauses are one transaction, and the
[four-ownership-clauses phase](phase-14-ownership-clauses-and-reservations.md) writes it once: one closed
seam of kernel primitives, two platform rows filling it, one selector between them, four abstract clause
tokens whose order is a property of the types, and a producer that makes clause 4 reachable from the
durable record so a release in a later entry is still inside the clause order. All three **host-local**
owners consume it — the run's data root, its generated sibling config, and the per-user host wall — so
the identity read, the no-replace link, the exclusive open, the identity-conditional act, and the durable
record encoding each exist once beneath every one of them, and the injected object-identity seam and the
wall's own platform backends are gone. The host wall's clause 1 and clause 2 are now the same protected
entry and compare-and-swap the other two hold, so it carries no lock, journal, or fence file of its own.

The **shipped row** is built with it. A transaction addressed to a lift context is carried to a process of
this same binary at that context and interpreted there, over the crossing the authenticated-handoff
boundary already owned: one opaque transaction out, one opaque outcome back, a private protocol channel,
and a process group ended on every exit path. The receiving process holds the protected store's exclusive
entry for exactly its own lifetime, so clause 1 stays a kernel fact, and the frame table now carries the
ownership column that says which row holds a frame's clauses.

The seam's **adoption by the drivers** is complete. The provider's provisioning, readiness,
share, stop, delete, and guest-execution transactions are now Haskell operations over the protected
store, described commands, and total classifiers, and the 27KB interpreter program, the Direct
permission program, and the locking front end they ran under are deleted. Cluster and Colima use the same
clause seam locally; the guest alias ships its closed symbolic-link transaction to the binary established in
that frame. Phase 13 supplies the entry a frame crossing needs: one total pure classifier
over `argv`, consulted once before the parser, and one bracketed near side that folds a lift context into
the invocation that crosses the frames, carries one transaction over, reads one answer, and ends the
child group.

Nothing checked it because nothing could. The `Depends on` field is clean for all thirty phases and always
was; the coupling lived in prose. The
[governance-and-documentation-standards phase](phase-0-governance-and-documentation-standards.md) now
carries the checks that read it: no `Remaining Work` section cites a later phase, an `Active` phase carries
one non-empty `## Remaining Work`, a `Done` sprint's begins "None.", every ledger row names exactly one
deleting phase, and every contract opens with the phase that owns it. Each is scoped so a legitimate scope
statement stays legal, and each has a fixture proving both that it fires and that its scoping holds.

§ NN's evidence contract is the second thread. Phase 2 owns the contract and the guards for the harness's
own shapes; a guard against a shape in *production* belongs to the phase whose work removes it (§ I).
Phase 10 has taken the first of those: the redo coordinator carries no crash point, because the durable
state an interruption leaves is a value a fixture writes through the store, after which the recovery
driver under test needs no cooperation from the code under test. Phase 14 has taken the second: the host wall's crash-resume branches are entered by
writing the durable state an interruption leaves — a value — through the wall's own protected store, so
the driver carries no crash point and no injected seam, and the injected object-identity seam is deleted.
Phase 15 has taken the third: the provider backend holds no execution seam, a source guard says so, and
the outcome-unknown window between clause 2 and clause 3 is reached by a provider client that really
performs its launch and really dies rather than by a patch point. Phases 16 and 24 apply the same rule to
cluster, Colima, and guest-alias recovery: fixtures write the durable boundary state and production carries
no patchable crash-point marker.

On 2026-08-17 the complete host static gate passed host-native on Windows 11 Home 10.0.26200 x86_64 with
GHC 9.12.4 and Cabal 3.16.1.0: `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`
at 1,922/1,922 in 234.62 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. On 2026-08-18 the same gate passed
host-native on an x86_64 Linux gate host with the same toolchain at 2,174/2,174 in 220.73 seconds, plus
both Python commands with 231 passed — the first family on which the grouped-teardown and POSIX
ownership-row cases execute rather than record a refusal, the run that closed phase 14 with all three
host-local owners on the one seam, and the run that first carried an ownership transaction across a real
process boundary. Confirming the same gate on a macOS and a
Linux gate host is the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md)'s, because that claim needs
three machines and § C forbids a baseline phase owing hardware it does not declare.

## The effect vocabulary and the frame table

§ KK's vocabulary is built. One closed command vocabulary describes the tool, its exact argument vector,
its stdio disposition, and its frame; one interpreter runs it; one quoter and one process runner sit
beneath; and one module owns the guest bootstrap — the ordered, probe-first steps that establish the binary
in a frame that has never run it. It now reaches the provider's ownership driver and the cluster's: every
provider and cluster effect is a described command, every decision above it a total function, and the
cluster boundary carries no program written in another language at all — the embedded one, the protocol its
reports were parsed back out of, and the private component its injected executor lived in are deleted.
Colima is held by its private native row and the guest alias is interpreted by the installed project binary,
so neither carries an interpreter program or discovers a locking/stat front end.

§ LL makes a provider a **row** over one closed frame table rather than a module of parallel logic, because
the guarded delete, the existence probe, the readiness wait, the budget-to-wall rendering, and the four
ownership clauses are one computation each: written per provider they become copies that pass their own
tests while disagreeing with each other. Its host-frame half is settled — `HostFrame` is the closed
three-constructor axis and the reconcilers are rows over it — and its guarded destructive delete is one
computation over that table. The **ownership primitive** is built, every host-local owner is on it, and the
provider and cluster drivers now hold their four clauses through it — the cluster as an object whose every
node carries its own record, so a cordon addresses a node by the identity this run bound rather than by the
name a replacement inherits. The shipped row carries that transaction to another frame, and both Colima and
the guest alias consume their appropriate rows without restating the clauses.

§ NN states what a gate's evidence is worth. A fake exists because a decision is trapped inside an effect,
so the answer is not to write better fakes but to lift the decision into a total function that can be
called: applied to values it needs no stand-in, and the primitives left underneath are exercised against
the real kernel. § MM is settled by the frame a described command carries: `framePathGrammar` answers which
grammar a path obeys from the process that will read it, so a validator's grammar follows the reader rather
than the writer.

[legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) records what is still standing against
those three, and each row names the phase whose completion removes it (§ I).

The constructive boundary of the narrative remains the
[recursive lifecycle command](phase-17-recursive-lifecycle-command.md). The completed
[authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) boundary's
challenge/grant foundation, exact config refinement, narrow child-plan authority, Build and Activation
packages, registered edge, keyless relay foundation, and the only two rooted protocol-v1 outer tags are
implemented. Sprint 13.9 adds the additive `RootedPayloadBinding`: its canonical root-signed bytes preserve
the existing immediate-edge binding and separately frame complete-payload and child-config digest claims.
Config signing and verification require exact byte/digest equality, while a signed unequal recovery claim
alone grants no package or config-field admission. Sprint 13.10 adds the abstract canonical two-frame
`RecoveryChildPackage`, its distinct hidden-capability live-broker signer, and the package-aware verified join.
That join treats the supplied rooted value as untrusted signed data, cryptographically reverifies its canonical
bytes against the exact authenticated handoff and installed key, and only then decodes the authenticated
payload and recomputes both package/config-field digests. It adds no receiver or catalog producer. Sprint
13.11 implements the standalone `AuthenticatedRootScope` primitive: its live-broker producer derives the exact
Production or Harness scope, and its installed-identity/key verifier introduces that scope only through the
closed rank-2 fold. Sprint 13.12 adopts it without changing the four-field outer Offer. The root Relay mints
one capsule for its live scope, nested links copy those exact root-issued bytes, and the Receiver structurally
splits the opaque Offer fields before it verifies the leading capsule against the independently installed
identity and key. Only inside that closed Production-or-Harness continuation may key, binding, challenge,
grant, or payload semantics run. This grants no edge or lifecycle authority. Sprint 13.13 adopts the exact
rooted proof in both receiver branches and retains the recovery package with its typed projection, grant, and
verified adapter wire. Root signing begins only after the exact Offer exists; nested links relay canonical
request/response bytes and receive no signing capability. Phase 13's own reverse route composes no package;
the [recursive lifecycle command](phase-17-recursive-lifecycle-command.md) supplies the sole producer. The 7 MiB embedded Offer
payload ceiling is only a strict sub-ceiling; Protocol's 8 MiB total-body check remains authoritative and may
still refuse the other fields and framing overhead. Sprint 13.14 implements the one hidden non-indexed rooted
request without changing Protocol: pathless `OpenFrame` is four fields, post-open control is nine, and only
settlement/descent result adds an opaque tenth field. Its strict 7 MiB codec is validated only by exact
private-source guards: no facade export, testing companion, or semantic/process/durable importer is introduced;
the neutral Receiver-internal path fold is the sole transport import. The sealed
external relay envelope is the sole open-time ancestry and uses the same one-to-256-component,
4,096-byte-per-component grammar as the inner post-open path. Sprint 13.15 implements the one neutral
non-indexed response: exact nine-field `Opened`, exact eleven-field post-open responses, their closed
request-family pairing and body/bound grammar, and no cryptography or semantic ownership. Sprint 13.16
implements the public fixed live-broker signer and installed-key exact-pair CPS verifier without another named
type or semantic caller. Its signature transcript frames only the fixed domain, installed-key digest, exact
request, and canonical unsigned response; the opaque result remains descriptive rather than authority. Sprint 13.17
implements only singleton rooted transport, bounded external requester-envelope construction, exact
inner-byte preservation, and structural request/response pairing in the keyless relay. Every hop checks the
authenticated path suffix and the root requires complete-envelope equality; the originating typed operation
alone verifies the returned signed bytes with the independently installed key. Both the existing outer
`Refused` and a signed rooted `Refused` remain distinct uninterpreted transport outcomes. Phase 13 validates
the structure of a rooted request at the root and carries the answer; which answer a request receives is the
[recursive lifecycle command](phase-17-recursive-lifecycle-command.md)'s rooted relay service, whose live
endpoint the root link runs. Sprint 13.17 constructs no recursive child and claims no
successful rooted process exchange, retained session path, durable replay/receipt behavior, or semantic
lifecycle transition.

Phase 17 consumes that wire for one root-owned recursive lifecycle. The topology root alone retains the
`ProtectedStore`, global run lease and snapshot, immutable recursive plan catalog, per-frame journals, and
all prepare, settlement, replay, and receipt transactions. A nested process is a long-lived storeless frame
executor: it independently reconstructs its cataloged target plan, receives one exact root-selected grant,
runs only that local probe or effect, and returns a bounded observation. It receives no protected-store path,
cursor, command authority, record key, compare-and-swap operation, signing key, or caller-selected operation
set. Shared authority mounts and generic protected-store RPC are outside the architecture.

The completed lower Phase 17 artifacts remain useful: root command gates, current-frame/reverse plan
projections, root-coordinator lifecycle-context evidence, reverse intent/preparation, sealed handoff and
completion owners, structural acknowledgement/relay machinery, finalized child projection, and exact
planned-forward packaging, the recursive rooted plan catalog, the digest-proven codec and registry
reindexes, the recovered finalized specification each root plan's own index now carries, and the durable
catalog manifest the root entry now persists and strictly re-reads, the storeless forward package an
admitted descent entry authorizes, and the catalog-produced recovery package the private relay now opens,
signs, and transmits, and the installed recursive handoff runtime every frame now derives its trust and arm
from, the root-owned frame session an `OpenFrame` attaches to, the prepared node grant that follows every exact durable unknown row, the exactly-once settlement its observation returns to, the terminal receipt that ends it, the live root endpoint that answers the opening, and the storeless executor that place in the conversation belongs to, and the sanitized process route that carries the whole exchange over a child's standard input and output, and the descriptor isolation that keeps those bytes the receiver's own, and the bracketed POSIX owner that holds one child, its group, and its descriptors for exactly one edge. The forward and reverse receivers, root coordinator, semantic completion/recovery, exact cluster cleanup,
and retained reverse terminalization/rearm are also complete; prepared reverse descent now derives its exact
sanitized process route without losing nominal lineage, and the rooted reverse service now retains and settles
one prepared child forest through canonical receipt, while root command authority is now nominally distinct
from every nested descent parent. The proof-complete real-process gate is closed.

Sprint 17.37 has built what that opening produces. A `FrameExecutor` is deliberately the poorest value in the
recursive lifecycle: it holds a place in a conversation — the admitted canonical path, the root's opaque
session and stage, the ordinal the root said comes next, and the digest of the last complete signed response —
and there is no function from one to a store, journal, lease, snapshot, catalog row, signing key, session
opener, or settlement. Every entry point turns signed bytes into a response through one helper consuming the
installed key and the exact request those bytes answer, so no branch reads a coordinate off unverified bytes.
Opening admits only a verified `Opened`; advancing admits every post-open family but `Opened` and requires a
strictly greater ordinal; and execution admits only `Prepared`, reads its four packages out of that response
rather than beside it, and refuses a `Descend` or a signed `Refused` on the same branch — which is what keeps
"the root answered" apart from "the root authorized this effect". Only after the authorized node, its ordered
dependencies, and its projections are compared against the frame's own plan does the executor become the sole
additional caller of `mintPreparedGate`, and what it mints restates a durable row the root already wrote:
the attempt and journal version come out of the signed package, because a storeless frame has no other way to
know them.

Sprint 17.36 has made the root endpoint live. `rootBrokerLink` now runs a rooted lifecycle service where it
previously refused every request, and the one service the repository builds reaches the fixed signer only
through the recovery signing admission the relay already holds. The runtime gains a root-arm fold, so the arm
that may reach a signer is chosen by which fold a caller can enter rather than by a boolean beside the
identity it returns, and a keyless nested arm cannot be read as a root runtime at all. The session owner
holds the join: it enforces the sealed envelope's one-to-256 component, 4,096-byte grammar before comparing
that envelope to the path the session itself retains, admits exactly an `OpenFrame`, and renders the
nine-field unsigned `Opened` from root-selected coordinates alone — the request contributes only the digest
that names it. Signing arrives as a continuation, so the owner still names no signer, and the existing
attachment records the complete signed response's digest and reads it back before the caller may release
those bytes. Because Ed25519 signing is deterministic, an exact replay under the same lineage, catalog,
envelope, and nonce re-derives the same bytes over a row already attached, and any other bytes are a
conflicting row rather than a second opening.

Sprint 17.35 has closed the terminal receipt in its own storeless owner. `Lifecycle.Rooted.Receipt` reaches a
session only through the frame-session owner's fixed-unit coordinate fold and names no `ProtectedStore` at
all: both durable steps arrive as continuations from the relay that already holds the recovery signing
admission, so what the owner holds is the join and the two digests rather than the writes. Only a `CloseFrame`
reaches a terminal report and only a `ReceiptConfirm` confirms one, each answered inside its own paired
`FrameComplete | Refused` or `ReceiptRecorded | Refused` family; a signed `Refused` is read as an outcome
rather than minted. The close checks the session's own path, token, ordinal, nonce, and recorded predecessor,
requires the carried report to eliminate canonically and name the session's verb, and publishes and reads that
report back before the complete signed-response digest exists. The confirmation names that report by carrying
the digest as its predecessor, and the recorded receipt repeats it in its own body, so a child that persists
nothing can still say which terminal report was received and an exact retry converges without reopening
anything.

Sprint 17.30 has landed the catalog-produced recovery package. Durable reverse-descent
preparation takes its canonical child configuration only from the admitted catalog edge, joins it to the
plan's own reverse adapter through Phase 13's frozen constructor, and makes the complete package — never the
adapter alone — the prepared record's payload, the binding input's child-config digest, and the offer payload.
Both root reverse entries retain the catalog they were admitted under. The private relay's reverse route is
that durable Bound transition wrapped in transport: it opens the package recoverably through the frame's own
keyless link, proves payload, token, and opened binding agree, compare-and-swaps the Bound row, and only then
routes the exact Offer to the already-installed root signer and enters the existing challenge loop. The route
takes no payload argument, so an adapter alone is unrepresentable there, and a repeated attempt recovers the
binding and token the root already minted rather than opening a second edge.

Sprint 17.29 has landed that forward package. One rank-2 catalog fold selects an admitted descent by exact
parent and child frame — missing, duplicated, and sibling children each refuse — and rechecks the selected
entry against the parent level's own retained plan, so a parent frame that is not that level's current frame,
a descent the parent plan does not declare with exactly the retained raw route, and projected node keys that
are not the parent plan's own all refuse before the continuation. The fold discloses the parent level only as
its own current frame. `CatalogForwardHandoff` then rechecks the admitted child against the evidence the
entry retains — target-plan current frame, validated-configuration endpoint, rendered plan digest against the
binding's, and configuration/payload digests against each other and the canonical payload's own hash — before
rebuilding the binding input and sealing. It retains no lifecycle context, parent plan, or specification
index, and has no process or command call site. The same sprint adds the suite's first projecting
forward-child fixture, so the real `project up` entry now admits a one-layer VM descent and persists a
manifest that frames that exact edge before the first effect.

Sprint 17.25 has landed the recursive rooted plan catalog. Its hidden all-nominal
`RootedPlanCatalog scope rootPlanId brokerGeneration catalogId` is its own entry carrier: the base retains
the root's finalized specification, invocation authority, plan, current frame, and root-resident lifecycle
context, and each extension retains one admitted descent edge with its exact target plan, digest binding,
current frame, raw and stripped route, canonical config bytes, config and payload digests, and the parent
frame's plan-owned projected node keys. Construction rechecks root residency, the frame-evidence join, the
admitted context endpoint, and the authority's installed project and store identity before descending; the
descent terminates on a frame with no declared edge and is bounded by the root topology's frame count. The
same sprint factors descriptor, context, configuration, and target-plan validation into one VLC-free
immediate-target kernel that the immediate `PlannedForwardHandoff` producer now delegates to. Both modules
are hidden with no runtime caller, so their coverage is exact source and compile-fail guards; behavioural
coverage arrives with Sprint 17.28's root entry call site, and positive multi-level admission with Sprint
17.29's projecting fixture.

Sprint 17.26 has landed the two remaining specification-index relabellings. The installed `ProjectCodec` and
the jointly finalized service registry each keep their representation in a Cabal-hidden owner whose sole
importer is the facade that re-exports the abstract type and every producer and eliminator it already owns.
Each owner holds one reindex kernel that changes only the phantom, compares the digest-equality token against
the digest the carrier itself retains — the registry retains the exact digest its finalization stamped, so a
project registering no service is checked rather than relabelled vacuously — and preserves every other
retained term. Neither kernel reaches a public facade, mints a token, or admits a caller-selected index.

Sprint 17.27 has joined both relabellings under one token. The recovered-inputs boundary now yields the exact
finalized specification alongside the recovered configuration and drafts, all three at the recovered
profile's index, and that public boundary is what carries the join's behavioural coverage. `Command` threads
it through both root `project up` entries — the fresh entry holds the invocation's own specification, the
recovered entry the relabelled one — and the shared bound body refuses before any lifecycle effect unless the
threaded specification's digest is the bound plan snapshot's.

Sprint 17.28 has made the catalog durable. That threaded specification now reaches the one root-entry call
site, where the entry admits the recursive catalog after the acquisition journal has revalidated the live
global lease, protected snapshot, and plan digest, then compare-and-swaps one bounded canonical manifest
keyed by the root plan's installed project, stable profile, and broker epoch. The catalog owner renders and
strictly compares those bytes and names no store, session, record, or compare-and-swap operation, so durable
authority stays with the entry. An exact retry converges on the record already present because the decision
comes from the strict readback rather than from who won the swap; conflicting bytes and a refused descent
projection both refuse before the command reservation and before any effect. The root Up entry retains the
exact catalog, reachable only through the owner's rank-2 folds.

The accepted security boundary is explicit. Root signatures authenticate coordinator responses, and exact
requester path, session, stage, ordinal, nonce, predecessor digest, and sealed package-private construction
prevent malformed, stale, or cross-edge traffic among cooperating interpreters. They do not attest a physical
child against a malicious same-privilege launcher or intermediary; that stronger claim needs independently
provisioned descendant identity or platform attestation.

**Live acceptance owed.** Phase 18 builds deterministic interruption fixtures and closes on its host-static
gate. The later test-harness phase reruns the targeted `recovery-interruption` Cabal group on linux-cpu, then
runs `hostbootstrap run -- test run all` against live infrastructure. Phase 20 has every deliverable built and
closed by the host static gate and still owes its own declared live linux-cpu sequence. Phase 17 closes on its
future core host-static gate with real local process-boundary fixtures; Phase 24 Sprint 24.30 separately owns
the worked-demo Production `up`/`down`/`destroy` and Harness `10/10` confirmation.

**Machinery without a production call site.**

- **18.2**'s broker, old-permit fence set, verified session/operation manifest, and recorded-session
  interpreter have landed, and a **completed** migration is resumed from the durable stable key rather than
  inferred from current config. **18.3**'s digest-level migration spine has also landed: the profile builders,
  freeze, lineage compare-and-swap, activation transition, and configless post-CAS classification. The
  remaining work is split by contract and adoption: **18.4–18.7** build durable complete resource-record
  rehydration; **18.8–18.13** make prospective, completed, frozen, recovered, committed, and activated migration
  consume real plans and the exact set; **18.14–18.16** derive recovered frames, consume the shared recovery
  wire, and drive abandoned resources child-first; **18.17–18.18** retain Production lifecycle ownership and
  consume settled destroy as project-closure evidence; and **18.19** installs the deterministic interruption
  matrix that the later test-harness live gate confirms on linux-cpu.
- **22.2**'s effect algebra and its closed `ServiceProgram` have landed: an undeclared effect is a compile
  error, a row outside the signed ceiling has no authorization, and there is no `IO` constructor. The
  **declared row** has now landed with it — `serviceDefinition` takes a `DeclaredEffects`, the registry carries
  it through finalization and selection, and the demo's two roles declare genuinely different rows. What
  remains is the handler return type and the `ServiceBackend` call site, which cannot precede the deploy step
  that installs a signed activation, so they land with **22.3**.
- **22.3**'s relayed activation signing has **landed**: a distinct private-protocol
  `ActivationSignRequest`/`Response` tag pair reachable only from an admitted child, a manifest wire codec so
  the root signs a value it decoded rather than opaque bytes, and a Cabal-private relay operation with the root
  signing locally and every other frame relaying. Phase 13's keyless relay foundation owns that lower route;
  its rooted relay adoption and Phase 17's storeless executor/process adopters supply the complete recursive
  runtime evidence. What 22.3 owes is activation installation plus `service run` measurement/verification. It
  does not own the demo chart transaction; worked-demo Sprint 24.26 joins those activation semantics to exact
  cluster readiness at the chart/workload boundary.
- **24.4**'s published-base consumption is now enforced: every derived build passes `--pull`, and the
  host-native lane resolves the published tag to its repository digest and builds `FROM` that, refusing an
  image that has no repo digest because that is exactly the stale-local case. The digest is a within-run
  handoff rather than a committed pin, which is what § FF requires. The existing config-derived Harness
  profile/root isolation is not the target boundary: 24.4 still replaces those independent consumer terms with
  the exact plan-owned projection. **24.5** extends the lower step/plan declaration vocabulary, authors the
  provider/cluster resources at their exact frames, and proves the unique direct-parent join; **24.6–24.7**
  seed neutral plan execution and project the concrete workload/partition/slices. **24.8–24.18** establish the
  invocation-owned canonical/live dependency registries, VM/Direct/share/alias adopters, and authenticated
  parent-serviced provider reprobe. **24.19–24.23** render exact Kind/nvkind config, bind and discover the
  closed backend, recover fresh cluster readiness, and adopt reconcile/cordon/readiness. **24.24–24.27** plan,
  prepare, adopt, and reverse the readiness/activation-gated chart workload. **24.28** installs the frozen demo
  projector only after those consumers, and **24.29** connects Phase 13's reusable build protocol to the real
  Docker secret/session channel. **24.30** alone records the worked-demo live acceptance.

Every one of those depends only on lower-numbered phases, so they can be taken in order.

## Validation policy

`Done` requires the phase's own declared gate to pass, aligned governed documentation, and no remaining work
in its scope. A phase closes on **its own** gate; it never carries a closure obligation needing hardware it
does not declare.

Two gates carry that weight, and a phase says which one closes it (§ II). The **host static gate** —
`cabal test all --ghc-options=-Werror` from `core/` plus the two Python commands — runs as an ordinary
process of the outer host and proves the pure, typed, and lexical contracts. Because every binary is
built host-native (§ N), it must pass host-native on macOS, Linux, and Windows alike (§ JJ); running it
natively on Windows is an outer host realization, not a substrate declaration. A **`linux-cpu` substrate
gate** is one whose gated process and POSIX/container effects execute inside the realized Linux
substrate, and a native Windows or macOS process is not one of those merely because its assertions are
otherwise static. Neither gate substitutes for the other.

A dated run validates only the behaviour and substrate it exercised. It cannot stand in for a different
provider, architecture, concurrency race, negative parser path, or newly introduced type boundary — which is
why each acceptance phase lists what it confirms, and why a change to a behaviour a lane exercises makes that
lane's acceptance owed again.

Exact test counts are dated evidence recorded against the gate that produced them, never a repository-wide
"current count".

Three limits worth stating rather than assuming: `fourmolu` and `hlint` run only inside the container
`check-code`, so the host static gate is not the complete quality gate; a host static gate run is evidence
for the one outer host that ran it, so its dated evidence names that host and a pass on one outer host is
not a claim about another; and the long demo gate brings up real
provider VMs, Docker state, and clusters on the host it runs on. A harness run's cluster identity, removable
state, and durable root are its own rather than production's. The active exposure work makes selected host
ports runtime-owned by that exact run as well; until it closes, fixed mappings can still collide. The gate no
longer takes the operator's project identity, but it still mutates real host infrastructure, so a disposable
host remains the supported way to run it.

## Governance

- [development_plan_standards.md](development_plan_standards.md) — the doctrine (§ A–§ J, § II) and the
  normative technical contracts (§ K–§ JJ).
- [00-overview.md](00-overview.md) — phase responsibilities and the dependency flow, without status.
- [system-components.md](system-components.md) — the implementation surface inventory.
- [rationale.md](rationale.md) — why the design is what it is, and what it is not.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) — code still standing that the
  architecture does not want, each row naming the phase whose completion deletes it (§ I).
- Each phase file owns its objective, sprints, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture and
engineering documents describe supported behaviour; where a contract is not yet fully built, the owning phase
is `Active` and says so.
