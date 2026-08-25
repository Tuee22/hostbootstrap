# Shared Host Resource Protocol — Review

**Subject**: `documents/engineering/shared_host_resource_protocol.md` (82 lines, `**Status**: Draft`)
**Kind**: Review artifact. Not a governed document, not a canonical home, states no contract.
**Method**: Every load-bearing claim checked against Haskell and Python **source**, not against
neighbouring documents. Governance audited against `documents/documentation_standards.md` and
`DEVELOPMENT_PLAN/development_plan_standards.md`. Provenance read from git. The "shared host claim
ledger" the document defers to was searched for in this repo, in the sibling repos on this machine
(`amoebius`, `infernix`, `jitML`, `daemon-substrate`, `prodbox`), and as an installed root on this host.

---

## Verdict

The document is honest, well-written, and mechanically compliant — and it should not stay in
`documents/engineering/`. Three independent problems, in descending severity:

1. **It does not solve the problem it opens with**, and says so.
2. **Two of its three load-bearing technical claims are false about this codebase.**
3. **It is structurally the one artifact shape this repo's governance elsewhere makes a build
   failure** — unowned, orphaned, and a second home for a topic `resource_budgeting.md` owns —
   filed in the one tree where no ownership check reaches it.

---

## 1. Provenance: a deflated import that kept a foreign premise

The file's entire life is 2026-08-24, in three commits:

| Commit | Size | What it was |
|---|---|---|
| `f42714a` | 869 lines | Verbatim **amoebius** spec, *"Finite Resource Execution Authority Protocol"* — amoebius's `<details>` link-graph metadata block, and amoebius phase numbers 29 / 32 / 51 / 52–54 (this repo has phases 0–29) |
| `3dadfaf` | 1032 lines | Rewritten as a hostbootstrap-framed full protocol spec |
| `7cd5d28` | 82 lines | Cut to the current "Not adopted" residue |

The deflation was correct. But the residue inherited the import's framing premise. The original stated
its own design goal as *"There is no common package, service, daemon, executable policy document, or
dependency on `hostbootstrap-core`."* That is sensible **for amoebius**, which sits outside this
family's library chain. Read from inside hostbootstrap it inverts: `documents/architecture/library_hierarchy.md`
puts `hostbootstrap-core` at **L0**, beneath `daemon-substrate` (L1) and `{jitML, infernix}` (L2). A
protocol premised on "no dependency on `hostbootstrap-core`" is, here, a premise that the family's own
shared layer must not be the shared layer.

## 2. The proposal does not solve the problem it states

The problem section is sharp: two heavy native builds started from two repositories contend for the
same memory with nothing naming the contention. The proposal is a record. And then:

> "No enforcement changes. The uncapped and unreconciled cases listed above stay uncapped and
> unreconciled; **a claim declares demand, it does not bound it.**"

No admission path reads the record; nothing refuses; nothing waits. Two builds both write claims and
both still exhaust the host. The candour is to its credit, but candour about inertness is not a design.

The release story compounds it. `Transient` claims self-heal because "hostbootstrap may release its own
stale claim on its next run." The only reader who cares about a stale claim is *another* project, and
that reader stays blocked until hostbootstrap happens to run again. Self-healing on next-self-run puts
the repair on the wrong agent for a **shared** ledger.

**This is a choice, not a limitation — and it is the fatal one.** There is exactly one thing a shared
object buys that observation cannot: an observation is an instant, not a lease. `infernix`'s production
code says precisely this — *"The admission taken at mint is an observation at an instant, not a lease.
A claimant that started inside the region … must refuse the child rather than ride the earlier answer"*
(`BuildMemory.hs:1266-1272`) — and pays for it by re-observing immediately before every fork. A
`Transient` claim behind a held lock is the object that closes that gap. The draft then negates its own
best argument by declaring the claim non-binding. Either commit (participants must read and refuse or
wait — a real design needing a phase, live semantics, and a deadlock story), or drop the ledger for
observation. The middle position — a record nobody consults — is the one shape that costs adoption work
and returns nothing.

## 3. Claim-by-claim verification

| # | Claim in the document | Verdict | Evidence |
|---|---|---|---|
| 1 | "direct Linux GPU outer work is uncapped" | **Accurate**, understated | `Substrate/Provider.hs:955-968` — `direct` provider, `spReconcileCordon = Nothing`; container argv carries no `--memory`/`--cpus` |
| 2 | "bare-Linux storage has no runtime quota or image-GC wall" | **Accurate**, understated | `Cluster/Cordon/Foundation.hs:158-164` — `StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable`; `storageCordonPolicy` has **no `src/` call site at all** |
| 3 | "existing VM sizing is not uniformly reconciled" | **Accurate**, understated | Lima/Incus `spReconcileCordon = Nothing`; WSL2 re-applies the global wall; Colima compares and refuses. Nothing anywhere resizes an existing VM |
| 4 | "the WSL2 ceiling is one per-user utility-VM wall rather than a per-distribution one" | **Half true** | True of CPU/memory (`.wslconfig`). Storage **is** per-distro (VHDX `--vhd-size` at registration). `resource_budgeting.md:41-43` states both halves; the draft states one |
| 5 | "the base-image builder … accounts for nothing else running on the machine" | **False** | `hostbootstrap/resources.py:119,129-133` reads `/proc/meminfo` **`MemAvailable`**, not `MemTotal`; headroom is `max(25% of MemAvailable, 2 GiB)` under a comment reading *"Reserve headroom for the host (and other base build)"*; CPU is `cpu_count - 1`. `base_image.md:121` also says the CLI "measures available CPU/RAM". The gap is TOCTOU and absent coordination, **not blindness** |
| 6 | "Charges come from the budget the builder already computes" | **False at the named seam** | The seam (`bootstrap.py:372` `_assert_minimums` → `prereqs.py:239` `run_doctor`) asserts **zero resource quantities** — Ubuntu 24.04 + passwordless sudo + `curl`; Xcode CLT + Homebrew; winget + PowerShell. `resources.compute_build_budget` is on the maintainer-gated `base build` path only (`cli.py:643,678`), Linux-only (`detect_host_resources` returns `None` elsewhere), and has **no disk dimension** |
| 7 | "The Haskell binary does not exist yet at that point in the run" | **True only cold** | `.build/<exe>` persists (`bootstrap.py:333`, `_copy_if_changed:466`) and `_assert_minimums` re-runs every invocation. The load-bearing "a shared Haskell library could never govern it" holds only for a first build on a fresh checkout |
| 8 | "The primitive is also already present here … not a new mechanism" | **True of the repo, false at the seam** | The Windows global wall is real: `%USERPROFILE%\.hostbootstrap\global-wall` (`Wsl2/GlobalWall/Windows.hs`) on `base`'s portable `hLock` = `flock`/`fcntl`/`LockFileEx` (`internal/ownership/HostBootstrap/Protected.hs:27-28`), with a worked-out ownership/CAS argument (`GlobalWall/Host.hs:20-31`). But it is **Haskell**, inside the binary the doc argues does not exist yet. `hostbootstrap/*.py` contains **no locking code of any kind**. It is also **mutual exclusion, not sharing** (a second owner gets `ForeignWallOwner`/`IncompatibleWallSpec`; nothing sums two demands), and CPP-gated **Windows-only** |
| 9 | "The five substrates and four providers are closed enumerations here" | **Imprecise** | 5 matches `Substrate.SubstrateName`; but `HostFrame` is 3 and the Dhall `Substrate` vocab is 3 (no Windows). 4 matches `Substrate.Provider.ProviderKind`; but the **budget** machinery indexes `Cluster.Budget.Internal.ProviderBackend` (**6**: Colima, Lima, Incus, Wsl2, DockerNode, BareLinux) and `Context.ProviderKind` (**7**) is documented *"deliberately open-ended"*. An adapter author told "four providers" maps the wrong enum — the doc's own warning, turned on itself |

## 4. It aims at the side of the boundary this project has been deliberately emptying

The criticism I weight highest after §2, because it reverses a documented decision without noticing it:

- `documents/engineering/resource_budgeting.md:346` — *"the project binary applies them, **never the
  Python bootstrapper**."*
- `documents/engineering/prerequisites.md:38,51-52,159` — `/dev/kvm`, the `linux-gpu` NVIDIA runtime,
  and Docker were **removed from** the Python floor and given to Haskell `ensure` reconcilers:
  *"those transitions belong to their `ensure` reconcilers."*
- `documents/architecture/python_haskell_boundary.md` — a **closed 9-item enumeration** of what Python
  owns for `doctor`/`build`/`run`.
- `DEVELOPMENT_PLAN/phase-1-python-pre-binary-floor.md:15-18` (Done) — Python *"owns no lifecycle, no
  configuration model, and **no second implementation of anything the Haskell core owns**."*

A ledger record reader plus a portable file-lock helper in Python is a 10th item in a closed list, a
host-policy interpretation the boundary assigns to Haskell, and precisely the second implementation
phase 1 forbids — of a primitive `HostBootstrap.Protected` already owns.

## 5. The counterparty does not exist; the one that does uses a different mechanism

- **No installed ledger root exists on this machine.** `/opt`, `/var/lib`, `/etc`, `/usr/share`,
  `/usr/local/share`, `~` — nothing. The document says the ledger's authority is "the installed root
  and the `spec-version` that root carries." That root is not installed.
- **The spec exists in no sibling repo's working tree.** `amoebius`'s own `resource_capacity_*` doctrine
  has zero cross-project mentions.
- **`infernix` already solved this, unilaterally, without a ledger — and it already governs the
  hostbootstrap interaction on this machine.** `Infernix/HostClaimants.hs` + `Infernix/BuildMemory.hs:1129-1160`
  take two observations at the point of use: available host memory, and a census of foreign toolchain
  processes outside its own tree — `cabal`, `ghc`, versioned `ghc-N`, `ghc-iserv{,-dyn,-prof}`,
  `ghc-pkg`, `ghci`, `haddock`, `hsc2hs`, `runghc`, `runhaskell` (`HostClaimants.hs:447-467`).
  **A named claimant is a fail-closed refusal, not a warning.** It is production-wired: taken at
  authority mint (`BuildMemory.hs:1201`) and re-taken immediately before every toolchain fork (`:1272`).

  hostbootstrap's `_build_native` runs `cabal`. **So infernix already refuses to start while a
  hostbootstrap build is running**, with hostbootstrap as the unwitting, unconsulted claimant.

That reframes the whole thing. The asymmetry is real and worth fixing — but what hostbootstrap lacks is
the **reciprocal observation**, not a claim record. Observation is strictly stronger for this problem:
it binds a peer that never opted in, and needs no installed root, no `spec-version`, no cross-project
release cadence, and no agreement. A cooperative advisory ledger is the weaker mechanism *and* the one
that requires everyone to adopt it first.

## 6. Governance: passes every check, and is a triple outlier

It clears the full `HostBootstrap.DocValidator` — metadata block, link resolution, `snake_case` naming,
taxonomy — and `Draft` is a declared-legal `Status` (`documentation_standards.md:30`). Every objection
below is doctrine, not a mechanical violation. Passing is not evidence of belonging; it is evidence the
validator has nothing to say about this axis.

- **Only `Draft` among 61 governed docs** (42 `Authoritative source`, 17 `Supporting reference`, 1 `Draft`).
  **Only doc with a single `Referenced by` entry** (all 60 others list ≥2). **Only doc in `architecture/`
  or `engineering/` with zero inbound links** from any other governed doc.
- **Its sole inbound link repo-wide is `documents/README.md:101`** — where it is the **first entry under
  `## Engineering`**, ahead of `schema.md` and `secrets.md`. The least load-bearing page in the suite
  holds the most prominent slot in the index.
- **Second canonical home.** `## The problem here` restates `resource_budgeting.md:53,281,352` and
  `applied_cordon.md`, against `documentation_standards.md:141` ("keep one canonical home per topic").
  `resource_budgeting.md` is named in the `Docs to update` of phases 6, 7, 12, 16, and 24; this file is
  named by none of them, so its copy goes stale the moment those deficiencies close.
  *(Precision: `phase-29-documentation-reconciliation.md` Sprint 29.1 declares `Docs to update: every
  governed document`, so generic maintenance is nominally in scope — but phase 29 is `Planned` and last,
  and no phase that will actually edit this topic names the file.)*
- **Status claims in the wrong tree.** "no phase owns the work" is a plan-ownership assertion inside
  `documents/`, which `documentation_standards.md:120-122,142-145` reserves for `DEVELOPMENT_PLAN/` —
  and it is unreconcilable, because `DEVELOPMENT_PLAN/` says nothing on the topic.
- **The repo already has sanctioned homes for this shape, both with a mandatory owner.**
  `DEVELOPMENT_PLAN/rationale.md` (§ D:114-118 — *"the one permitted mention of a shape the project does
  not use"*) and `legacy_tracking_for_deletion.md` (§ I:299-313 — *"an unowned row is exactly how a
  ledger rots into a repair log"*), both enforced by validator checks. This draft is that shape placed in
  the one tree where no ownership check exists.
- Minor: `> **Read this if**:` extends the governed metadata block and appears nowhere else in the repo.

## 7. What the document gets right

- The **"Not adopted"** framing is exemplary. It refuses to create a dependency by writing a document,
  names the installed root rather than a repo copy as authority, and explicitly disclaims implementation
  status. That instinct is why the 869→82 deflation was correct.
- Classifying anything that outlives the invoking command — a VM, an Incus/Lima instance, a registered
  WSL2 distribution, a retained image store — as `Persistent` and **out of scope** is the right call.
- The guest caveat is real, though **understated**: on the Apple, Windows, and Incus routes the heavy
  footprint lands *inside* a VM the doc classifies `Persistent` and excludes, so a metal-frame claim
  would cover the smallest part of the footprint on most substrates.
- The warning not to couple an adapter to this project's substrate/provider enumerations is exactly right.
- Claims 1–3 of the problem statement are accurate and understate the absence of enforcement.

## 8. Disposition

**Recommended: delete the file and its index entry, and move the one durable insight to
`DEVELOPMENT_PLAN/rationale.md`.**

Strip the false sentences (§3) and the duplicated problem statement (§6) and what remains is a *rejected
alternative with an argument attached*. `rationale.md` is the repo's one sanctioned home for that
(`**Status**: Non-normative`, 44 existing entries, present-tense justification, absence guard only "where
one exists"). It needs **no owning phase** — the file itself is already owned by phase 0 Sprint 0.2
(`Done`), and `checkContractOwnership` is scoped to `development_plan_standards.md` contracts, never to
`rationale.md`. It also has a structural twin already in place: `### A free-port probe is not a port
allocation`, under `## Ownership and reservations` — the same argument about a weaker advisory mechanism
mistaken for ownership of a contended host resource.

Mechanics, if you want it:

1. Delete `documents/engineering/shared_host_resource_protocol.md`.
2. Delete `documents/README.md:101-105` **in the same change** — `checkLinks` (`DocValidator.hs:982`)
   resolves every relative target in the index, so a dangling entry fails `cabal test all`.
3. Add one `### An advisory shared claim record is not host arbitration` entry to `rationale.md` under
   `## Ownership and reservations`.

Alternatives considered and why they rank lower:

- **Keep and repair in place.** Defensible only with a full reframe — retitle away from a protocol this
  repo does not own, fix claims 4–9, add the missing cross-links to `python_haskell_boundary.md` and
  `prerequisites.md`, add inbound links from `resource_budgeting.md` and `base_image.md` to end orphan
  status, and demote the index entry. After all that, roughly fifteen lines of unique content survive:
  the cross-cutting negative ("no control here observes foreign demand") and the infernix fact. There is
  a real brevity argument for not folding those into `resource_budgeting.md` (367 lines) or
  `applied_cordon.md` (316) — both already past the ~300-line split threshold — but fifteen lines is
  thin justification for a governed page.
- **Delete outright, add nothing.** Cheapest and fully legal. Its one cost: `rationale.md` exists *"so a
  reader does not reintroduce one"*, and this shape was reintroduced from a sibling repo once already,
  today. Git history does not prevent a re-import; a rationale entry does.
- **Move the note into `resource_budgeting.md` with an owning phase.** Not viable. Phases 0–24 are
  `Done`, 25–27 are substrate-acceptance phases; every candidate owner (1, 3, 23) is closed, so this
  costs a phase reopening — a status flip caught by `checkPhaseStatusHarmony` and a reversal § A resists.

**Not proposed:** no new phase, no Python ledger reader, no Python lock helper, and no adoption of the
observe-and-refuse census either. The census is the better mechanism and worth naming as such, but it is
not implemented here, and asserting it in a governed doc would repeat the original mistake in the
opposite direction. If you ever want it, the seam is `resources.assert_build_minimums` (already a
fail-fast floor over measured host facts) with a typed mirror in `HostBootstrap.HostPrereqs` — and it
needs a sprint, not a document.

## 9. Incidental defects found while verifying

Independent of the document under review, both worth a look:

1. **`documents/engineering/resource_budgeting.md:350`** describes the Colima adapter as holding its
   artifacts *"under descriptor-held Python `fcntl.flock`"*, and
   **`DEVELOPMENT_PLAN/development_plan_standards.md:705`** repeats it. There is no `fcntl` anywhere in
   the Python tree (`grep -rn "fcntl" --include=*.py` returns nothing) and `HostBootstrap.Ensure.Colima`
   is entirely Haskell, holding its entry through `HostBootstrap.Protected`
   (`Ensure/Colima/Ownership.hs:54-66`). This is the line that makes the reviewed draft's "the primitive
   is already present here" look true.
2. **`core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs:7-9`** says the pure-Python `prereqs.py`
   "remains the live implementation until the canonical-quantities-and-reconcile-results phase reclaims
   the residual subset". That phase (6) is `Done` and the Python is still live, so the comment is stale.
