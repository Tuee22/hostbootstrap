# Remediation Plan — Documentation/Code Consistency Reconciliation

**Type**: Transient working artifact (NOT a governed doc). Delete this file once the remediation
lands so it does not become a parallel canonical home (documentation_standards § "keep one canonical
home per topic"). It deliberately does not carry the governed metadata block.

> **Purpose**: Describe, in detail, how the 26 verified review findings (plus the completeness-gap
> follow-ups) are fixed by reconciling **code as ground truth**, then rewriting `README.md`,
> `documents/` (per `documents/documentation_standards.md`), and `DEVELOPMENT_PLAN/` (per
> `DEVELOPMENT_PLAN/development_plan_standards.md`) into one cohesive, monotonic development narrative —
> reopening phases and updating `legacy-tracking-for-deletion.md` as required.

---

## 1. Context — what the review found

The `hostbootstrap` **binary is internally coherent and works** (full demo lifecycle real-run-validated).
The defect surface is almost entirely **documentation and source comments that drifted behind two
landed refactors**:

1. **Phase 18** added the `service` command (the core surface grew from five to six verbs).
2. **Phase 19** genericized the project model (`ProjectSpec cfg tcfg`; the chain became
   `psChain :: cfg -> [Step]`; `ProjectConfig`/`RootConfig` ceased to be core types).

Docs and comments were not swept consistently after either, producing repo-wide drift plus a handful
of genuine code/artifact defects. Two systemic issues dominate the blast radius (~25 sites each):

- **Command-surface drift** — the code currently surfaces six verbs (`ensure`, `context`, `project`,
  `test`, `service`, `check-code`; `Command.hs:96`), enumerated three incompatible ways across the docs
  (one family drops `service`, one drops `ensure`), usually asserted as "exactly"/"fixed." Per your
  direction the canonical surface is **five** — `ensure` is a composable reconciler library, not a
  command (§ 3.1) — so the code is corrected to match.
- **Chain-signature drift** — the live type is the generic `psChain :: cfg -> [Step]` (`CLI.hs:68`),
  but docs/comments say `RootConfig -> [Step]` (DEVELOPMENT_PLAN + root README + the standards doc) or
  `ProjectConfig -> [Step]` (the entire `documents/` tree); `RootConfig` exists nowhere in core and
  `ProjectConfig` is only the demo's type. The two adjacent core headers `Chain.hs:3`/`Step.hs:3`
  even contradict each other.

Both contradictions originate **inside the authoritative source documents** —
`development_plan_standards.md §§ P/T/W/Y` write `RootConfig -> [Step]` while `§ BB` defines the
generic model; `CLI.hs:7-10` calls `ensure` a "hidden debug surface" while the code surfaces it
normally. Fixing the canonical sources first is therefore load-bearing.

The full verified finding set (26 ranked issues + completeness-gap follow-ups) is enumerated in the
traceability matrix (§ 11). The two false-positives the adversarial pass refuted are excluded.

---

## 2. Guiding principles

1. **Code is ground truth; docs reconcile to code** — except for the small set of *genuine code
   defects* listed in § 4, where the code is fixed to match a documented contract.
2. **Resolve every systemic ambiguity once, centrally, then propagate.** Each canonical decision
   (§ 3) is fixed first in the authoritative source (the standards doc, the source-code comments,
   `system-components.md`), then applied verbatim everywhere else. No topic gets two canonical homes.
3. **Monotonic narrative (the user's constraint).** The development plan must read as one ordered
   story where **a later phase never contradicts or silently rewrites an earlier phase's delivered
   work**. Where a later phase changed an earlier surface (phase-18 `service`, phase-19 genericization),
   the earlier phase docs gain an explicit **forward-pointer**, and the superseded surface moves to
   `legacy-tracking-for-deletion.md` — never a stale "this is current" claim left in the old phase.
4. **Forward-only / non-blocking validation.** Reopening a phase for its own remaining work must not
   block any other phase. A phase is `Done` iff *its own scope* is complete and its docs are aligned;
   an independent phase reopening elsewhere does not reopen it (development_plan_standards § C).
5. **Declarative current-state language** (standards § D): phase narrative describes what *is*;
   obsolete names live only in the legacy ledger; per-phase historical metrics are explicitly labelled
   as point-in-time snapshots, not the current total.

---

## 3. Canonical decisions (resolve the systemic ambiguities)

These are the definitive resolutions every edit conforms to. Three carry a genuine choice and are
flagged **DECISION** — the recommended option is stated; please confirm or override.

### 3.1 Command surface — exactly five verbs; `ensure` is a library, not a command

**Per your direction (2026-06-23): there are no hidden commands, and `ensure` is exclusively a library
of host-configuration reconciler primitives that projects compose into their chains in a variety of
ways.** This supersedes the earlier "hidden debug surface" reading — including
`development_plan_standards § L`'s line-226 claim and `CLI.hs:7-10`'s header, both of which are
rewritten. The canonical statement everywhere becomes:

> The fixed core command surface is **exactly five** user-facing verbs — `project`, `test`, `service`,
> `context`, and `check-code`. There are **no hidden commands**. `ensure` is **not a command**: it is a
> library of idempotent host-configuration reconciler primitives (`ensureDocker`, `ensureIncus`, …, and
> the `ensure-*` `Step` kinds) that a project composes into its `chain`, run by `project up` as chain
> steps (§ Y). `coreCommandNames = ["context", "project", "test", "service", "check-code"]`.

This makes the "drop-`ensure`" doc family exactly right and resolves the whole F1 contradiction in one
direction: code and docs both converge on five verbs + a composable reconciler library.

- **CODE change (design correction, your direction):** remove the standalone `ensure` verb from the
  surfaced tree — drop `"ensure"` from `coreCommandNames` (`Command.hs:96`) and its wiring
  (`Command.hs:121`, the `ensureCommandWith` builder in `Ensure.hs:99-106`) — and delete the "hidden
  debug surface" language in `CLI.hs:7-10`. **Keep** `allReconcilers`, every `ensureX` reconciler, and
  the `ensure-*` `Step` kinds: that is the library surface a project composes. Update `CLISpec` /
  `EnsureSpec` so they assert the five-verb surface and the reconciler library (not an `ensure` verb).
- **DOC change:** the canonical five-verb statement replaces every divergent enumeration. The
  "drop-`service`" family (`documents/README.md:131`, `demo_runbook.md:70`,
  `authoring_project_binaries.md:126`, `derived_project_standards.md:252`, `cabal_layout.md:89-91`,
  `ensure_reconcilers.md:173-174`, `hostbootstrap_core_library.md:23-25/49-50/193`, `phase-16:41/251`,
  `phase-4:28-30/140-141`, `phase-13:260`'s invented `config`/`cluster`) and every "`ensure` is a
  top-level/exposed/hidden verb" claim are rewritten to: **five verbs + `ensure` as a composable
  reconciler library**. This includes rewriting `development_plan_standards § L` (drop "exposed as an
  optparse subcommand" and "standalone `ensure <tool>` … hidden debug surface"; the reconcilers are
  library primitives / `Step` kinds composed into chains), rewriting `phase-3` (the `ensure` suite is a
  reconciler library, not a verb group; its wrong-host applicability fails fast when the *step* runs),
  and removing the `ensure` "Hidden debug" row from the `README.md` CLI Surface table (it lists the five
  verbs, with a `service` row).

### 3.2 Chain signature — generic `chain :: cfg -> [Step]`

The canonical phrasing for the *core/abstract* signature is `chain :: cfg -> [Step]` (equivalently
`psChain :: cfg -> [Step]`, `ProjectSpec cfg tcfg`), matching `CLI.hs:68`, `§ BB`, and the one doc
already correct (`library_hierarchy.md:169`). `RootConfig` is deleted as a type name everywhere; the
demo's concrete instance stays `demoChain :: ProjectConfig -> [Step]` (the demo's own `ProjectConfig`,
`demo/src/HostBootstrapDemo/Config.hs:107`). Fixed first in:
`development_plan_standards.md §§ P (325) / T (382-383) / W (430) / Y (509)`, then `Chain.hs:3` and
`Step.hs:3` (identical wording so their cross-reference is consistent), then propagated to the ~40
doc/comment sites in § 11/R3.

### 3.3 Test-count single source of truth

The current core total is **238** (independently counted: 238 static `testCase` definitions across
`core/.../test/*.hs`; demo is 13). Decisions:

- **`system-components.md` carries the single canonical "current suite" line** (e.g. "current suite:
  `core 238 + demo 13` via `cabal test all`"). README foundation and `00-overview.md` quote that line.
- Every per-phase number (226/232/237 …) is **relabelled as a point-in-time, phase-close snapshot**
  ("`cabal test all` 232 as of Sprint 19.1") so it is never read as the current total.
- **Re-count after the § 4 code fixes land** (removing the `ensure` verb + updating CLISpec/EnsureSpec,
  and adding escaping/golden tests, will shift the number) and write the re-counted value as the SSoT;
  do not hardcode 238 in the final edit.
- Reconcile `system-components.md`'s "phase 20 — no core change" wording with the real 237→238 growth.

### 3.4 `project down` at the cluster frame — DECISION

`development_plan_standards § Y (526-528)` and `§ O` promise `project down` "stops … clusters … without
deleting them." The code's `clusterDown` (`Cluster/Lifecycle.hs:223-227`) runs `kind delete cluster`,
identical to `clusterDestroy`; only the retained derived-state paths differ. So `down` deletes the
kind cluster and the next `up` recreates it.

- **Recommended (doc-side relax):** correct `§ Y`, `§ O`, and `cluster_lifecycle.md:8-9/17-18/77-83`
  to state that stop-without-delete is a **VM-frame** capability (incus/Lima `stop`); at the **cluster
  (kind) frame**, `project down` deletes the kind cluster while preserving `.data`/durable state
  (kind has no reliable stop/restart). This keeps the contract honest with the shipped, sensible
  behavior and is a pure doc fix.
- **Alternative (code-side honor):** implement a real cluster stop — `docker stop` the kind node
  container(s) in `clusterDown`, `docker start` them on `up` — and keep the contract as written. This
  reopens phase-5/phase-16 with real-run validation and carries kind-restart fragility risk.
- **Recommendation:** doc-side relax (lower risk, preserves the monotonic narrative without expanding
  scope). Confirm if you'd rather implement the stop.

### 3.5 `dhall/Type.dhall` and the legacy-ledger correction — DECISION

`Type.dhall` is stale (no `ImageBuildContainer`/`topologyFrames`/`currentFrame`/`runtimeWitnesses`/
`ProviderKind`/`WitnessKind`; `Context.hs`/`example.dhall`/golden have them) and is not golden-tested,
so it silently re-drifts. `example.dhall` by contrast is a **live fixture** (`SchemaSpec.hs:196`
decodes it). The legacy ledger (lines 91-93) wrongly lists *both* as "Removed Surfaces … decoded
through `ProjectConfig`" though both exist and `ProjectConfig` is no longer a core type.

- **Recommended:** **delete `Type.dhall`** (the reflected schema via `context schema` / the golden
  `config_schema.dhall` is the source of truth; a hand-maintained `Type.dhall` only drifts). Keep
  `example.dhall`. Then fix the ledger: remove the bogus "Removed Surfaces" entry, add a **Removed
  Surfaces** entry for `Type.dhall` (now actually deleted), and add `example.dhall` to **Retained
  Current Surfaces** (live test fixture). Add a golden test guard for `example.dhall` so it cannot
  re-drift (completeness-gap G4).
- **Alternative:** regenerate `Type.dhall` from the reflected type and golden-test it. More surface to
  maintain. **Recommendation:** delete.

### 3.6 Doc-vs-code direction for the remaining genuine defects

Default: **fix the code** where it is a real bug/dead-code (§ 4); **fix the doc** where the code is the
intended behavior and only prose is wrong (§ 5). Each § 4 row states the direction explicitly.

---

## 4. Code & artifact fixes (the genuine defects)

These are the only non-doc changes. Each reopens its owning phase to `Active` (§ 6) until code-check
or real-run re-validates it. Small comment-only fixes that exist solely to make the command-surface /
chain-signature story true are folded into the consistency phase (§ 6, Phase 21) rather than reopening
a code phase.

| # | Defect | File(s) | Fix | Owning phase | Gate |
|---|--------|---------|-----|--------------|------|
| C1 | Standalone `ensure` verb exists though `ensure` is a library, not a command (your direction) | `Command.hs:96/121`, `Ensure.hs:99-106`, `CLI.hs:7-10`, `CLISpec.hs`, `EnsureSpec.hs` | Remove the `ensure` verb from `coreCommandNames` + wiring; keep `allReconcilers`/reconcilers/`ensure-*` `Step` kinds as the library; drop "hidden debug surface" text; update CLI/Ensure specs (§ 3.1) | 3 (+ surface in 16) | `cabal test` (CLISpec/EnsureSpec) |
| C2 | `Chain.hs`/`Step.hs` headers contradict + wrong type | `Chain.hs:3`, `Step.hs:3` | Identical generic `chain :: cfg -> [Step]` wording (§ 3.2) | 21 | `cabal build` |
| C3 | `clusterDown` deletes vs documented stop | `Cluster/Lifecycle.hs:223-227` | Per § 3.4 decision (recommend: no code change, doc relax) | 5/16 only if code-side chosen | real-run |
| C4 | `Type.dhall` stale, untested | `core/.../dhall/Type.dhall` | Delete (§ 3.5); add `example.dhall` golden guard | 8/15 | `cabal test` (DhallGenSpec) |
| C5 | `.gitignore` missing `.test_data/` | `.gitignore` | Add `.test_data/` next to `.data/` | 17 | manual / `git status` |
| C6 | `Container.hs` build #3 seam is dead code, docstring claims it runs the build | `Container.hs:1-11/47-54`, `Commands.hs:973-987` | Route `runVmBootstrap` build #3 through `dockerBuildArgs`/`buildProjectContainer` (preferred) **or** correct the docstring to "unit-tested argv helper, not on the prod path" | 13 | `cabal test` (demo) |
| C7 | `update --spec X --ref main` bypasses mutual-exclusion guard | `hostbootstrap/cli.py:285-286`, `self_update.py` | Detect explicit `--ref` via Click `ctx.get_parameter_source` instead of comparing to `DEFAULT_REF` | 6 | `test_all` (pytest) |
| C8 | ConfigMap injects helm message/replicas raw into a Dhall literal | `demo/chart/templates/configmap.yaml:123-124`, `Commands.hs:402-412` | Escape for Dhall (or document the plain-string constraint); cover `replicas` too (G8) | 20 | real-run / unit |
| C9 | `allReconcilers` Haddock says "six … plus incus" (it's seven+incus); `Hoist.hs:11` says "7-way ContextKind" (it's 8) | `Command.hs:76-89`, `Hoist.hs:11` | Correct both counts | 21 | `cabal build` |
| C10 | `base_image.py` docstring names non-existent `base push` | `hostbootstrap/base_image.py:4-5` | → `base build` / `base build-and-push` | 6 | `test_all` |

Decision-dependent rows: **C3** (only if § 3.4 code-side chosen). **C1** is recommended-YES per § 3.1.

---

## 5. Documentation rewrite plan, by surface

All edits apply the § 3 canonical decisions. Grouped so each topic is fixed in its canonical home
first, then propagated.

### 5.1 `DEVELOPMENT_PLAN/`

**`development_plan_standards.md` (authoritative — fix first):**
- §§ P (325), T (382-383), W (430), Y (509): `RootConfig -> [Step]` → `cfg -> [Step]` (§ 3.2).
- § P (320-321): keep the five user-facing verbs as the whole surface (no sixth/hidden entry).
- § L (full rewrite): the `ensure` reconcilers are a **library** of host-config primitives composed as
  `ensure-*` chain steps — drop "exposed as an optparse subcommand" and "standalone `ensure <tool>` …
  hidden debug surface"; keep the wrong-host applicability fail-fast (now at step-run time) (§ 3.1).
- § Y (526-528), § O: align the `project down` cluster-frame wording with § 3.4.

**`00-overview.md`:** chain signature (38, 224) → `cfg`; command-surface (43, 226) → canonical
statement; test totals (266, 279) → quote the SSoT line + label 237 historical; reconcile the
phase-19/20 narrative so phase-20's "no core change" matches 237→238.

**`README.md` (DEVELOPMENT_PLAN):** chain signature (35); command surface (43); test totals (49, 67,
80) → SSoT; foundation paragraph quotes the canonical surface + suite line.

**`system-components.md` (authoritative inventory — § F):** add the single canonical **current suite**
line and the **current command surface** line (the inventory is the SSoT both README and overview
quote); fix chain signature (46); reconcile context-subverb and Python-CLI enumerations (167, 196-202,
276) to one canonical list each (§ 5-R29); remove the `ensure` "hidden debug" row — `ensure` is a
reconciler library, not a command (§ 3.1) — and ensure the surface line reads the five verbs.

**`legacy-tracking-for-deletion.md`:** see § 7.

**Phase docs** — reconcile each to current state, add forward-pointers, relabel historical metrics
(§ 6 lists the status changes). Notable per-phase prose fixes:
- phase-4 (28-30, 44/59/109/143, 113-114, 140-141): five-verb surface (no `ensure` verb); chain → `cfg`;
  rewrite `ensure` as a composable reconciler library, not a subcommand.
- phase-5 (75, 202): delete the stale "still ships cluster"/"still exposes cluster status" clauses (R10).
- phase-7 (64-66): rewrite the superseded `--help` validation to the current surface or label superseded.
- phase-6 (95/107/120 vs 32): add `update` to the Sprint 6.2 enumerations or forward-point Sprint 6.5.
- phase-13 (80-111, 135-137, 53-58): relabel the deleted `vm/incus/harbor/web/role/deploy` noun verbs
  as historical pre-migration shape; chain → `demoChain :: ProjectConfig`.
- phase-15 (108, 196-198): label the `config init`/`context create` narrative superseded.
- phase-16 (9, 41, 43, 149, 251, 369): `coreCommandNames` → the five verbs (no `ensure`); chain → `cfg`
  for abstract, `demoChain :: ProjectConfig` for the demo.
- phase-3: rewrite the `ensure` suite as a reconciler **library** (composable `ensure-*` `Step` kinds),
  not an exposed optparse verb group; mark `Active` for the C1 verb removal (§ 6).
- phase-17 (152, 190): repoint the deleted `demo/.../Chain.hs` reference to `Commands.hs` (R-broken-ref).
- phase-19 (27, 88, 127, 161, 197, 226): label 232/237 historical; correct
  `psTestConfig :: tcfg -> IO cfg` → `tcfg -> IO [(Text, cfg)]` (the multi-variant list phase-20 needs).
- phase-8 (30-40), phase-11 (13, 31): merge the "None."/forward-pointer; make "is reopened" past tense.

### 5.2 `documents/`

Fix in canonical-home order, then deferring docs.

**architecture/ (canonical model homes):**
- `composition_methodology.md` (8-9, 41, 240-241): chain → `cfg`; command surface canonical.
- `hostbootstrap_core_library.md` (20, 23-25, 49-50, 79, 122, 146-149, 165, 193): chain → `cfg`;
  command surface (five verbs; `ensure` is a library, not a verb); remove `[ProjectCommand]`/"its own verbs" and the non-generic
  `projectSpec`/`withChain` signatures (reconcile with `library_hierarchy.md:13`, R12); align to
  `ProjectSpec cfg tcfg`.
- `library_hierarchy.md` (12, 18, 37, 62, 175): command surface; keep its correct generic chain.
- `generic_project_model.md` (85, 104): align `ProjectSpec` field sketch + surface.
- `python_haskell_boundary.md` (148-151), `build_and_run_model.md` (207, 222, 227),
  `run_models.md` (16, 84, 169), `harness_workflow.md` (41, 52-53): chain → `cfg`; surface canonical;
  mark the harness "Per-Variant Loop" as describing the project-seam-driven flow (align to `Harness.hs`
  `runMatrix`, R16) rather than overstating runMatrix's own logic.
- `binary_context_config.md` (23, 60, 76, 196, 276, 310): chain → `cfg`; fix the `renderComposition`
  description (drops `parentChain`; parent links come from `topologyParentId`); pick one frame-count
  framing (three-frame descent + service leaf) used consistently (R18); mark the Local-capability list
  "e.g." (R19).
- `dhall_generation.md` (15, 116, 168): chain → `cfg`; add `SecretRef` to the artifact list; align
  the frame-count to `binary_context_config.md`.

**engineering/ (schema is a key correctness fix):**
- `schema.md` (135, 137-146, 174-181): replace the wrong 8-constructor `CommandClass` block (rename
  `ContextInspectionCommand`→`ConfigInspectionCommand`; add `ConfigGenerationCommand`,
  `ContextCreationCommand`, `ClusterLifecycleCommand`) with the 11-constructor union from
  `Context.hs:149-161`/golden; fix the worked example so it decodes; better, direct readers to
  `<project> context schema` instead of a hand-maintained union (R7/R19).
- `code_check_doctrine.md` (38-42): name both lint samples (`core/app` **and** `daemon/app`) to match
  `basecontainer.Dockerfile:280-284` (R20).
- `cluster_lifecycle.md` (8-9, 17-18, 30, 77-83): chain → `cfg`; § 3.4 cluster-down wording.
- `gitignore_guardrails.md` (44, 48): once `.test_data/` is added to `.gitignore` (C5), the "covers all
  of the above" claim becomes true; otherwise correct it (R22).
- `playwright.md` (31, 36-37): describe the actual `--network host` + `BASE_URL=http://localhost:30080`
  e2e mechanism, not the superseded kind-network/control-plane hostname (R15).
- `secrets.md` (22-35): align the `SecretRef` constructors/`Prompt` to `Config/Vocab.hs:81-84`.
- `self_update.md` (61-63): align with the C7 guard fix.
- `cabal_layout.md` (89-91), `ensure_reconcilers.md` (18, 22-24, 173-174): the `--help`/surface lists
  the five verbs (no `ensure`); rewrite `ensure_reconcilers.md` so the reconcilers are a composable
  library run as chain steps, never a top-level verb (§ 3.1).
- `incus.md` (22, 23, 110, 117, 69), `lima.md` (9, 37): chain → `cfg`; standardize the step-kind
  spelling to `deploy-VM`; fix `lima.md:37`'s `--vm-type vz` to match the actual emitted limactl argv
  (verify against the VM-lifecycle builder; correct doc or note the flag) (R31).
- `derived_dockerfile.md` (48): show the full `project init` flag set (or a trailing `…`) (R31).
- `derived_project_standards.md` (29, 62, 233, 252): chain → `cfg` (reserve `ProjectConfig` for demo);
  fix `github.com/tuee22` → `github.com/Tuee22` casing; add `service` (R24/R31/repo-URL).
- `config_generation.md` (14, 26, 64, 146): chain → `cfg`; surface canonical; "reflected project-local
  config schema (labelled `projectConfig`)" wording (R31).
- `documentation_standards.md` (174, 178): expand § Validation to enumerate the governed-doc metadata
  fields (incl. `**Referenced by**:`) and the YAML-front-matter rejection the validator actually
  enforces; note link-resolution skips placeholder-shaped targets (R28); document the backlink-
  reciprocity stance (§ 8).
- Remaining engineering docs touched only by the two systemic sweeps (dhall_topology, composition_
  patterns, authoring_project_binaries, base_image, warm_store, etc.): apply § 3.1/§ 3.2 verbatim.

**operations/ + languages/:**
- `demo_runbook.md` (16, 56, 70, 96, 99, 256, 265, 294): chain → `cfg`/`demoChain`; surface canonical;
  e2e network mechanism (R15); `service run web` vs `service run` wording.
- `languages/*`: verify each "shipped in the base image" toolchain against `basecontainer.Dockerfile`;
  confirm the GHC `9.12.4` / Cabal `3.16.1.0` / fourmolu `0.19.0.1` / hlint `3.10` version quartet
  against the Dockerfile pins (G9); fix any drift.

### 5.3 `README.md` (root, governed orientation)

- Chain signature (44, 74, 284) → `cfg` (or `demoChain :: ProjectConfig` where the demo is meant).
- Command surface prose (72, 235-238) → canonical five-verb statement; **remove** the `ensure`
  "Hidden debug" row from the CLI Surface table (ensure is a library, not a command) and make sure the
  table carries a `service` row, so table and prose both read the five verbs.
- Keep README a thin orientation layer that quotes the `system-components.md` SSoT for counts/surface,
  not a parallel canonical home (standards § J).

### 5.4 `AGENTS.md` / `CLAUDE.md`

- Restore the missing normative paragraph to `AGENTS.md` (the "If a workflow step appears to require a
  commit … stop and ask the user. Do not work around the rule." block present in `CLAUDE.md:16-19`,
  absent from `AGENTS.md`) so both entry docs carry identical *rules* (only Claude↔agent branding
  differs) — G1 / standards § J.

---

## 6. Phase status changes (reopening map)

New phase **21 — Documentation/Code Consistency Reconciliation** owns the cross-cutting sweep (the
two systemic standardizations, the stale-prose cleanup, the comment-only code fixes C1/C2/C9, and the
governance edits). Adding it updates `development_plan_standards.md § E`, `README.md`, `00-overview.md`,
and `system-components.md` in the same change (standards § E).

| Phase | New status | Reason / Remaining Work | Validation gate |
|-------|-----------|--------------------------|-----------------|
| 21 (new) | `Active` | The repo-wide doc/comment sweep (§ 3.1–3.3, § 5), C2/C9, governance edits, backlink pass | `cabal test` (DocValidator) + manual review |
| 3 | `Active` | C1 — remove the `ensure` verb; rewrite the suite as a composable reconciler library | `cabal test` (CLISpec/EnsureSpec) |
| 5 | `Active` only if § 3.4 code-side chosen; else stays `Done` (doc fix only) | C3 cluster stop | real-run |
| 6 | `Active` | C7 update guard, C10 docstring | `test_all` |
| 8 | `Active` | C4 Type.dhall delete + golden guard | `cabal test` |
| 13 | `Active` | C6 Container.hs build-#3 seam | `cabal test` (demo) |
| 17 | `Active` | C5 `.gitignore .test_data/` | `git status` |
| 20 | `Active` | C8 ConfigMap escaping (message + replicas) | real-run / unit |
| 0 | stays `Done` | Owns governance; the doc reconciliation is a § A follow-on tracked by phase 21 | — |
| 1,2,7,9,10,11,12,14,18,19 | stay `Done` | Scope complete; only prose drift, corrected in-place this change | `cabal test` |

**Forward-only guarantee:** every reopening above is a self-contained defect in that phase's own
scope; none is a prerequisite another phase consumes, so all other phases stay `Done`
(development_plan_standards § C). No earlier phase is reopened by a later phase's work, and no phase's
validation is gated on another phase's reopened item. Each reopened phase gets a `## Remaining Work` /
`Remaining Work` sprint section (standards § C/§ G) naming exactly its item and gate; when the fix
lands and validates, status returns to `Done` and the entry moves out of Remaining Work.

---

## 7. `legacy-tracking-for-deletion.md` updates

- **Remove** the stale "Removed Surfaces" entry at lines 91-93 (`Type.dhall` + `example.dhall` …
  "decoded through `ProjectConfig`") — it is wrong on three counts (files exist; `example.dhall` is
  live; `ProjectConfig` is not a core type).
- **Add to Removed Surfaces:** `core/hostbootstrap-core/dhall/Type.dhall` — deleted (§ 3.5); the schema
  source of truth is the reflected `context schema` / golden `config_schema.dhall`. Owning phase: 8.
- **Add to Retained Current Surfaces:** `core/hostbootstrap-core/dhall/example.dhall` — live schema
  fixture decoded by `SchemaSpec`; now golden-guarded (G4).
- **Add to Removed Surfaces (after C1 lands):** the standalone `ensure <tool>` top-level command —
  `ensure` is a reconciler **library** composed as `ensure-*` chain steps, **not** a CLI verb; there
  are no hidden commands. The reconcilers/`Step` kinds are retained (library surface). Owning phase: 3.
- Audit the ledger's own `ProjectConfig`-as-core-type references (e.g. line 93, 107-109, 138) and
  reword to "the demo's `ProjectConfig`" / "the project's `cfg`" consistent with § BB.
- Keep `Pending` empty if all cleanup lands in this change (empty `Pending` is valid, § I rules).

---

## 8. Backlink & cross-reference integrity pass

The `DocValidator` checks only that a `**Referenced by**:` line *exists* and that *forward* links
resolve — never that named back-referrers actually link back. The review found non-reciprocal
backlinks (e.g. `applied_cordon.md` claims `cluster_lifecycle.md` references it; it does not — and ~22
similar). Plan:

1. Mechanically diff every `**Referenced by**:` target against whether that target actually links back;
   fix each by either adding the missing link or correcting the `Referenced by` list (G2).
2. **DECISION (recommend YES):** add a `checkBacklinkReciprocity` check to `DocValidator` (+
   `DocValidatorSpec` coverage) and document it in `documentation_standards.md § Validation`, so this
   class can't silently re-drift. If declined, leave the validator as-is and only fix the data.
3. Verify every changed relative link still resolves (the sweep moves/renames nothing, but `phase-17`'s
   repointed `Chain.hs`→`Commands.hs` reference must resolve).

---

## 9. Execution sequence

Ordered so each canonical decision is fixed at its source before propagation, and so the doc that
describes a behavior is edited only after the code reaches its final shape:

1. **Confirm the two open DECISIONS** (§ 3.4 cluster-down, § 3.5 Type.dhall) and the § 8 validator
   decision. (§ 3.1 is resolved: `ensure` verb removed, no hidden commands.)
2. **Code fixes (§ 4)** — C1, C2, C9 (comment/flag), C4 (delete Type.dhall + golden guard), C5, C6,
   C7, C8, C10; C3 only if code-side. Run `cabal test` and `test_all`; **re-count the test total**.
3. **Authoritative sources** — `development_plan_standards.md` (§§ P/T/W/Y/L/O/Y wording),
   `system-components.md` (SSoT surface + suite lines), `legacy-tracking-for-deletion.md` (§ 7), add
   **Phase 21**.
4. **DEVELOPMENT_PLAN narrative** — `00-overview.md`, `README.md`, every phase doc (§ 5.1, § 6 status +
   Remaining Work), with forward-pointers and relabelled historical metrics.
5. **`documents/`** — architecture (canonical homes) → engineering → operations → languages (§ 5.2),
   applying the two systemic sweeps + the per-doc fixes.
6. **Root `README.md`** + **`AGENTS.md`/`CLAUDE.md`** (§ 5.3-5.4).
7. **Backlink/cross-reference pass** (§ 8) + write the re-counted SSoT total.
8. **Validate** (§ 10). Iterate until green. Move reopened phases back to `Done`. Delete this file.

## 10. Validation plan

- **`cabal test` from `core/`** — runs `DocValidatorSpec` (metadata, root-doc, broad-doctrine, links,
  README refs, naming, taxonomy, doc-requirements; + the new backlink check if § 8 adopted), plus
  `CLISpec`/`EnsureSpec` (assert the five-verb surface + the reconciler library — no `ensure` verb),
  `SchemaSpec`/`DhallGenSpec` (schema
  + `example.dhall`/golden guards), and the full unit suite. Record the final core total for the SSoT.
- **`poetry run python -m hostbootstrap.check_code`** and **`… test_all`** — Python gate for C7/C10
  (coverage stays `fail_under=100`).
- **`cabal build all --ghc-options=-Werror`** + **fourmolu/hlint** on core and demo — for C1/C2/C6/C9.
- **Real-run** (operator) — only if § 3.4 code-side (C3) or for C8's live ConfigMap path; otherwise the
  demo lifecycle is unchanged.
- **Manual editorial pass** — confirm one canonical statement of surface + chain signature + suite
  total appears repo-wide and no phase narrative contradicts an earlier phase.

---

## 11. Traceability matrix (every finding → action)

R = ranked review issue; G = completeness-gap follow-up. "Sweep" = the § 3.1/§ 3.2 repo-wide
standardization.

| ID | Finding | Sev | Action | § |
|----|---------|-----|--------|---|
| R1 | Command surface enumerated 3 ways | high | Sweep to canonical **five** verbs; `ensure` is library-only (C1) | 3.1, 5 |
| R2 | Chain.hs/Step.hs/CLI.hs comments contradictory + wrong hidden-ensure | high | C1, C2 | 3.1, 3.2, 4 |
| R3 | Chain signature stale types repo-wide | high | Sweep to `cfg` | 3.2, 5 |
| R4 | `ensure` is a library tool, not a command (no hidden commands) | high | C1 (remove the `ensure` verb) | 3.1, 4 |
| R5 | Test total 226/232/237/238 | high | SSoT in system-components; relabel history | 3.3, 5.1 |
| R6 | `project down` doc stop vs code delete | high | § 3.4 decision (C3 or doc relax) | 3.4 |
| R7 | schema.md CommandClass wrong (non-existent constructor) | high | Rewrite to 11-constructor union | 5.2 |
| R8 | Type.dhall stale | high | C4 delete + ledger fix | 3.5, 4, 7 |
| R9 | phase-13 deleted noun verbs as current | high | Relabel historical | 5.1 |
| R10 | phase-5 self-contradiction | high | Delete stale clauses (75, 202) | 5.1 |
| R11 | phase-4/7 superseded surfaces as current | high | Add `service` + forward-pointers | 5.1 |
| R12 | library_hierarchy vs core_library ProjectSpec/ProjectCommand | med | Reconcile core_library to generic code | 5.2 |
| R13 | phase-19 232 vs 237 in one doc | med | Label per-sprint historical | 3.3, 5.1 |
| R14 | 237 vs live 238 | med | SSoT + relabel | 3.3, 5.1 |
| R15 | playwright/demo_runbook e2e network stale | med | Doc → `--network host`+localhost | 5.2 |
| R16 | harness_workflow per-variant loop overstated | med | Align doc to `runMatrix` | 5.2 |
| R17 | fixed-config chain signature as current | med | Sweep to `cfg` | 3.2, 5 |
| R18 | context render / frame-count divergence | med | Fix render desc; one frame-count framing | 5.2 |
| R19 | schema.md broken-ref + capability example | med | With R7; mark capability list "e.g." | 5.2 |
| R20 | in-Dockerfile code-check lints daemon/app too | med | Doc both sample paths | 5.2 |
| R21 | cabal_layout/ensure_reconcilers omit service | med | Add `service` | 3.1, 5.2 |
| R22 | .gitignore missing .test_data/ | med | C5 | 4, 5.2 |
| R23 | Container.hs build #3 dead seam | med | C6 | 4 |
| R24 | derived_project_standards/phase-16 ProjectConfig/RootConfig split | med | Sweep to `cfg`/demo | 3.2, 5 |
| R25 | allReconcilers/Hoist miscounts | med | C9 | 4 |
| R26 | update --spec/--ref guard bypass | low | C7 | 4 |
| R27 | ConfigMap raw Dhall injection (message) | low | C8 | 4 |
| R28 | documentation_standards §Validation under-reports; validator edge cases | low | Expand §Validation; (opt) strip inline code spans, add negative root-doc test | 5.2, 8 |
| R29 | context subverbs / Python CLI / phase-6 enumerations | low | One canonical list each; add `update` | 5.1 |
| R30 | phase-doc clarity leftovers (phase-8/11/13, currentSelfRef path) | low | Merge None./forward-pointer; past-tense "reopened"; note 3/3→6/6; document fixed in-VM path | 5.1 |
| R31 | misc broken refs/casing/skeleton (base push, deploy-vm/VM, init skeleton, projectConfig) | low | C10 + doc fixes | 4, 5.2 |
| G1 | CLAUDE.md/AGENTS.md missing paragraph | — | Restore to AGENTS.md | 5.4 |
| G2 | Referenced-by backlinks non-reciprocal | — | Backlink pass; (opt) validator check | 8 |
| G3 | `service` subverb (`init\|schema\|run`) not enumerated | — | Add `service schema` to surface enumerations | 5.1 |
| G4 | Type.dhall/example.dhall not golden-tested | — | Golden-guard example.dhall | 3.5, 4 |
| G5 | port chain 8080→30080 trace | — | Verify service.yaml/deployment.yaml/values/kind/Commands; align docs | 5.2 |
| G6 | Core.dhall budget-helper doc agreement | — | Cross-check documented `fitsWithin`/`split`… vs Core.dhall exports | 5.2 |
| G7 | ServiceType↔ServiceHandler `web` coupling | — | Confirm `"web"` matches a Dhall `ServiceType` constructor; align docs | 5.2 |
| G8 | ConfigMap replicas raw injection | — | C8 (cover replicas too) | 4 |
| G9 | GHC/Cabal/fourmolu/hlint version quartet vs Dockerfile | — | Grep Dockerfile pins; align language/eng docs | 5.2 |
| G10 | freeze import path `/opt/basecontainer/haskell-deps/` vs Dockerfile stage | — | Confirm path equality | 5.2 |
| G11 | optimization/tests/benchmarks/shared flag quartet across 4 project files | — | Diff the flag block; align | 5.2 |
| — | Repo-URL casing `tuee22` vs `Tuee22` | low | Standardize GitHub org to `Tuee22` (docker.io `tuee22` stays) | 5.2 |

**Refuted (no action):** "phase-10 Sprint 10.5 omits service" and "phase-8 158-tests vs others" — the
adversarial verifier correctly found both are correctly-scoped per-sprint history, not defects.

---

## Open decisions for your confirmation

1. **§ 3.1 — RESOLVED (your direction):** no hidden commands; `ensure` is a library, not a command.
   The standalone `ensure` verb is removed; the reconcilers/`Step` kinds stay as composable library
   primitives. Canonical surface = five verbs.
2. **§ 3.4** — `project down` cluster frame: relax the doc to "delete + preserve `.data`" (recommended)
   vs implement a real `docker stop` cluster-stop (reopens phase-5/16).
3. **§ 3.5** — delete `Type.dhall` (recommended) vs regenerate + golden-test it.
4. **§ 8** — add a backlink-reciprocity check to `DocValidator` (recommended) vs fix the data only.

On your confirmation I will execute § 9 in order.
