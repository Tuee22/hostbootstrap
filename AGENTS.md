# Agent Instructions

- Never run `git add`, `git commit`, or `git push`.
- Git staging, committing, and pushing are reserved for the human user.
- You may inspect repository state with read-only Git commands when useful.

## Development commands

- `check_code` and `test_all` are Python modules, not shell commands on `PATH`.
- Run code checks with `poetry run python -m hostbootstrap.check_code`.
  - Defined in `hostbootstrap/check_code.py`.
  - Runs `ruff check hostbootstrap stubs`, `black --check hostbootstrap stubs`,
    then `mypy hostbootstrap`.
- Run the full test suite with `poetry run python -m hostbootstrap.test_all`.
  - Defined in `hostbootstrap/test_all.py`.
  - Sets the `HOSTBOOTSTRAP_TEST_ALL` sentinel and invokes `pytest tests`
    in-process.
  - Forward pytest args after the module name, for example
    `poetry run python -m hostbootstrap.test_all -k docker_ops -q`.
- Run coverage with
  `poetry run python -m coverage run -m hostbootstrap.test_all && poetry run python -m coverage report -m`.
  - Coverage is configured in `pyproject.toml` with `fail_under = 100`.
- Do not invoke `pytest` directly; `tests/conftest.py` requires the
  `hostbootstrap.test_all` runner. The sentinel is a guardrail for one supported
  suite entry point, not a claim that `-k` or other forwarded pytest filters are
  disabled.
