# Shared Host Resource Protocol — Critical Analysis

**Subject**: [documents/engineering/shared_host_resource_protocol.md](documents/engineering/shared_host_resource_protocol.md) (583 lines, `Status: Draft`)
**Date**: 2026-08-26
**Nature**: Ad-hoc analysis artifact. **Not a governed document** — it carries no
`Status`/`Supersedes`/`Referenced by` block and sits outside `DocValidator`'s scope, which covers
`documents/**`, `DEVELOPMENT_PLAN/**`, and exactly three root docs
([`DocValidator.hs:93`](core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs)).

> **Verdict**: **Do not adopt. Demote to a measured reference note.** Take exactly one thing — §5.3's
> identifier-spelling table — as a naming convention. Fix five cheap hygiene items regardless.

---

## TL;DR

- **Everything the document measured reproduces exactly on this host. Everything it did not measure is
  broken.** The unmeasured half — §5's algebra and §7.2's admission procedure — is precisely the half
  this repository would have to implement.
- The syscall-level content is genuinely good and worth keeping as reference material.
- The protocol has **zero counterparties**, by its own §11 admission, and explicitly excludes the only
  shared-host failure these projects have actually recorded (§10).
- `hostbootstrap` already has kernel-released exclusion that is **already inside the mandated lock
  family** — measured, not assumed.

---

## 1. What reproduces (the honest strengths)

Re-measured on this host: Linux 7.0.0-28-generic x86_64 — the exact kernel §6.2 cites for its
independent reproduction.

| Claim | Result |
|---|---|
| §6.2 full 3×3 holder/prober matrix | **Cell for cell.** `{flock}` disjoint from `{fcntl, OFD}`; every negative control `ACQUIRED`; every `BLOCKED` carrying errno 11 |
| §6.2 lifetime table | **Both rows, all six cells.** `fcntl` LOST on unrelated-close and on fork-parent-exit; `flock` and OFD survived |
| §6.2 `FD_CLOEXEC` console block | **Line for line**, including the subsidiary `F_OFD_GETLK` → `l_pid = -1` detail |
| Struct arithmetic | **Exact.** Natural pack 28, kernel `sizeof(struct flock)` 32, `F_OFD_SETLK == 37` |
| §11 witness resolution | **Verbatim** in all four cells; 100/100 distinguishable at 50 ms spacing, cliff exactly at the 10 ms `CLK_TCK` tick |
| §5.1 algebra asserts | **All pass**, and both traps §11 names are real (naive string-prefix `conflicts("gpu:0","gpu:01")` → `True`; a `^…$` validator accepts `"gpu:0\n"`) |
| §3 container scope | **Holds.** OFD lock on the host, probed from inside an Alpine container over a bind mount: `BLOCKED` for `fcntl`/`ofd`, `ACQUIRED` for `flock` — family split intact across the boundary |

Beyond the measurements, three things deserve credit:

- **The OFD migration argument is the right reason for the mandate**, not merely a workable one: an
  unmigrated classic-`fcntl` participant is already inside `{fcntl, OFD}`, so until it migrates it is
  *blocked rather than invisible*. Moving it to `flock` would take it out of the family.
- **§11's "not verified" register** names its own gaps — Windows, NFS, container init, and the
  zero-participant count — with more candour than most specifications manage.
- **§1's falsification table has real content.** The `$HOME`-is-an-environment-variable row and the
  `rename(2)`-orphans-the-lock row are both correct and non-obvious.
- **The "Not adopted" banner at §1** is honest and unusual.

---

## 2. Defects that matter

### 2.1 §7.2's admission decision is not confluent (blocking)

`conflicts()` is consulted **only** on the exclusive branch; the counted branch uses exact-match
arithmetic, which §5.2 defines as "arithmetic on an **exact domain match**, never a prefix sum."
Transcribed onto §5.1's own algebra and run both ways with `capacity = {host:memory: 1000}`:

```
order 1:  A "host:memory/build *" -> Grant       B "host:memory 800" -> Grant
order 2:  B "host:memory 800"     -> Grant       A "host:memory/build *" -> Conflicted
```

Same two claims, opposite outcomes. **Whoever asks first wins.** It also contradicts the document's
own sentence at line 194 — "`host:memory/build` is not a sub-share of `host:memory`; it is a
different, exclusive domain" — while `conflicts("host:memory/build", "host:memory")` is `True`
under §5.1.

The document never exhibits this pair, which is why it survived two review rounds: §5.2 discusses the
domains, §7.2 discusses the procedure, and nothing runs them together.

### 2.2 The self-skip breaks the capacity invariant (blocking)

§7.2 line 390 `continue`s before line 394's `held += content.claims`, so a caller's own **counted**
claims leave the sum. Measured on a faithful transcription: with capacity 64, one process is granted
`host:memory 48` three times in a row — 144 units against 64, violating §5.2's own stated invariant
`held(d) + reserved(d) + demand(d) <= capacity(d)`.

The prose at lines 416–417 justifies the skip for **exclusion** only ("a program that spawns a second
image of itself blocks on itself"). Applying it to the arithmetic is unjustified by the document's own
reasoning.

### 2.3 §9's crash guarantee is falsified by a plain `fork()` — and §6.2 contains the counterexample

§9 line 495 states that a spawned child outliving the holder is "**No leak**, because `FD_CLOEXEC` is
set." `FD_CLOEXEC` is consulted at `execve`, **not** at `fork`. A holder that takes the grant with the
flag verifiably set, forks a child that never execs, and is then SIGKILLed leaves the lock held:
prober `BLOCKED 11` before *and* after the kill, `ACQUIRED` only after killing the child, with
`/proc/locks` showing `OFDLCK ADVISORY WRITE -1` — a leaked grant that cannot even be named.

§6.2's lifetime table at line 292 already records "`fork`, parent exits, child keeps the descriptor →
**survived**" and presents it as a *virtue*. With §4 forbidding any TTL and §9 promising "Nothing here
requires an operator to delete a file," the leak has no remedy.

§4.3's stronger MUST ("MUST NOT let a grant descriptor be inherited") does cover the case — the defect
is §9's *justification* and the confounded `close_fds=False` measurement it rests on.

### 2.4 Standing claims break across a container boundary (blocking, and specific to this repo)

This is the mechanism `hostbootstrap` would actually need, and it is the one that fails on this
project's own container descent.

§3 line 61 puts containers in the **host's** scope ("Containers share the host kernel and are the same
scope"). But a containerised participant records its **PID-namespace** pid. Demonstrated end to end:

```
container: witness pid=10 starttime=187366749   # `sleep 300`, genuinely alive
host boot_id : 7ad97501-7aae-460e-813f-69be9677249f
recorded boot: 7ad97501-7aae-460e-813f-69be9677249f   # identical — same kernel, as §3 requires
host verdict : GONE
```

The boot check **passes** (the container shares the host kernel, exactly as §3 says). The witness is
**alive**. The host still reads the claim as `GONE`, so `vm:incus-demo` becomes re-grantable while the
resource runs. That is the **under-conservative** direction — a second claimant admitted — which
§4.1 line 110 explicitly claims the design avoids ("over-conservative rather than an admission of a
second claimant").

The document's scope model (§3) and its witness model (§4.1) are mutually inconsistent for containers,
and nothing in §11's unknowns register covers it.

### 2.5 §11's conformance test cannot catch the failure that matters (major)

`lock_is_free` appears **exactly once** in the entire document (line 392), undefined and unmeasured;
`free_slot_of_mine` likewise. §11's conformance script only ever runs the participant as **holder**, so
an implementation whose acquire path is OFD but whose *peer probe* is `flock` passes unchanged — and
then reads every live peer grant as free. The deciding cell reproduced here: holder `ofd`, prober
`flock` → `ACQUIRED`.

§11 itself concedes that one Haskell toolchain gives "two different answers in one toolchain," so a
split acquire/probe family is the likely case, not the exotic one.

Compounding it: the shipped `hostgrant_probe.py` reports an unreaped **zombie** as `LIVE`
(`os.kill(pid, 0)` succeeds for a zombie), and §4.1's prose states the rule the same way — so a faithful
implementation inherits the bug, falsifying §4.1's "Resource torn down → witness exits → claim ignored"
for the whole zombie window.

---

## 3. Fit to this project

This is where the question actually resolves, and the document answers it in its own voice:

> §11 line 577 — "no project on the machines these measurements were taken on implements this policy. A
> mutual-exclusion protocol's value is proportional to participants minus one, and this one currently
> has none."

> §10 line 509 — progressive consumption is "**the only shared-host failure these projects have actually
> recorded**", and it stays out of scope.

A protocol with zero counterparties that explicitly excludes the only observed failure mode.

**Current attachment to the repository:**

| Vector | Count |
|---|---|
| Inbound references | **1** — [`documents/README.md:101`](documents/README.md) |
| DEVELOPMENT_PLAN phases owning adoption | **0** |
| Source files reading or writing a rendezvous | **0** |

**What the project already has.** `withRunLiveness` and `withStoreLock`
([`Protected.hs:366,400`](core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs))
give kernel-released exclusion over `base`'s portable `hLock`. Measured directly here — GHC 9.12.4,
`hLock ExclusiveLock` on Linux:

```
prober=flock -> ACQUIRED
prober=fcntl -> BLOCKED 11
prober=ofd   -> BLOCKED 11
```

`hLock` is **already inside the mandated `{fcntl, OFD}` family** on Linux. (The doc comment at
`Protected.hs:27` describing it as "`flock`/`fcntl` on POSIX" is imprecise for Linux.) The document's
central mandate is therefore already satisfied — without the rendezvous, and without adoption.

**What adoption would cost:**

- A `sudo`-established `/var/lib/hostgrant` at mode `1777`, on every host, **inside every VM**, and
  bind-mounted into **every container** — against a project whose entire premise is bootstrapping a
  host with minimal preconditions. This touches `demo/`, CI, and every fresh substrate.
- Per-platform `fcntl` FFI with a hand-packed `struct flock`: `unix-2.8.8.0` exposes no `F_OFD` symbol
  and `base` has no byte-range API, so the Windows leg additionally needs `LockFileEx` FFI.
- All of it inside `-Werror` + `fourmolu` + `hlint` + 100 % Python coverage, gated host-native on three
  platforms — where §11 concedes **every** Windows claim is unverified, against an active
  [phase-27](DEVELOPMENT_PLAN/phase-27-windows-and-wsl2-substrate.md).

**A category mismatch in §8.** The obligation restates this repository's own method, but
[`documents/architecture/unrepresentable_state.md`](documents/architecture/unrepresentable_state.md) is
its canonical home and requires that "a claim of unrepresentability **ships a compile-fail fixture**.
Without one, the claim is a comment." §8 says work "*should* fail to compile" and cites neither that
page nor § HH. A repository that ships compile-fail proof obligations cannot place an order-dependent
admission decision (§2.1) under a type-level guarantee.

---

## 4. Recommendation

**Do not adopt.** The strongest reason is not any defect above — it is §11 in the document's own voice.
Adoption buys no exclusion this repository does not already have, while costing a rendezvous, a slot
format, an admission procedure, an algebra, per-platform FFI, and a conformance harness. And the parts
nobody measured — §5's algebra and §7.2's admission — are exactly the parts that would have to be
implemented, and they are order-dependent.

**Adopt exactly one thing:** §5.3's identifier-spelling table (`vm:incus-<instance>`,
`disk:<fs-uuid>`, `gpu:<vendor-stable-id>`) as a naming convention for identities the project already
mints. Pure naming — no rendezvous, no operator step, no lock.

**Demote the rest.** Retitle as a measured lock-mechanism reference note. §6.2 and §9's kernel
behaviour are excellent reference material and independently corroborate the `GuestFlock`/`GuestLockf`
split that [`wsl2.md`](documents/engineering/wsl2.md) already encodes as a type. Amend §1 to say
"reference measurements and naming table; not a target," so no future phase picks it up as adoptable
work.

**The trigger that would change this:** a second, independent program on one of these hosts contending
with `hostbootstrap` for a host resource — concretely, an observed collision on a GPU, an Incus/Lima VM
name, or host memory, with something the project does not control. Until then the cheap answer is a
well-known lock name for `withRunLiveness` under the existing protected store: kernel-released, already
`-Werror`-clean, already working on Windows through `base`'s `LockFileEx` backend, no operator step on
any host.

If the trigger fires, §2.1–§2.4 above are **preconditions** to a phase being able to write a `**Gate**:`
line at all.

---

## 5. Cheap hygiene, worth doing regardless of the adoption decision

1. **[`documents/README.md:101-105`](documents/README.md) is stale and wrong.** It describes "one grant
   held by the supervising process with **standing capacity declared as a reserve instead**" — the exact
   model §1 records as a *wrong* falsification and §4 replaced with three distinct kinds (grant /
   standing claim / reserve). It is the only inbound link in the repository. One-sentence fix.
2. **Two tracked `.py` files under `documents/` are invisible to every gate and fail all three
   linters.** Measured: `ruff` 20 errors, `black` would reformat both, `mypy --strict` 25 errors. Green
   today only because [`check_code.py:10`](hostbootstrap/check_code.py) scopes to
   `("hostbootstrap", "stubs")` and `DocValidator.listMarkdown` filters to `.md`. Decide explicitly —
   move them under a gated path and fix them, or record in the document that they stay ungated. **Do
   not widen `check_code`'s scope without fixing them first**; that would red the host static gate.
3. **`hostgrant_probe.py` opens slots with `O_CREAT`** (lines 36 and 44), against §6.2's explicit
   "`O_CREAT` never: slots are pre-created" and §7.2's MUST. It fails in the *false-pass* direction on
   exactly the unestablished-rendezvous condition §6.1 warns about. Two-line fix.
4. **§7.3's headline is a tautology.** After `install()`, `crash_harness.py` opens without `O_CREAT` and
   never unlinks, so `count()` **cannot** change; both arms of the "simulated hard crash" are the same
   `os.close(fd)`, differing only by a counter; and `grants=300/300` means zero contention ever
   occurred. It reproduces byte-for-byte and establishes nothing. Either drop "300 acquire/release
   cycles" and "simulated hard crashes" from the prose, or make the harness able to fail.
5. **§11 cites "§6.2's byte-0 result" — there is no such result.** §6.2's measured platforms are Linux
   aarch64 and Darwin arm64; the byte-0 rule is a bare MUST with no console block, sitting directly
   after the statement that the sample uses `l_len = 0` (whole file). Delete the citation or move
   byte-0 into the unknowns register.

**Structural nits if the document is retained:** §1's nine-row change log belongs in
[`DEVELOPMENT_PLAN/rationale.md`](DEVELOPMENT_PLAN/rationale.md) per the documentation standards' rule
to keep implementation chronology out of governed topic documents; the `Supersedes` line points at
deleted git history; and at 583 lines it is the longest document in `documents/engineering/` with no
`## TL;DR` (20 of 30 carry one).

---

## 6. Verified clean — do not re-audit

- All 22 inline anchors resolve to real headings.
- All relative links resolve on disk.
- `Status: Draft` **is** permitted vocabulary (`documentation_standards.md` line 30) — though it is the
  only `Draft` in the suite.
- `Referenced by` is accurate: the documentation index really is the only inbound reference.
- `DocValidatorSpec` passes with the document in place.
- §11's shell pass criterion runs correctly as written.

---

## Method

Ten agents across four phases: two grounding agents (one re-measuring every load-bearing Linux claim on
this host, one mapping the project's existing coordination machinery), four independent review
dimensions (protocol correctness, fit and cost, documentation governance, evidential quality), three
adversarial verifiers applying distinct lenses (does the document actually say this / is the technical
claim correct / does it matter for this repository), and one synthesis pass. Findings refuted by a
majority of verifiers were dropped; the order-dependence in §2.1, the crash-harness tautology in §5.4,
the stale index paragraph in §5.1, the linter counts, the container-witness failure in §2.4, and the
`hLock` family measurement in §3 were each independently re-confirmed by hand before being recorded
here.

Reproduction scripts are in the session scratchpad, not in the working tree.
