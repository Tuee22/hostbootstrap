# Analysis: `documents/engineering/shared_host_resource_protocol.md`

**Date**: 2026-08-25
**Subject**: `documents/engineering/shared_host_resource_protocol.md` (Status: Draft, 362 lines)
**Nature of this file**: A one-off review artifact, not a governed document. It sits at the repository
root, which `HostBootstrap.DocValidator` does not govern (`DocValidator.hs:93` fixes the governed root
set to `README.md`, `AGENTS.md`, `CLAUDE.md`), so it carries no `Status`/`Supersedes`/`Referenced by`
block and does not enter the documentation gate.

**Method**: Thirteen agents — six auditors across independent dimensions (empirical measurement,
project fit, protocol design, scope model, governance, value/alternatives), six adversarial verifiers,
and one completeness critic. Every empirically checkable claim was re-measured on this host
(`Linux 7.0.0-28-generic x86_64`, Ubuntu 24.04, ext4), not accepted from the document. Findings that
did not survive adversarial verification are listed in § 7 rather than dropped.

---

## Verdict

The document's **mechanism analysis is correct and reproduces exactly**. Its **protocol is not
adoptable by this project**. Its **governance position is the most urgent defect**: it is an unowned
Draft carrying 17 MUST-class obligations addressed to repositories that are not this one.

> **Reject §§ 4–8 as hostbootstrap policy. Retain §§ 6.2 and 9 as a lock-mechanism note.
> Fix the document's home before its bugs.**

---

## 1. What is correct, and was independently reproduced

Every measurable claim reproduced on this host — a different kernel and architecture from the
document's stated measurement platform (`7.0.0-28-generic x86_64` here vs `6.8.0-100-generic aarch64`
there), which strengthens rather than weakens them:

| Claim | Section | Result |
|---|---|---|
| Linux 3×3 lock-family matrix, cell for cell | § 6.2 | Reproduced, with negative controls |
| `{flock}` and `{fcntl, OFD}` are disjoint families on Linux | § 6.2 | Reproduced |
| Lifetime table: unrelated `close()` drops `fcntl` only | § 6.2 | Reproduced |
| Lifetime table: `fork` + parent exit — OFD and `flock` survive | § 6.2 | Reproduced |
| `F_OFD_SETLK = 37`, `struct.pack('hhqqi', …)` | § 6.2 | Correct; sample `take_grant()` works |
| With `FD_CLOEXEC` **set**, OFD lock released at `exec` | § 6.2 | Reproduced |
| Containers share the host kernel; a bind-mounted rendezvous arbitrates, a non-bind-mounted path does not | § 3, § 6.1 | Reproduced |
| Darwin `struct flock` layout (`'qqihh'`, `F_OFD_SETLK = 90`) | § 6.2 | Consistent with xnu; not measurable here |

The core argument — that OFD is the only mechanism with both `flock`'s open-file-description lifetime
and `fcntl`'s arbitration, so migration is incremental and safe — is sound. § 1's falsification table
has genuine archival value.

It also closed one of its own § 11 open items in this repository's favour:

> **Measured:** GHC 9.12.4's `hLock` (`GHC.IO.Handle.Lock`) emits an **OFD** lock on this host —
> `/proc/locks` shows `OFDLCK ADVISORY WRITE -1 … 0 EOF` for a `hLock`-held file. `Protected.hs`'s
> store lock is therefore already inside the mandated `{fcntl, OFD}` family and already has the
> survives-a-stray-`close()` property. It requires no change.

---

## 2. Findings

Severity is post-verification. Every row below survived an adversarial pass.

| # | Sev | § | Finding |
|---|---|---|---|
| 1 | **Critical** | 6.2 / 9 | The `FD_CLOEXEC MUST be clear` mandate lets a grant outlive its holder indefinitely, falsifying § 9's crash table and the § 4 reasoning that deleted every recovery path |
| 2 | **Critical** | 7 / 9 | The same mandate applied to `admission.lock` wedges admission **machine-wide** — a strictly larger blast radius |
| 3 | Major | 5 | Three of five v1 reserved families are quantities, which the boolean prefix algebra can only model as machine-wide mutexes |
| 4 | Major | 5 | Five reserved families, zero identifier syntax — conforming participants naming the same device differently do not conflict |
| 5 | Major | 3 | The Linux scope row omits guest VM kernels, and Linux+Incus VM is this project's default lane |
| 6 | Major | 7 | The specification contains exactly one operation. There is no release, no downgrade, no renew |
| 7 | Major | 4 | Reserves have no programmatic writer, while `project up`/`destroy` create and remove exactly what a reserve describes |
| 8 | Major | 6.1 / 7 | Operator-established root plus operator-registered slots contradict the project's reconciler doctrine |
| 9 | Major | 7 | In-place write with no mandated truncate leaves phantom and malformed domains; no refusal class covers malformed peer content |
| 10 | Major | 6.2 | The survey premise underpinning the OFD mandate is false on this host for the substrates this project manages |
| 11 | Major | — | No `DEVELOPMENT_PLAN` phase owns the document; the sentence stating non-adoption was deleted on 2026-08-25 |
| 12 | Major | — | Written as policy for unnamed other repositories; `hostbootstrap` appears once in 362 lines |
| 13 | Major | — | An Authoritative, phase-owned document already owns this topic, and the two mandate opposite descriptor policies |
| 14 | Minor | 5 | The verbatim `valid()` regex accepts a trailing newline in a format defined as line-oriented |
| 15 | Minor | 7 | `Busy` is mandated non-blocking with no backoff, fairness, or termination condition |
| 16 | Minor | 7 | The version rule is a machine-wide flag day, contradicting the incremental-migration argument |
| 17 | Minor | — | `Grant` already names a signed capability in this codebase, with roughly the opposite sense |

---

## 3. Critical: the CLOEXEC mandate falsifies the document's own crash guarantees

§ 6.2:218 mandates `FD_CLOEXEC` **clear** on the grant descriptor. § 9:306 asserts that SIGKILL of a
holder means "domains are free immediately"; § 7:278 annotates the returned grant "released by the
kernel when this process dies".

**Measured false.** An OFD lock is owned by the open file description, not the process. With
`FD_CLOEXEC` clear — the state the document requires — any `fork`+`exec` hands the same description to
the child, and the grant survives SIGKILL of its holder for as long as any child lives.

- Grant survived SIGKILL in **4 of 5 ordinary spawn patterns**: `fork`+`execv`, double-fork daemonize,
  `Popen(close_fds=False)`, `sh -c 'sleep &'`. Only `close_fds=True` released it.
- Reproduced in this project's own toolchain: a GHC 9.12.4 holder calling the **default**
  `System.Process.createProcess` leaked the grant past `kill -9`. GHC's `openFd defaultFileFlags`
  also yields `FD_CLOEXEC` clear, so a Haskell participant lands in the leaking configuration with no
  explicit action.
- `/proc/locks` and `F_OFD_GETLK` both report the OFD owner as `l_pid = -1`, so a leaked grant is
  **unidentifiable**, and a non-root operator cannot scan for it (600 of 812 processes on this host
  have an unreadable `/proc/<pid>/fd` for uid 1000).

§ 4:80 forbids *relying* on inheritance, but that rule cannot prevent inheritance from occurring —
and § 4:77-78 draws the opposite conclusion from it: *"No record outlives its holder, so there is no
reclaim rule, no time-to-live, no boot identity and no operator escape hatch."* The premise is false,
so the protocol has deleted every recovery path for a failure mode it mandates into existence.

**The larger case (finding 2).** § 7:235 makes `admission.lock` an OFD lock like every other, and
§ 6.2 supplies exactly one lock-taking helper. An implementation with one uniform descriptor policy —
the one the document's single helper invites — that spawns anything while holding `admission.lock` and
then dies leaves the global mutex held for as long as that child lives. Measured: every subsequent
probe returns `BLOCKED errno=11`. Every participant in the scope then gets `Busy` forever, including
ones with no conflicting domain, with no holder identity and no reclaim rule. § 7:270 makes
`admission.lock` non-blocking, so there is no queue to drain and `Busy` has no termination condition.

### Scoping this honestly

This is **critical as a document defect** and **near-unreachable for hostbootstrap on Linux**.
Measured on this host, every long-lived substrate process is a pre-existing daemon reached over a
socket, not an inherited-fd child: `incusd`, `dockerd`, `containerd`, and the running
`qemu-system-x86_64` all have `ppid = 1`. `Detached.hs:311` pins `close_fds = True` behind a hidden
constructor. The two spawn sites that leave `close_fds` at its `False` default —
`Effect/Run.hs:145-148` via `readProcessWithExitCode`, and `Colima/Backend/Runner.hs:124-125` — both
**wait** for the child, so it cannot outlive the holder unless the invoked tool self-daemonizes.

The residual exposure is **Darwin**, where `colima start` and `limactl start` genuinely daemonize out
of a foreground invocation. `Detached.hs:299-301` also documents a live Windows exception.

---

## 4. Major: the algebra cannot express what this project actually contends for

### 4.1 Quantities modelled as mutexes

`conflicts()` is reflexive prefix exclusion. Three of the five families reserved at v1 (§ 5:129) are
quantities:

- `host:memory` vs `host:memory` → **True**. Maximum simultaneous grants naming host memory on a
  machine: **1**, regardless of installed RAM.
- The obvious escape does not work: `host:memory/16GiB` vs `host:memory/32GiB` → **False**. Sub-segments
  give name-only partitions with no arithmetic and no relation to bytes, while any participant
  declaring bare `host:memory` conflicts with every slice.
- § 5:134 concedes "a new quantity costs a revision" — the algebra cannot express quantity — and then
  reserves three quantity families at v1 anyway.
- The document never states whether a bare quantity domain means "the whole quantity is spoken for" or
  "I am using some of it". Two participants that pick different readings do not interoperate.

This collides directly with § O of `development_plan_standards.md`, whose byte-valued
`EffectiveBudget`/`ValidatedBudget` contract admits two participants **with exact quantities** rather
than refusing one outright. The mismatch is in the admission decision, so § 8's "applies no limit …
existing enforcement is unaffected" does not repair it.

### 4.2 Reserved families with no identifier syntax

§ 5:129 reserves `host:memory`, `host:cpu`, `gpu:<id>`, `disk:<fs-id>`, `vm:<name>` and specifies the
syntax of none of `<id>`, `<fs-id>`, `<name>`. Since § 5:110 mandates byte-for-byte comparison, two
conforming participants naming the same physical device differently do not conflict — inside the
families that exist precisely to make them conflict. Measured against this host's real NVIDIA GPU:

- `gpu:0`, `gpu:nvidia0`, `gpu:GPU-<uuid>`, `gpu:pci-0000_01_00.0` — all grammar-valid, **no pair
  conflicts**.
- `gpu:0000:01:00.0` and `gpu:/dev/nvidia0` — the two spellings the kernel itself uses — are malformed.
- `disk:/`, `disk:/dev/nvme0n1p5`, `disk:259:5` are invalid; the two that remain (`disk:66309`,
  `disk:<uuid>`) do not conflict with each other.
- `vm:<name>` fails the other way: two unrelated projects that both name a VM `demo-vm` conflict
  spuriously.

§ 5:132's "a new family costs nothing" is true of family *names* and false of the thing that has to
agree. This project has a live GPU substrate (phase 26), so `gpu:<id>` is the one reserved family it
would actually use, and it is where the silence is most expensive.

---

## 5. Major: the scope model and the lifecycle model do not fit this project

### 5.1 The Linux scope row is wrong for the default lane

§ 3 grants Darwin "one scope per virtual machine" and Windows "plus one" for WSL2, but gives Linux only
*"The host. Its containers share that kernel, so they are the same scope."*

**Measured on this machine:** metal `Linux 7.0.0-28-generic x86_64`; the Incus instance
`hostbootstrap-phase24-cpu-host` is of type `VIRTUAL-MACHINE` running `Linux 6.8.0-138-generic`.
`linux-cpu` — the gated primary substrate — has exactly the two-kernel structure the document credits
only to Darwin (`incus.md:12`: *"Native Linux CPU uses an Incus VM as its provider frame"*).

The failure direction is the dangerous one: a participant implementing the table literally does not
take a host grant for deep work — it takes a **guest-local** grant at the VM's `/var/lib/hostgrant`
while believing it is on the host. That is precisely the *"admission against an empty guest-local
rendezvous succeeds every time"* failure § 3 exists to prevent.

### 5.2 No release operation

§ 7:269-278 gives `acquire(demand)` and the document gives nothing else. A grep for release semantics
returns only "released by the kernel when this process dies", "the kernel releases the lock", and
"Kernel-released" — none is an operation. A participant cannot relinquish a domain it has finished
with, cannot add one, and cannot narrow one. § 2:34 defines a grant as held "for as long as it occupies
them", which the API cannot express: occupancy ends only when the process does.

For this project that means a `project up` supervisor (25–50 min) and the accelerator daemon hold every
domain they ever needed until exit — and § 4:80 then forces each of the three chain frames to acquire
its own grant while the outer frame still holds overlapping domains.

### 5.3 Reserves have no programmatic writer

§ 4:69 makes `<root>/reserved` operator-only, but `project up` programmatically creates precisely the
standing objects a reserve describes (a persistent provider VM, a persistent kind cluster) and
`project destroy` force-deletes them. The declaration can therefore go stale in **both** directions —
and a stale line permanently excludes every participant from capacity that no longer exists, a wedge
§ 9's crash table does not cover because nothing crashed.

More broadly, § 3 and § 6.1 assume scopes are pre-existing and operator-provisioned, whereas
hostbootstrap **manufactures** the guest scope as part of the work it wants coordinated.

### 5.4 Operator setup contradicts the reconciler doctrine

`prerequisites.md:16-21` states that when a probe reports absence and a supported install plan exists,
"the reconciler installs and re-runs that probe rather than documenting a manual prerequisite", and the
file carries an explicit WRONG/RIGHT block against exactly the operator-runs-a-setup-command pattern.
§ 6.1's root-owned `/var/lib/hostgrant` plus § 7's operator-registered fixed slot count is a manual,
privileged, per-machine, per-project step no reconciler is permitted to perform. Passwordless sudo is
an asserted Linux minimum, so the directory could in principle be reconciled; the **slot count cannot**,
because it is an operator decision. On Windows the asserted minimums are only winget and PowerShell,
with no elevation asserted anywhere.

### 5.5 In-place write without truncate

§ 7:240-241 mandates in-place writes and argues this makes checksums and padding unnecessary. Padding
also solved a second problem the document drops: slots are never unlinked, release clears nothing, and
no truncate is mandated, so a shorter list leaves the previous holder's tail on disk. Measured:
republishing `gpu:0\n` over `gpu:0/part1\nvm:demo-cluster\n` at the mandated offset 1 yields
`gpu:0\npart1\nvm:demo-cluster\n` — one live domain, one **phantom** domain that will wrongly Conflict a
real cluster, and one malformed line.

The truncate omission is trivially fixable. The unstated half is not: § 7:285-288 offers exactly four
refusal classes and **none covers "a peer's slot content is malformed"**, so § 5:111's MUST-reject has
no defined effect on a scanner. Rejecting bricks admission machine-wide; skipping silently abandons
arbitration. Byte 0, "reserved on every platform", is never given a defined value.

A related compound failure: § 9:308's "Crash mid-write → No torn read" is protected not by
`admission.lock` (which does not survive the crash either) but accidentally, by the dead holder's grant
lock being released so the scan skips the slot. That accidental protection **disappears in exactly the
case the CLOEXEC mandate creates**. Measured: a torn `host:mem` — well-formed under § 5's grammar, so
no validity check catches it — read as a live grant.

### 5.6 The survey premise behind the OFD mandate is false here

§ 6.2:193-197 justifies mandating OFD over `flock` on the grounds that a survey found most programs
sharing a development host "already taking classic `fcntl` record locks at the call sites that
arbitrate host capacity". Measured on this host, the programs that actually arbitrate host capacity are
in the `{flock}` family, which the document's own matrix shows is **invisible to OFD**:

- **flock**: `dockerd` (image identity cache, volume metadata, network local-kv, buildkit cache and
  history, containerd-overlayfs metadata), `containerd` (bolt metadata, overlayfs snapshotter, mount
  manager), `snapd`, `cron`, `pipewire`, `lxcfs`.
- **OFD**: only `qemu-system-x86_64` (OVMF firmware images).

The mandate is still the right choice on its own merits; the *migration-cost argument* for it does not
hold against the real incumbents on this machine.

---

## 6. Governance: the most urgent defect

- **No `DEVELOPMENT_PLAN` phase owns it.** Zero grep hits for `shared_host_resource_protocol`,
  `hostgrant`, or `admission.lock` across the whole plan.
- **The non-adoption marker was deleted.** Revision `7cd5d28` (2026-08-24) opened with
  *"**Not adopted.** No hostbootstrap code reads or writes the ledger, no command depends on it, and no
  phase owns the work"* and carried a `## Current Status` section. `576b74e` kept a weaker form.
  **`ce2554b` (2026-08-25 15:51) deleted it outright** and replaced § 1 with the "Why this document
  changed" changelog. The file now carries **17 MUST-class obligations (6 of them MUST NOT) and 1
  SHOULD** across 362 lines, with exactly one scoping hedge — "would implement", in the Purpose
  blockquote — and no statement anywhere that no code implements it and no phase owns it.
- **It is addressed to other repositories.** "asked each project to adopt it", "Independent review in
  each project falsified it", "the same pattern both projects already use for the Docker socket",
  "Each project discharges this in its own idiom", "the only shared-host failure two of these projects
  have actually recorded" — *these projects* has no antecedent anywhere in the file. `hostbootstrap`
  appears **once in 362 lines**, in the Purpose blockquote. Line 14's "two of my own corrections" is the
  only authorial first person in the entire `documents/` suite. `documentation_standards.md:118-119`
  scopes this tree to hostbootstrap alone; § S of the plan standards holds that non-adopted external
  doctrine must not be treated as a current blocker.
- **Its origin explains the deixis.** `f42714a` (2026-08-24 15:29) added this file, and only this file,
  as an amoebius-framed cross-project protocol citing phases 29/32/51–54 — hostbootstrap has 0–29 — and
  a `Referenced by` target that does not exist here.
- **The third clause of its own Purpose is absent.** It promises "what adopting it would require" and
  supplies no adoption section, no cost, and no mapping onto any hostbootstrap substrate, command, or
  module. That absence is why this analysis had to construct the adoption case itself.
- **The topic is not vacant.** `documents/architecture/ownership_invariant.md` is `Authoritative source`
  with nine referrers; its first clause is *"an OS-released exclusive lock"* — the same primitive, for
  the same purpose, on the same substrates. Its normative statement is § EE (phase 5) and its clause
  work is **phase 14, titled "The four ownership clauses and host-local reservations", Status: Done**.
  The Draft declares `Supersedes: N/A`, never mentions the invariant or the clauses, and the two mandate
  **opposite descriptor policies**: § 6.2:218 requires `FD_CLOEXEC` clear, while the shipped POSIX seam
  opens with `O_CLOEXEC` (`Ownership/Posix.hs:180, 212, 231, 362, 405, 497`).
- **Vocabulary collision.** `Grant` is already a load-bearing signed-capability noun in this codebase,
  with roughly the opposite meaning. This is downstream of the canonical-home clash.
- **It has zero outbound links** in its body — the only document in `documents/engineering/` with none;
  the next-lowest has 2 and `resource_budgeting.md` has 32. Only the metadata `Referenced by` line
  satisfies the linking rule mechanically.
- **It passes the gate vacuously.** `DocValidatorSpec` reports OK, but the gate checks only that
  metadata lines are present and links resolve. Passing is not evidence of admissibility.
- **Its evidence is not reproducible here.** `hostgrant_probe.py`, named by the § 11 conformance
  procedure, exists nowhere on this machine. No measurement carries a date or an owning sprint. The
  Darwin and Windows rows require hosts this project's owner does not have.

---

## 7. Claims examined and **not** upheld

Recorded so they are not re-argued.

- **"Proving a bind mount is unimplementable"** — *refuted*. Device/inode identity gets a participant
  most of the way; the residual gap is that inode identity proves same object, not same kernel.
- **"The frame chain forces `Unsupported` everywhere"** — *refuted*. The chain has routes the auditor
  did not account for.
- **"§ 1's atomic-rename verdict collides with the repo's own design"** — *refuted*. The document's
  claim is correct **inside its own choice** to co-locate lock and content in one file. `Protected.hs`
  keeps `store.lock` separate from renamed record files, so the verdict does not touch phase-5 work.
  It is stated unqualified, however, and could be misread as condemning that pattern — a wording risk,
  not a defect.
- **"`No reader can observe a partial write` is simply wrong"** — *refuted* as stated; the real defect
  is the narrower compound case in § 5.5 above.
- **"hostbootstrap is currently exposed to the grant leak"** — *substantially overstated*. See § 3.
  The document defect stands; the project's Linux exposure is measured to be near zero.
- **"Two non-arbitrating lock families exist in this repo"** — *withdrawn*. An early reading assumed
  `hLock` was `flock` on Linux. Measurement shows it is OFD, so `Protected.hs` and `Ownership/Posix.hs`
  are in the same family and do arbitrate.
- **"infernix's census is incompatible with this policy"** — *overstated*. A lock registry and a
  foreign-process census answer disjoint questions and could run side by side.

---

## 8. The value proposition

- **No second participant exists.** Six sibling checkouts on this machine (`infernix`, `jitML`, `mcts`,
  `daemon-substrate`, `amoebius`, `agent`) were grepped for the protocol's vocabulary: **zero hits in
  all six**. A mutual-exclusion protocol's value is proportional to participants minus one. Adopting
  § 8 today buys exclusion against nobody.
- **§ 10 concedes the gap.** *"Progressive consumption is invisible … This is the only shared-host
  failure two of these projects have actually recorded."* The protocol does not address the only
  failure mode anyone has actually experienced.
- **The real contention points are already engineered out of contention here.**
  - *Ports*: hostbootstrap never picks a number. It publishes `127.0.0.1::<listener>/tcp` and lets the
    runtime select and bind atomically (`Cluster/Backend.hs:1621`), then binds the observed port to the
    plan generation; canonical cluster config is refused byte-level if it contains `hostPort:` or
    `extraPortMappings:` (`Cluster/Lifecycle.hs:437-438`). There is no scan-then-bind window for an
    advisory domain lock to reopen — modelling a port as a domain would be a regression.
  - *Names*: VM, cluster, and Colima profile identities are derived from project or plan identity, with
    a name-prefix delete guard.
  - *Same-project concurrency*: already excluded by a kernel-released run-liveness lock and mode lease
    (`Protected.hs:352-392`, phase 9).
- **§ 8's obligation is the one part this project over-satisfies.** A typed, non-constructible capability
  threaded through effectful boundaries is exactly this codebase's existing discipline — which is also
  why adopting it means threading a new index through a ~108k-line authority chain with no phase to
  land in. And the Python half has no compile step in which to have it (see
  `documents/architecture/python_haskell_boundary.md`).

---

## 9. Recommendation

**Reject §§ 4–8. Do not delete the file. Fix its home first.**

1. **Restore the deleted non-adoption sentence.** Highest value per character in the whole file — it
   converts 17 unowned MUSTs back into a proposal, and it is a one-line edit.
2. **Re-status and re-scope** the page as what it demonstrably is: an inbound, unadopted cross-project
   proposal. Add the one relationship line to `documents/architecture/ownership_invariant.md`, and
   correct `documents/README.md:101-105`, which currently describes the policy in the same settled
   register as the Authoritative pages around it.
3. **Record the adoption decision in `DEVELOPMENT_PLAN`.** Everything else follows from it. If the
   answer is no, the CLOEXEC contradiction, the `admission.lock` wedge, the missing release operation,
   the undefined identifier syntax, and the flag-day version rule are someone else's bugs and cost this
   repository nothing. If it is yes, each becomes phase work with an owner and a gate.
4. **Keep §§ 6.2 and 9** — reduced to a short, phase-owned lock-mechanism engineering note. That part is
   right, reproduces on a different kernel and architecture, and earns its place.
5. **One real action item it surfaced.** `Ownership/Posix.hs:378` takes a classic `fcntl` record lock
   via `setLock` — the mechanism the document measured as droppable by an unrelated `close()`. Note the
   fix is **not** one line: `unix-2.8.8.0`, the version in use, exposes only
   `setLock`/`getLock`/`waitToSetLock` (classic `F_SETLK`) and no OFD binding, so it needs new FFI plus
   a `CoverageManifest` declaration. `Protected.hs` needs no change at all.

If §§ 4–8 are ever adopted, these must be fixed first, and they are wrong regardless of who adopts:
the descriptor discipline for `admission.lock` and for every non-governed spawn; a release operation;
the identifier syntax for all five reserved families; a mandated `ftruncate`; a fifth refusal class for
malformed peer content; the version integer this revision actually is; and `\A…\Z` anchoring plus a
stated strip rule for `<root>/reserved`.

### The strongest argument against this recommendation

§ 1's falsification table records six specific designs that were tried and disproved, and says
explicitly that it exists so "the same ground is not re-argued". That register is valuable to this
repository whether or not the protocol is ever implemented here, and it is written project-neutral
*because* it serves several projects. Forcing a hostbootstrap adoption decision onto the page risks the
two worst outcomes: a "no" that deletes the falsification record along with the policy, or a "yes" that
distorts a cross-family document into a hostbootstrap-specific one and breaks it for its other
consumers. Recommendation 2 is the form that preserves the record; recommendation 3 should be recorded
in the plan rather than imposed on the page.
