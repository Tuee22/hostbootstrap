# Claude Instructions

**Status**: Governed entry document
**Supersedes**: prior root CLAUDE.md without metadata
**Canonical homes**: [documents/documentation_standards.md](documents/documentation_standards.md), [DEVELOPMENT_PLAN/development_plan_standards.md](DEVELOPMENT_PLAN/development_plan_standards.md), [documents/README.md](documents/README.md)

> **Purpose**: Thin entry document that points Claude-style agents at the canonical documentation and
> development-plan rules and states the non-negotiable git-history boundary for this repository.

Instructions for Claude and other LLM-based coding assistants working in this repository.

## Non-negotiable rules

Git history is **exclusively a user-controlled domain**. LLM assistants must never perform any of the
following:

- never run `git add`
- never run `git commit`
- never run `git push`

Staging, committing, and pushing are reserved for the human user. An assistant may edit files, run
read-only Git commands (`git status`, `git diff`, `git log`, `git blame`), and propose commit
messages or PR descriptions in chat — but it must not perform the staging or commit itself.

If a workflow step appears to require a commit (for example, a CI check that runs against `HEAD`
rather than the working tree), stop and ask the user to perform the commit. Do not work around the
rule.

## Scope

`hostbootstrap` is a dual-language repository: a Haskell `hostbootstrap-core` library plus a thin
Python bootstrapper. See [README.md](README.md) for the architecture and
[documents/architecture/python_haskell_boundary.md](documents/architecture/python_haskell_boundary.md)
for the ownership boundary between the two.

## Repository layout

The repository is split by language: `haskell/` holds the `hostbootstrap-core` Cabal package, the
`haskell/cabal.project` workspace file, and `haskell/haskell-deps/` (the warm-store package), while
`python/` holds the Poetry project (the `hostbootstrap` CLI distribution, its `tests/`, and
`stubs/`). The `demo/` consumer carries its own `demo/cabal.project`. The root carries `docker/`,
`documents/`, and `DEVELOPMENT_PLAN/` and no Cabal project file.

## Development commands

### Haskell core

- `hostbootstrap-core` (under `haskell/hostbootstrap-core/`) is built and tested with Cabal against
  the pinned GHC, driven by `haskell/cabal.project`.
- Build the library with `cabal build` (from `haskell/`).
- Run the Haskell tests with `cabal test` (from `haskell/`).
- The Haskell quality gate (formatter check, linter, type-correct build) runs through the project's
  canonical code-check.

### Python bootstrapper

- Run all Python commands from the `python/` directory (the Poetry project root).
- `check_code` and `test_all` are Python modules, not shell commands on `PATH`.
- Run code checks with `poetry run python -m hostbootstrap.check_code`.
  - Runs `ruff check hostbootstrap stubs`, `black --check hostbootstrap stubs`, then
    `mypy hostbootstrap`.
- Run the full test suite with `poetry run python -m hostbootstrap.test_all`.
  - Sets the `HOSTBOOTSTRAP_TEST_ALL` sentinel and invokes `pytest tests` in-process.
  - Forward pytest args after the module name, for example
    `poetry run python -m hostbootstrap.test_all -k docker_ops -q`.
- Run coverage with
  `poetry run python -m coverage run -m hostbootstrap.test_all && poetry run python -m coverage report -m`.
  - Coverage is configured in `python/pyproject.toml` with `fail_under = 100`.
- Do not invoke `pytest` directly; `python/tests/conftest.py` requires the `hostbootstrap.test_all` runner.
  The sentinel is a guardrail for one supported suite entry point, not a claim that `-k` or other
  forwarded pytest filters are disabled.

## Base image: rebuild → republish → pull

The published `docker.io/tuee22/hostbootstrap:basecontainer-<flavor>-<arch>` tags are the **source of
truth** every derived project (including `demo/`) builds `FROM`. When you change
`docker/basecontainer.Dockerfile` or the warm-store inputs under `haskell/haskell-deps/` (the layer
manifests, the `*.project` files, or the `core.freeze`/`daemon.freeze` projection), the published base
no longer matches the repo. You MUST then **rebuild and republish** the affected base tag and have
consumers **pull** the republished tag.

- Do **not** work around a stale published base by pointing a consumer at a freeze name the published
  base does not yet ship (for example, editing a derived project's `container.cabal.project` import).
- Do **not** build the base locally and build derived projects against the un-republished local image —
  that hides the drift between the repo and Docker Hub.
- The canonical command is `hostbootstrap base build-and-push --flavor <f> --arch <a>` (plain
  single-arch `docker build` + `docker push`, host-native, no buildx). See
  [documents/engineering/base_image.md](documents/engineering/base_image.md) and
  [documents/engineering/build_release.md](documents/engineering/build_release.md).

Republishing pushes to the user's Docker Hub namespace — an outward-facing publish an assistant performs
**only when the user directs it**. It is a container-registry push, **not** a git operation, so it is
outside the git-history boundary above.
