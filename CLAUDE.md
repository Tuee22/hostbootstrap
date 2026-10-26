# Claude Instructions

**Status**: Governed entry document
**Supersedes**: prior root CLAUDE.md without metadata
**Canonical homes**: [documents/documentation_standards.md](documents/documentation_standards.md), [DEVELOPMENT_PLAN/development_plan_standards.md](DEVELOPMENT_PLAN/development_plan_standards.md), [documents/README.md](documents/README.md)

> **Purpose**: Thin entry document that points Claude-style agents at the canonical documentation and
> development-plan rules and states the non-negotiable git-history boundary for this repository.

Instructions for Claude and other LLM-based coding assistants working in this repository.

## Non-negotiable rules

Git history is **exclusively a user-controlled domain**. Assistants must never perform any of the
following:

- never run `git add`
- never run `git commit`
- never run `git push`

Staging, committing, and pushing are reserved for the human user. An assistant may edit files, run
read-only Git commands (`git status`, `git diff`, `git log`, `git blame`), and propose commit
messages or PR descriptions in chat — but it must not perform the staging or commit itself.

"Pushing" here means `git push`. Building and publishing the base container images to Docker Hub is a
separate registry operation, not a git operation, and assistants perform it as required (see the base-image
section below).

If a workflow step appears to require a commit (for example, a CI check that runs against `HEAD`
rather than the working tree), stop and ask the user to perform the commit. Do not work around the
rule.

## No manual log files

Do not create manual log files anywhere in the working tree, and **never create a file with a `.log`
extension** while doing work. When you need to capture the output of a long-running or background
command, rely on the harness's own output capture (background-task output files, monitors) — never
redirect or `tee` command output into a file under the repository (for example, do not `... > run.log`,
`... >> deploy.log`, or `tee build.log`). Hand-made log files clutter the tree, risk being staged by
accident, and duplicate output the harness already retains. If you encounter a stray `.log` file in the
working tree (for example a leftover `deploy.log`), delete it. If a run genuinely needs a persisted
artifact, ask the user where it should live rather than dropping a log into the repo.

## Removals must be statically resolvable

Write every `rm`/`rmdir` so its target resolves **before** the shell expands it, in any harness. Claude Code carries
a `dangerousRemoval` circuit breaker that raises a permission prompt for removal targets it cannot
resolve statically, and that prompt is **not** suppressed by `bypassPermissions` ("yolo") mode, by
the auto-approve classifier, or by a `Bash(rm:*)` allow rule. Rewriting the command is the only way
to avoid it.

A target is statically resolvable when it is an **absolute path**, its command contains **no `cd`**,
and **at most one path segment is globbed**. Targets containing `..` after a real segment, `$VAR`,
`$(...)`, or `~user` are never resolvable.

```bash
# prompts — cd plus a relative glob target
cd demo && rm -rf .data/*

# prompts — two globbed segments
rm -rf demo/.data/*/*

# clean — absolute, no cd, one glob level
rm -rf /abs/path/to/hostbootstrap/demo/.data/*
```

Assistants should build an absolute path from the working directory the harness reports rather than
`cd`-ing into a subdirectory first.

## Line endings

The repository's canonical line ending for all text files is **LF**. The policy is defined by
[`.gitattributes`](.gitattributes) (with [`.editorconfig`](.editorconfig) as the editor-level companion),
which is **authoritative** — do not rely on per-machine `core.autocrlf` for correct behavior. Its CRLF rule
for `.bat`, `.cmd`, and `.ps1` is defensive normalization only: § KK keeps scripts out of the repository.

- New files use LF; never add a script to the repository (§ KK).
- Assistants must not intentionally change line endings.
- If a file appears changed only because of CRLF/LF conversion, **investigate before committing**
  rather than staging the churn.
- Avoid commits that consist only of accidental line-ending churn.

## Scope

`hostbootstrap` is a dual-language repository: a Haskell `hostbootstrap-core` library plus a thin
Python bootstrapper. See [README.md](README.md) for the architecture and
[documents/architecture/python_haskell_boundary.md](documents/architecture/python_haskell_boundary.md)
for the ownership boundary between the two.

## Repository layout

The Haskell core lives under `core/`: the `hostbootstrap-core` Cabal package, the
`core/cabal.project` workspace file, and `core/warm-deps/` (the warm-store Cabal project, two
dependency-group packages). The Poetry project (the `hostbootstrap` CLI distribution) is rooted at
the repository root — `pyproject.toml`, the `hostbootstrap/` package, and its `tests/`. The `demo/`
consumer carries its own `demo/cabal.project`. The root also carries `docker/`, `documents/`, and
`DEVELOPMENT_PLAN/` and no Cabal project file.

## Working the development plan

`DEVELOPMENT_PLAN/` is a work queue, not just a record. When asked to advance the project:

1. Read the status table in [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md). It is the sole
   cross-phase status authority; no other document's prose overrides it.
2. Take the **lowest-numbered `Active` phase**. Phase numbers are the dependency order: a phase depends
   only on lower-numbered phases, so the four acceptance phases (26 to 29) come last. Acceptance phases
   are terminal and none depends on another, so one whose hardware the session lacks stays `Active` and
   the next is taken.
3. Inside it, work the sprints in order — the `Active` sprint first, then each `Planned` one. A sprint
   is one working session: § G caps it at roughly 400 lines of production Haskell across at most three
   source modules, and a sprint that outgrows that is split rather than stretched.
4. Close a sprint by filling in its `#### Validation` with what actually ran, and setting its
   `#### Remaining Work` to `None.`
5. Close the phase by re-running **its own declared `**Gate**`** — not a convenient subset — and
   recording a `**Gate evidence**` row. A deferred phase also re-measures the digest over its
   `**Evidence covers**` paths. Then set the phase `Done` in both its header and the README table;
   `checkPhaseStatusHarmony` fails if the two disagree.

Two things that will bite otherwise:

- **Editing any source file expires the completion evidence of every `Done` deferred phase whose
  `**Evidence covers**` set contains it**, and `cabal test all` then fails through `DocValidatorSpec`.
  That is the validator working, not a regression. Set each such phase `Active` in the same change that
  edits the covered path, naming the sprint that owes the re-run in its `## Remaining Work`; § C calls
  this evidence expiry, which is not a design-error reopening.
- The acceptance phases (Apple Silicon, NVIDIA, Windows/WSL2, host portability) close **last**, once no
  lower phase carries open work, because each covers the host-portable tree and any earlier change
  re-owes their runs.

[DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md](DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md)
lists shapes still standing that the architecture does not want, each with the phase that deletes it.
It schedules nothing on its own; the deleting phase's own sprints do that.

## Development commands

### Haskell core

- `hostbootstrap-core` (under `core/hostbootstrap-core/`) is built and tested with Cabal against
  the pinned GHC, driven by `core/cabal.project`.
- Build the library with `cabal build all` (from `core/`).
- Run the Haskell tests with `cabal test all` (from `core/`).
- Run the worked consumer the same way from `demo/`. The `demo/` leg is part of the gate, not an extra.
- `-Werror` needs no flag. `hostbootstrap-core` and `hostbootstrap-demo` carry it in their
  `common warnings` stanza, so a plain `cabal build` holds exactly the policy a phase closes on and a
  warning cannot land unnoticed.
- The Haskell formatter and linter (`fourmolu`, `hlint`) run in the base publisher's source gate and in a
  derived image's `check-code`, never in the host static gate; see
  [documents/engineering/code_check_doctrine.md](documents/engineering/code_check_doctrine.md#where-the-style-tools-run).

### Python bootstrapper

- Run all Python commands from the repository root (the Poetry project root).
- `check_code` and `test_all` are Python modules, not shell commands on `PATH`.
- Run code checks with `poetry run python -m hostbootstrap.check_code`.
  - Runs `ruff check hostbootstrap`, `black --check hostbootstrap`, then `mypy hostbootstrap`.
- Run the full test suite with `poetry run python -m hostbootstrap.test_all`.
  - Sets the `HOSTBOOTSTRAP_TEST_ALL` sentinel and invokes `pytest tests` in-process.
  - Forward pytest args after the module name, for example
    `poetry run python -m hostbootstrap.test_all -k docker_ops -q`.
- Run coverage with
  `poetry run python -m coverage run -m hostbootstrap.test_all && poetry run python -m coverage report -m`.
  - Coverage is configured in `pyproject.toml` with `fail_under = 100`.
- Do not invoke `pytest` directly; `tests/conftest.py` requires the `hostbootstrap.test_all` runner.
  The sentinel is a guardrail for one supported suite entry point, not a claim that `-k` or other
  forwarded pytest filters are disabled.

## Running tests on Windows

The fast suites need no durable launcher on any platform. The **host static gate** is these four
commands, each run from the repository root; run them foreground and iterate normally, on Windows as
elsewhere:

```bash
cd core && cabal test all
cd demo && cabal test all
poetry run python -m hostbootstrap.check_code
poetry run python -m hostbootstrap.test_all
```

§ JJ of
[DEVELOPMENT_PLAN/development_plan_standards.md](DEVELOPMENT_PLAN/development_plan_standards.md) is
canonical for that list, and this file does not restate it in a second spelling. Dropping
`check_code` or the `demo/` leg runs a strictly weaker gate than the one a phase closes on, and the
difference is silent.

The Python legs finish in seconds; the Cabal legs take minutes. The 2026-10-22 native Windows run records
380 seconds for the `core/` leg and 529 seconds for the `demo/` leg, and an earlier native Windows `core/`
run took 1,244 seconds including test compilation. A 10-minute per-command tool timeout is therefore no
safe margin: give each Cabal leg an explicit timeout at the tool's maximum, and treat a timeout as an
unfinished run, not a passing or failing one. The dated durations are in
[host-portability acceptance](DEVELOPMENT_PLAN/phase-29-host-portability-acceptance.md).

The gate is expected to *pass* natively on Windows, not merely to
run: the project binary is built host-native on every substrate, so its sources and suites are
host-portable. A failure that turns out to be a POSIX-only fixture, a native path separator, or a
locale-decoded source read is a defect in the suite rather than an expected platform limit. The gate
kinds and the rules the harness holds are canonical in
[documents/engineering/testing.md](documents/engineering/testing.md), and each is owned by a phase in
[DEVELOPMENT_PLAN/](DEVELOPMENT_PLAN/README.md).

The **long demo gate** runs from the repository root through the Python bootstrapper:
`poetry run hostbootstrap run --project-root demo test init` (a short foreground call the matrix needs
first), then `poetry run hostbootstrap run --project-root demo test run all`, and the same route's
`project up`. It is different **on Windows only**. Budget hours, not minutes; the dated run durations are
recorded in [the NVIDIA GPU phase](DEVELOPMENT_PLAN/phase-27-nvidia-gpu-substrate.md) and
[the Windows and WSL2 phase](DEVELOPMENT_PLAN/phase-28-windows-and-wsl2-substrate.md). In any harness,
launch it outside the assistant's own process tree and poll an exit sentinel. Under Claude Code, a naive
`run_in_background` shell is a descendant of `claude.exe` and gets force-killed mid-run by the
harness's own reaper (`taskkill /PID <pid> /T /F`). To run it durably there on Windows:

- launch it out of `claude.exe`'s process tree with the harness-owned
  `%USERPROFILE%\.claude\hostbootstrap\Start-DurableRun.ps1`, then poll the printed `<label>.exit`
  sentinel with the `ScheduleWakeup` tool;
- **never** launch the gate as a naive `run_in_background`, and never use a `run_in_background`
  sleep-loop "waiter" (the waiter is itself reaped and produces false "killed" alarms).

A `PreToolUse` guard (`%USERPROFILE%\.claude\hostbootstrap\guard-durable-run.ps1`) enforces this on
Windows and no-ops on macOS/Linux. Both files live in the Claude harness's own configuration rather
than in this repository, because the reaper they exist for is a property of that harness and not of
this project (§ KK); the repository carries no script. **On macOS/Linux, run the gate normally** — none
of this applies. Full mechanism, root cause, and how to install the two files on a fresh Windows
machine: [documents/engineering/durable_windows_runs.md](documents/engineering/durable_windows_runs.md).

## Base image: rebuild → republish → pull

The published rolling `docker.io/tuee22/hostbootstrap:basecontainer-<flavor>-<arch>` tags are the
**source of truth** every derived project (including `demo/`) builds `FROM`. When you change
`docker/basecontainer.Dockerfile` or the warm-store inputs under `core/warm-deps/`, the published base
no longer matches the repo. You MUST then **rebuild and republish** the affected base tag and have
consumers **pull** the republished tag. A rebuild intentionally discovers current compatible upstream
versions; it is not required to replay a committed input lock.

- Consumers use the same host-compatible `cabal.project` inside and outside containers. Do not add
  `/opt/basecontainer/...` freeze imports or a container-only project; the inherited Cabal store is only
  an opportunistic cache and misses may resolve and build normally.
- Do **not** build the base locally and build derived projects against the un-republished local image —
  that hides the drift between the repo and Docker Hub.
- The canonical command is `poetry run hostbootstrap base build-and-push --flavor <f> --arch <a>`
  (single-arch and host-native, no buildx): it runs the repository source preflight, cold-builds with plain
  `docker build`, smoke-builds a compatibility consumer against the local image, pushes, then pulls the
  published tag and smoke-builds against its digest. `base` is a maintainer
  command of the **Python bootstrapper**, gated to the repository Poetry environment; it is not
  reachable from a pipx install. See
  [documents/engineering/base_image.md](documents/engineering/base_image.md) and
  [documents/engineering/build_release.md](documents/engineering/build_release.md).

**Assistants build and publish the base images to Docker Hub as required.** This is standing authority, not
a request to repeat: when `docker/basecontainer.Dockerfile` or the inputs under `core/warm-deps/` differ from
those of the publication recorded in the owning development-plan sprint, an assistant runs the canonical command
itself on a native host of that architecture and records the pulled digest the command reports as dated
evidence in that sprint (see
[publication authority](documents/engineering/base_image.md#publication-authority)). It publishes only the affected
tags, uses the host's existing `docker login`, and never prints, copies, or writes the credential. It reports
an architecture with no native host in the session as outstanding instead of emulating it, and reports which
rolling tags changed if one flavor fails after another was pushed. Publishing is a container-registry push,
**not** a git operation, so it is outside the git-history boundary above: `git add`, `git commit`, and
`git push` stay forbidden.
