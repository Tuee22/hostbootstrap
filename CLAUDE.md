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

## Development commands

### Haskell core

- `hostbootstrap-core` is built and tested with Cabal against the pinned GHC.
- Build the library with `cabal build`.
- Run the Haskell tests with `cabal test`.
- The Haskell quality gate (formatter check, linter, type-correct build) runs through the project's
  canonical code-check.

### Python bootstrapper

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
  - Coverage is configured in `pyproject.toml` with `fail_under = 100`.
- Do not invoke `pytest` directly; `tests/conftest.py` requires the `hostbootstrap.test_all` runner.
  The sentinel is a guardrail for one supported suite entry point, not a claim that `-k` or other
  forwarded pytest filters are disabled.
