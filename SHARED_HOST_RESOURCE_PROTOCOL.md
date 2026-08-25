# Shared Host Resource Protocol — Review

**Subject**: `documents/engineering/shared_host_resource_protocol.md` (111 lines, `**Status**: Draft`,
at `576b74e`)
**Kind**: Review artifact. Not a governed document, not a canonical home, states no contract.
**Method**: Every load-bearing claim checked against Haskell and Python **source**, not against
neighbouring documents. Governance audited against `documents/documentation_standards.md` and
`DEVELOPMENT_PLAN/development_plan_standards.md`, and against the mechanical validator
(`HostBootstrap.DocValidator`). Provenance read from git. The "shared host claim ledger" the document
defers to was searched for in this repo, in every sibling repo on this machine (`amoebius`,
`infernix`, `jitML`, `daemon-substrate`, `mcts`, `prodbox`), and as an installed root on this host.
**Supersedes**: the review at `6bd1172`, which reviewed the 82-line version this one replaced. That
review's §5 conclusion — that point-of-use observation is *strictly stronger* — is **wrong**, and the
rewrite is right to say so. See §2 below.

---

## Verdict

The document is well-written, internally coherent, and — as of the `576b74e` rewrite — no longer says
anything false about this codebase. It achieved that by deleting almost everything it said about this
project.

**It is now a competent summary of a protocol that exists nowhere, filed in a directory reserved for
this project's own engineering doctrine, under a Purpose line that promises hostbootstrap specificity
the body explicitly refuses to supply.**

The rewrite made the document more correct and less useful in the same stroke. Its single best
argument — §6 — is an argument *about hostbootstrap*, and the document will not say so.

---

## 1. Provenance: the rewrite removed the specifics rather than correcting them

The file's whole life is 36 hours, in four commits:

| Commit | Date | Lines | Shape |
|---|---|---|---|
| `f42714a` | 2026-08-24 | 869 | Verbatim import — *"Finite Resource Execution Authority Protocol"*, carrying **amoebius** phase numbers 29/32/51/52–54 (this repo has 0–28), amoebius's `<details>` link-graph block, amoebius's `> **Read this if**:` convention, and no metadata block |
| `3dadfaf` | 2026-08-24 | ~1040 | Rewritten as a hostbootstrap-framed full protocol spec |
| `7cd5d28` | 2026-08-24 | 82 | Cut to a **"Not adopted."** residue that named concrete hostbootstrap seams |
| `576b74e` | 2026-08-25 | 111 | Current. All hostbootstrap-specific content removed |

Two root-level analyses were written and deleted in the same commits that shrank the file:
`4c0f210` added a 754-line `SHARED_HOST_RESOURCE_PROTOCOL_ANALYSIS.md`, deleted by `7cd5d28`;
`6bd1172` added a 229-line `SHARED_HOST_RESOURCE_PROTOCOL.md` review, deleted by `576b74e`.

The `7cd5d28` version said what hostbootstrap would claim (`Transient`), where it would attach (the
pre-binary minimum-assertion step), what the charge would come from, and carried an
**"Open before adoption"** list that included the guest/host divergence. `576b74e` deleted all of it
and stated the new principle at `:98-99`:

> "Three obligations hold for any participant, and **none of them is stated here for any particular
> one**."

The index gloss tracks the same move — `documents/README.md:101-106`, "how hostbootstrap would
participate" → "what participation would mean".

Two things also disappeared that were load-bearing:

- **the bold `**Not adopted.**` marker**. The only surviving signal that this is not repo policy is
  unemphasised prose at `:12`.
- **the guest caveat**, which was the most important hostbootstrap-specific fact in the file (§3B).

Read against the review it followed, `576b74e` is a defensive edit: the falsifiable claims were
**removed rather than corrected**. What remains is unfalsifiable because it is about no one.

---

## 2. Where the new version is right, and the previous review was wrong

§6 is the strongest section in the file, and it corrects the review that prompted it.

> "What it cannot see is capacity with no process to observe: an idle cluster, a stopped virtual
> machine, a registered guest, or retained bytes on disk."

That is not an abstraction here. It is a literal inventory of what this project produces:

- the demo full-lifecycle ceiling is **6 CPU / 10 GiB / 80 GiB**
  (`demo/src/HostBootstrapDemo/Config.hs:675-679`; `demo/.build/hostbootstrap-demo.dhall:57`);
- `project destroy` deletes the VM and **preserves `.data`**;
- kind/nvkind clusters, registered WSL2 distributions with their VHDX slice, Colima profiles, and the
  Cabal warm store all persist with no process to census.

And the peer that already observes cannot see any of it. `infernix`'s
`Infernix/HostClaimants.hs` — verified live — censuses `cabal`, `ghc`, versioned `ghc-N.*`,
`ghc-iserv{,-dyn,-prof}`, `ghc-pkg`, `ghci`, `haddock`, `runghc` outside its own process tree, and
**fails closed**:

> "Both fail closed. An unavailable probe, a malformed response, or a census that names a claimant is
> a refusal that reports what it found; none of them is evidence that the host is free."

So today, unilaterally and with no agreement, **infernix already refuses to start while a
hostbootstrap `cabal` build is running**, with hostbootstrap as an unwitting, unconsulted claimant —
and it is simultaneously blind to a stopped 10 GiB Incus VM and an 80 GiB retained store that
hostbootstrap left behind.

§6's claim of non-subsumption is therefore **correct**, and correct *specifically about hostbootstrap*.
The `6bd1172` review's "observation is strictly stronger" does not survive contact with this project's
own footprint.

**This is the document's central failure of nerve.** It makes the one argument that matters for this
repo, and then declines to say the argument is about this repo.

---

## 3. The holes

### A. The reclamation story regressed to nothing

`7cd5d28` had one: `Transient` self-heals because *"hostbootstrap may release its own stale claim on
its next run without an operator."* The rewrite deleted it and added two properties that make the gap
strictly worse:

- §2: *"A truncated file, an unfamiliar revision, and a corrupted byte all decode as occupied, so no
  failure of the encoding can release capacity."*
- §2/§4: `Persistent` means *"the holder's death proves nothing."*

Together, **every failure mode leaks capacity permanently, by design**, and the document never names
an operator path back. There is no liveness notion, no staleness rule, no GC, no override.

The contrast with the repo's own primitive is sharp. `HostBootstrap.Protected` (in
`core/hostbootstrap-core/internal/ownership/`) states:

> "The exclusive entry is `base`'s portable `hLock`, which is `flock`/`fcntl` on POSIX and
> `LockFileEx` on Windows and is **released by the kernel when the holding process dies**."

The ledger's design deliberately discards the property this repo's equivalent mechanism is built on.

### B. The fixed-path rule is unworkable across this project's own substrates

§1 makes `$HOME/.hostclaim` absolute and says the resolution *"admits no configuration"* because
divergence is *"the one failure the ledger exists to prevent."*

hostbootstrap's entire job is crossing that boundary. Lima, Incus, WSL2 and Docker frames each carry
their own `$HOME`; on Windows, WSL2's `$HOME` and `%UserProfile%` are **different roots on the same
machine**. A claim taken inside a guest coordinates with nothing on the host, and a metal-frame claim
reaches nothing inside the guest — which is where the heavy footprint lands on the Apple, Windows,
and Incus routes.

`7cd5d28` said this outright under "Open before adoption". The rewrite **deleted the caveat and kept
the absolutism that causes it.**

### C. §7's "derive the charge once" is already violated inside this repo

Two independently authored reserve figures exist today:

- `hostMemoryReserveBytes = 4 * 1024^3` — `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`
- `HOST_MEM_HEADROOM_BYTES = 2 GiB` — `hostbootstrap/resources.py:47`, under the comment
  *"Reserve headroom for the host (and other base build)"*

That is precisely the silent drift §7 warns about — a finding the document would have surfaced had it
looked at this project at all.

### D. It cites nothing, and there is no counterparty

§1: *"Its authority is that installed root and the `spec-version` the root carries."* The document
names no location for the spec, no version, and no participant. Verified:

- `/home/matt/.hostclaim` **does not exist**; nor `/opt`, `/var/lib`, `/etc` variants.
- `hostclaim` / `FREAP` / *"Finite Resource Execution Authority"* appear **nowhere** under `$HOME`
  outside this file and agent session transcripts — not in `amoebius`, `infernix`, `jitML`,
  `daemon-substrate`, `mcts`, or `prodbox`.
- amoebius's `resource_capacity_*` family and `phase_59_capacity_scheduler` are an **in-cluster
  Kubernetes reservation ledger** (Pods, Bindings, RBAC, admission webhooks) — a different mechanism
  at a different layer.

**The document defers authority to an installed root that is not installed, versioned by a
`spec-version` no one can read, for a protocol with one hypothetical participant.**

### E. No refusal semantics, no testability story

§3 implies admission can fail. Nothing states what a refused participant does — block, poll, fail —
with what timeout, or how a user learns *why*. Nor is there a story for testing admission failure
against a repo with `fail_under = 100` and a host-static gate expected to **pass natively on
Windows**: a `$HOME/.hostclaim` dependency in test code is a hermeticity and portability hazard the
document never raises.

### F. Two §2 bullets are in tension

*"Charges are declared in a frozen set of dimensions"* and *"a participant that has never heard of a
hardware family still refuses to double-book its domains, so adding hardware costs no revision"* are
presented as mutually supporting. They are not: the prefix test covers the **conflict domain**, while
the **charge dimensions** are explicitly frozen. New hardware needing a dimension outside the frozen
set (VRAM, NPUs, host PCI, ports) costs a revision. Worth noting that this repo's own budget has
**no GPU dimension** — CPU/memory/storage only — and states *"Direct Linux GPU outer host work is
uncapped."*

---

## 4. Governance

It passes `HostBootstrap.DocValidator` cleanly — `checkGovernedMeta` checks presence, not vocabulary;
`checkBroadDoctrine` is scoped to `documents/architecture/`; its single link resolves. Every objection
below is doctrine, not a mechanical failure. That is itself the point: the repo's enforcement was
built where the doctrine lives, and this shape sits in the one tree with no ownership check.

- **Sole `Draft` among 60 governed documents.** `Draft` is legal (`documentation_standards.md:30`),
  but the repo's established pattern for unbuilt material is `Authoritative source` plus
  `## Current Status` — `documents/architecture/lifecycle_state_model.md` and `network_reachability.md`
  are both unimplemented *targets* held that way. 39 of 60 docs carry `## Current Status`; this one
  does not.
- **Zero links in the body** (lines 10–111), against `documentation_standards.md:135` — *"each
  governed doc links to at least one other governed source."* Only the metadata line links out.
- **Only doc whose `**Referenced by**` names a single consumer.** All 59 others name two or more.
- **Mentions `hostbootstrap` exactly once**, unbackticked, in the Purpose blockquote. It never names
  `hostbootstrap-core`, the Python bootstrapper, `ensure`, the command surface, or any seam.
- **Numbered headings** (`## 1.` … `## 7.`) — `grep -rn "^## [0-9]" documents/` returns this file and
  nothing else.
- **Zero mentions in `DEVELOPMENT_PLAN/`.** No phase's `Documentation Requirements` names it. By
  contrast `resource_budgeting.md`, whose topic it partly duplicates, is named by six phases — so when
  the deficiencies close, that file is updated and this one rots with no gate to notice.
- **First bullet under `## Engineering`** in `documents/README.md`, ahead of `schema.md` and
  `secrets.md`. The least load-bearing page holds the most prominent slot.
- **No precedent in the repo** for "someone else's protocol that we do not implement." The repo has
  two owner-enforced institutions for recorded non-adoption — `DEVELOPMENT_PLAN/rationale.md`
  (§ D, *"the one permitted mention of a shape the project does not use"*) and
  `legacy_tracking_for_deletion.md` (§ I, *"an unowned row is exactly how a ledger rots into a repair
  log"*) — both in `DEVELOPMENT_PLAN/`, both requiring an owner, both validated.

---

## 5. The question the document avoids

Apply §7's own three obligations to hostbootstrap.

**Name the seams.** They exist and are unusually well formed. `HostBootstrap.Teardown.actionFor` maps
every verb to a release (`ProjectDown`/`ProjectDestroy` → `StopFrame`/`DeleteFrame`/`DeleteCluster`/
`ReleaseResource`), and `RoleLifecycle`'s drain runs under a `mask` bracket that cannot be skipped.
**§4's rule is already implemented here, before the rule was written.**

**Derive the charge once.** Already two figures, in two languages (§3C).

**Establish release evidence.** `withRunLiveness`, the § EE four-clause Locked-Origin Identity
Ownership kernel, and `Protected.hs` already do this — with a threat model stated in nearly the
ledger's own words (`development_plan_standards.md:2197-2200`): *"it excludes crash/retry and
concurrent cooperating runs, and it detects rather than silently overwrites foreign mutation. It does
not exclude a hostile same-privilege process."* Compare `shared_host_resource_protocol.md:56-57`.

So the honest answer for this repo is not "not yet". It is: **hostbootstrap cannot be a participant on
the terms given.**

- The Python floor has **no lock primitive at all** — zero `fcntl`, `flock`, `msvcrt`, `LockFileEx`,
  `filelock`, `portalocker` in `hostbootstrap/` — and is a **closed 9-item enumeration**
  (`documents/architecture/python_haskell_boundary.md:30-40`) governed by
  `phase-1-python-pre-binary-floor.md:17`: Python *"owns no lifecycle, no configuration model, and no
  second implementation of anything the Haskell core owns."*
- The Haskell binary that **does** hold the primitive is downstream of the heaviest work, since
  producing it is the work.
- The guest boundary defeats the fixed path on the Apple, Windows, and Incus routes (§3B).

That is a **structural** non-participation, not an effort question — and it is a far more valuable
thing to record than a spec summary.

### The cheaper real fix, which needs no protocol

`resolveHostCapacity` reads, per substrate:

| substrate | memory source |
|---|---|
| `linux-cpu` / `linux-gpu` | `/proc/meminfo` **`MemAvailable`** |
| `apple-silicon` | `sysctl hw.memsize` — **total** |
| `windows-cpu` / `windows-gpu` | CIM `TotalPhysicalMemory` — **total** |

**On two of three host families this project sizes against memory it cannot have.** Linux nets out
resident peers; Apple and Windows do not net out anything. Reading available rather than total there
is a one-dimension change in `Cluster/Cordon/Foundation.hs` and buys more real contention safety than
a ledger with no counterparty. It would need an owning phase, and every candidate owner (6, 16) is
`Done`.

---

## 6. What the document gets right

- **§4 is the best thing in the file** and is durable regardless of adoption: release-directed work
  must never be conditional on an admission that can be refused, or cleanup deadlocks against itself.
  This repo's teardown algebra already embodies it.
- **§3's refusal to overstate** — advisory, no limit applied, no device fenced, no defence against a
  non-participant or a hostile same-user process — is exemplary, and matches § EE's own honesty.
- **§6's non-subsumption argument is right**, and corrects the review it followed (§2 above).
- **§5's admission that progressive consumption is out of reach**, stated as a real limit rather than
  a gap awaiting a patch, is the correct posture — though it is worth noticing that progressive
  consumption (a warm store that fills, an image set that accumulates) is the shape *this* machine
  produces most.
- **Naming the installed root rather than a repo copy as authority** is the right reflex. It is also
  what makes restating the spec here self-undermining.

---

## 7. Options

Three coherent remedies. They are mutually exclusive.

### A. Re-project onto hostbootstrap

Keep the file; make it about this repo. Cut §2's spec restatement to a thin pointer (it has no
authority here by the document's own rule) and spend the space on: the four persistent objects
observation cannot see and which of them this project creates; the guest/`$HOME` divergence and which
substrates it breaks; the 4 GiB / 2 GiB reserve drift; and the primitives that already exist
(§ EE, `withRunLiveness`, `Protected.hs`, `Teardown.actionFor`). Then fix the governance outliers:
`Status` → `Authoritative source` with a `## Current Status` section, restore the bold
**"Not adopted."**, add body links, drop the numbered headings.

*Cost*: keeps an unowned document in `documents/` with no phase and no gate, which is how it rots.

### B. Retire to `DEVELOPMENT_PLAN/rationale.md` — **recommended**

Delete the governed document and its index entry; move the durable argument to `rationale.md` as a
rejected-alternative entry, under `## Ownership and reservations`, beside the structurally identical
`### A free-port probe is not a port allocation` — a weaker advisory mechanism mistaken for ownership
of a contended host resource. That file is the repo's one sanctioned, owner-enforced home for a shape
the project does not use, and it is `Non-normative` by status, which is what this content actually is.

Add one scoped defect note to `documents/engineering/resource_budgeting.md` — its canonical home,
named by six phases, therefore maintained — recording the honest residual: sizing is point-in-time and
uncoordinated, and on Apple and Windows it reads total rather than available.

*Cost*: the §6 insight is compressed into a rationale entry rather than developed.

### C. Governance-only

Leave the content; fix only the outliers listed in §4.

*Cost*: preserves the central defect — a hostbootstrap document that is not about hostbootstrap.

---

## 8. Side findings (independent of the above)

1. **A documented Python locking primitive that does not exist.**
   `documents/engineering/resource_budgeting.md:350` and
   `DEVELOPMENT_PLAN/development_plan_standards.md:705` both describe the Colima adapter's artifacts
   as held under *"descriptor-held Python `fcntl.flock`"*. `grep -rn fcntl hostbootstrap/ tests/ stubs/`
   returns nothing, and `HostBootstrap.Ensure.Colima` is entirely Haskell. Two governed documents
   assert a mechanism in the wrong language. This also makes the deleted "the primitive is already
   present" claim look true when it is not.

2. **Apple/Windows capacity is read as total, not available** (§5). Recorded here because it is the
   concrete contention defect the ledger discussion is circling.

---

## Appendix — what was verified

| Claim | Method | Result |
|---|---|---|
| Ledger root installed | `ls $HOME/.hostclaim`, `/opt`, `/var/lib`, `/etc` | **Absent** |
| Spec exists in a sibling repo | `grep -rl` over `amoebius`, `infernix`, `jitML`, `daemon-substrate`, `mcts`, `prodbox`, then all of `$HOME` | **Nowhere** outside this file and agent transcripts |
| amoebius owns the protocol | Read `resource_capacity_doctrine.md`, `phase_59_capacity_scheduler.md` | Different mechanism — in-cluster Kubernetes reservations |
| infernix observes foreign toolchains | Read `Infernix/HostClaimants.hs` | **Confirmed**, fail-closed, by executable basename |
| hostbootstrap observes anything foreign | Surveyed `Cordon/Foundation.hs`, `Cluster/Budget.hs`, `applied_cordon.md` | **No.** Aggregate scalars only; `applied_cordon.md` is enforcement, not observation |
| Python has a lock primitive | `grep` for `fcntl`/`flock`/`msvcrt`/`LockFileEx`/`filelock`/`portalocker` | **None** |
| Reserve figures agree | `Cordon/Foundation.hs` vs `resources.py:47` | **4 GiB vs 2 GiB** |
| Capacity read source per substrate | `capacityReadPlan` / `resolveHostCapacity` | Linux `MemAvailable`; Apple + Windows **total** |
| Release seams exist | `Teardown.actionFor`, `RoleLifecycle` drain mask | **Yes**, verb-indexed and complete |
| Document passes the validator | Traced `DocValidator.hs` dispatch | **Yes**, cleanly |
| `Draft` is a legal status | `documentation_standards.md:30` | **Yes**, and the only use in 60 docs |
| Any phase owns this | `grep -rn "shared_host" DEVELOPMENT_PLAN/` | **None** |
