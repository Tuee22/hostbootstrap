# hostbootstrap (Python bootstrapper)

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../documents/architecture/python_haskell_boundary.md](../documents/architecture/python_haskell_boundary.md)

> **Purpose**: Orient readers to the `python/` subtree — the thin Python bootstrapper that runs before
> any project binary exists — and point at the canonical architecture and engineering docs.

The `python/` subtree is the thin Python bootstrapper half of `hostbootstrap`. The Haskell
`hostbootstrap-core` library that owns the host-management logic lives under
[`../haskell/`](../haskell/); the repository [`../README.md`](../README.md) is the overall
orientation document.

## Layout

```text
python/
├── pyproject.toml        # Poetry project (the `hostbootstrap` CLI distribution)
├── hostbootstrap/        # the Python package
├── stubs/                # mypy stubs
└── tests/                # the pytest suite
```

## Development

Run all Python commands from this `python/` directory:

- Code checks: `poetry run python -m hostbootstrap.check_code`
  (runs `ruff check hostbootstrap stubs`, `black --check hostbootstrap stubs`, then `mypy hostbootstrap`).
- Tests: `poetry run python -m hostbootstrap.test_all`.
- Coverage: `poetry run python -m coverage run -m hostbootstrap.test_all && poetry run python -m coverage report -m`
  (configured with `fail_under = 100`).

Do not invoke `pytest` directly; `tests/conftest.py` requires the `hostbootstrap.test_all` runner. See
[`../documents/architecture/python_haskell_boundary.md`](../documents/architecture/python_haskell_boundary.md)
for the ownership boundary between this bootstrapper and `hostbootstrap-core`.
