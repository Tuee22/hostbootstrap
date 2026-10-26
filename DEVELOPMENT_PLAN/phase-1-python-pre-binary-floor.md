# Phase 1 — Python pre-binary floor

**Status**: Active
**Depends on**: Phase 0 (governance and documentation standards)
**Substrates**: linux-cpu
**Gate**: `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root
**Gate kind**: deferred
**Gate evidence**: 2026-09-13 ; x86_64 Ubuntu 24.04.4 LTS, Python 3.12.3, Poetry 2.4.1 ;
`poetry run python -m hostbootstrap.check_code && poetry run python -m hostbootstrap.test_all` ; pass ;
covers 44abe223709138e3946745a8ec1e33432b79d90048dfbba2ac5047d451fe907c
**Evidence covers**: `hostbootstrap` `tests` `pyproject.toml`

> **Purpose**: Assert the irreducible host floor, prepare the native Haskell toolchain, build the project
> binary host-native, and hand control to it.

## Phase Objective

Something has to run before the Haskell binary exists. That something is a thin Python bootstrapper whose
whole job is to make the binary buildable and then get out of the way: assert the host floor, install the
pinned toolchain, build host-native, and invoke the result. It owns no lifecycle, no configuration model,
and no second implementation of anything the Haskell core owns.

Two operator-invoked surfaces stay in Python because they exist *before* or *outside* a project binary:
the base-image build/publish surface and the pipx self-update surface.

## Sprints

### Sprint 1.1: Host floor assertion and prerequisites [Active]

**Status**: Active
**Implementation**: `hostbootstrap/prereqs.py`, `hostbootstrap/substrate.py`,
`hostbootstrap/resources.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

Refuse early and legibly when the host cannot host the build.

#### Deliverables

- `prereqs.py` asserts the pre-binary floor and names the exact missing prerequisite.
- `substrate.py` classifies the host so the floor is substrate-correct rather than lowest-common-denominator.
  The `/proc` and `/dev` NVIDIA file markers are read on the Linux branch only; a Windows host is
  classified by the `nvidia-smi -L` probe alone. Each refusal of `substrate.py` carries its own message:
  `unsupported host architecture`, `only supports Apple Silicon`, `unsupported host platform`.
- `run_doctor` dispatches exhaustively over `SubstrateName`: an explicit case per constructor and an
  `assert_never` default, so a new substrate cannot fall through to the Linux checks.
- `resources.py` reads host capacity for the pre-binary decisions that need it. `assert_build_minimums`
  accepts a host exactly at each floor (`MIN_CPUS` 8, `MIN_MEM_TOTAL_BYTES` 14 GiB,
  `MIN_MEM_AVAILABLE_BYTES` 8 GiB) and refuses one unit below it.
- A refusal names the prerequisite; a refusal for an installable prerequisite (sudo, curl, PowerShell,
  Xcode Command Line Tools, Homebrew, winget, passwordless sudo) also names the remedy. The doctor never
  partially proceeds: the first `_check_*` that raises stops the run.
- The Git long-paths advisory reads `git config --type=bool --get core.longpaths`, so every spelling Git
  honours as true (`true`, `yes`, `on`, `1`, any case) reads as enabled.

#### Validation

`poetry run python -m hostbootstrap.test_all` holds these cases in `tests/test_prereqs.py`,
`tests/test_substrate.py` and `tests/test_resources.py`, all passing:

- `test_passwordless_sudo_checks` asserts the probe argv is exactly `["sudo", "-n", "true"]`, and its
  root case (`geteuid() == 0`) stubs `_have` and `process.probe` to raise, so the early return is proven.
- `test_ubuntu_check` refuses `ID=ubuntu VERSION_ID=22.04` and `ID=debian VERSION_ID=24.04`, each with
  `PrereqError` matching `Ubuntu 24.04`, besides the existing accept and `debian/12` cases.
- A refusal-text case per installable prerequisite asserts the remedy text.
- A long-paths case stubs `git config --type=bool` output `true` for a configured `1`, and asserts the
  argv carries `--type=bool`.
- A dispatch case asserts each `SubstrateName` reaches its own doctor branch.
- `test_has_nvidia_gpu_from_marker` also patches `substrate.shutil.which` to return `None`, so a `True`
  can come only from the marker; a Windows case with a present marker path asserts the marker is not read.
- `test_unknown_arch_raises`, `test_detect_darwin_intel_rejected` and `test_detect_unknown_system` each
  pass `match=` with their own fragment (`unsupported host architecture`, `only supports Apple Silicon`,
  `unsupported host platform`).
- `test_assert_build_minimums_passes_above_floor` gains an at-floor row (`cpu_count=8`,
  `mem_total_bytes=14 * _GIB`, `mem_available_bytes=8 * _GIB`) that is accepted, and
  `test_assert_build_minimums_rejects_below_floor` gains rows `14 * _GIB - 1` total and `8 * _GIB - 1`
  available (the other values at floor) refused with `total memory` and `available memory`.

#### Remaining Work

- `prereqs._check_passwordless_sudo` tests: pin the `sudo -n true` argv in the success stub of
  `test_passwordless_sudo_checks`, and make the root case's `_have`/`process.probe` stubs raise
  `AssertionError`.
- `test_ubuntu_check`: add the `ubuntu/22.04` and `debian/24.04` refusal cases.
- `prereqs.py`: give the `sudo is required but not installed`, `could not exec sudo`, `curl is required`
  and `Windows PowerShell is required` refusals a remedy sentence (the install command or package), and
  add one `pytest.raises(PrereqError, match=...)` case per message asserting the remedy text.
- `prereqs._git_long_paths_enabled`: probe `git config --type=bool --get core.longpaths`; test that the
  argv carries `--type=bool` and that the normalized `true` reads as enabled.
- `prereqs.run_doctor`: replace the fall-through with a `match substrate.name` over `LINUX_CPU`,
  `LINUX_GPU`, `APPLE_SILICON`, `WINDOWS_CPU`, `WINDOWS_GPU` and an `assert_never` default (mypy strict
  holds exhaustiveness); add a parametrized test asserting each name reaches its branch.
- `substrate._has_nvidia_gpu`: check `_NVIDIA_MARKERS` only when `platform.system() == "Linux"`; patch
  `shutil.which` to `None` in `test_has_nvidia_gpu_from_marker`, and add a Windows case where an existing
  marker path does not make the answer `True`.
- `tests/test_substrate.py`: add the `match=` fragment to `test_unknown_arch_raises`,
  `test_detect_darwin_intel_rejected` and `test_detect_unknown_system`.
- `tests/test_resources.py`: add the at-floor accept row and the one-byte-below total and available
  memory refusal rows, so the 14 GiB and 8 GiB floors are pinned exactly.

### Sprint 1.2: Native toolchain preparation and binary build [Active]

**Status**: Active
**Implementation**: `hostbootstrap/bootstrap.py`, `hostbootstrap/process.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

Build the project binary host-native and invoke it.

#### Deliverables

- `bootstrap.py` prepares the pinned GHC/Cabal toolchain and builds the project binary for the host's own
  architecture — never cross-built, never fetched pre-built. The pinned GHCup download is HTTPS-only
  (`curl --proto =https --tlsv1.2 -fsSL`) and SHA-256 verified; on Windows the URL and output path reach
  PowerShell as arguments, never spliced into script text.
- Project discovery requires the Cabal file stem, the package `name`, and the single `executable` stanza
  to agree; section keywords match case-insensitively, as Cabal reads them.
- Repeated runs are incremental: Cabal's own build skips an up-to-date component, `cabal update` runs only
  when the package index is not fresh, and the stable `.build/<exe>` copy is rewritten only when its bytes
  change.
- The package-index location follows Cabal's resolution: `CABAL_DIR` when set, `%APPDATA%\cabal` on
  Windows, `~/.cabal` when it exists, else `$XDG_CACHE_HOME/cabal` (default `~/.cache/cabal`).
- The stable copy is replaced atomically: a sibling temporary file in `.build/` is written and `os.replace`d
  onto the destination, so a running binary is never truncated in place.
- `--offline` reaches both the toolchain check and the native build from `bootstrap()` and
  `build_binary()`, and contacts no network.
- Invocation is process replacement (`exec`) on POSIX and a child subprocess on Windows, so the binary's
  exit status is the operator's exit status.
- `process.py` is the single place a subprocess is launched, with explicit stdio disposition.

#### Validation

`poetry run python -m hostbootstrap.test_all` holds these cases in `tests/test_bootstrap.py`, all passing:

- `test_discover_project_rejects_every_identity_mismatch` carries a stem-only case (`demo.cabal` declaring
  `name: other` / `executable other`); a discovery case accepts `Executable demo`.
- The `recorded_commands` fixtures in `tests/conftest.py` record `(argv, cwd, "checked" | "probe")`; the
  driver tests assert `cwd=project_root` for `cabal update`, build and `list-bin`, that probes and installs
  receive `_toolchain_env()` (its `PATH` starts with the GHCup bin directory), and a fresh-host case where
  `run_checked` raises `CommandError` on the GHC install propagates it.
- `bootstrap()` and `build_binary()` driver cases with `offline=True` assert no `cabal update` runs and
  `--offline` is in the build argv; a `_build_native` case with `CabalIndexState.STALE` and
  `offline=False` asserts `commands[0] == bootstrap.cabal_update_command()`.
- `cabal_index_path` cases cover `CABAL_DIR`, Windows `%APPDATA%`, an existing `~/.cabal`, and the XDG
  default.
- The GHCup download cases assert the exact curl argv (pinned URL, `--proto =https`, `--tlsv1.2`, `-f`)
  and that the Windows command carries the pinned URL and a path containing `'` as separate arguments.
- The command-builder cases parametrize `os.name` over `nt` and `posix` and assert literal expected argv;
  `test_bootstrap_linux_gpu_builds_host_native` asserts the full command list, library probe included.
- A `_copy_if_changed` case asserts the destination is replaced through a new file (its inode or file id
  changes), and the POSIX exec line carries no `# pragma: no cover`.

#### Remaining Work

- `bootstrap.cabal_index_path`: resolve `CABAL_DIR`, else `%APPDATA%\cabal` on `os.name == "nt"`, else
  `~/.cabal` if it is a directory, else `$XDG_CACHE_HOME/cabal` or `~/.cache/cabal`; add one test per row.
- `bootstrap._install_verified_ghcup`: pass the URL and output path to PowerShell as `param($u, $o)`
  arguments (`-Command "& { param($u,$o) Invoke-WebRequest -Uri $u -OutFile $o }" <url> <path>`); test
  with a temporary directory whose name contains `'` and assert the argv elements.
- `bootstrap._copy_if_changed`: copy to a sibling temporary file, flush and `fsync`, then `os.replace` it
  onto the destination (on Windows, when `os.replace` is refused for a running executable, rename the
  old file aside first); test that a destination opened before the copy keeps its old bytes and the new
  path holds the new bytes.
- `bootstrap._discover_executable`: compare `parts[0].lower() == "executable"`; add the `Executable demo`
  accept case and the stem-only mismatch case.
- `tests/conftest.py`: record cwd and checked/probe kind in both recorder fixtures; add the cwd, env and
  failing-install assertions listed under Validation.
- `tests/test_bootstrap.py`: add the offline driver cases, the online `STALE` case, the exact curl argv
  assertion, the `os.name`-parametrized builder cases, and the full LINUX_GPU command list.
- `bootstrap._exec_project_binary`: drop the `# pragma: no cover` on `os.execve`, which
  `test_posix_exec_project_binary_rehomes_to_project_root_then_execs` already executes.

### Sprint 1.3: The operator CLI surface [Active]

**Status**: Active
**Implementation**: `hostbootstrap/cli.py`, `hostbootstrap/base_image.py`,
`hostbootstrap/docker_ops.py`, `hostbootstrap/self_update.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/build_release.md`

#### Objective

Expose exactly the surfaces that must exist outside a project binary.

#### Deliverables

- `hostbootstrap run -- <args>` prepares and invokes the project binary, forwarding `--offline` and
  `--cabal-file`; the bootstrapper implements no project lifecycle or configuration verb, those belong to
  the binary.
- `hostbootstrap base build-and-push --flavor <f> --arch <a>` is the canonical base publication command:
  plain single-architecture `docker build` plus `docker push`, host-native, no buildx.
- `base build` and `base build-and-push` run, in order and before the first `docker_ops.build`, the
  maintainer authority, the native-architecture refusal (requested, host and Docker engine architecture
  all equal), and the quality gates; a refusal from any of them builds and pushes nothing.
- The quality gates are `check_code`, `test_all`, the formatter and linter, and `cabal build all` /
  `cabal test all` with `--ghc-options=-Werror` in `core/` and `demo/`. The formatter's source list is
  split into argv chunks under `_FORMATTER_ARGV_BUDGET` characters of `subprocess.list2cmdline`, so no gate
  exceeds the Windows `CreateProcess` 32,767 character limit.
- Concurrent flavors both run to completion, every published flavor's `published and validated <digest>`
  line is printed, and every failed flavor is reported by label in one final error when each failure has
  a friendly message; a failure without one (a `KeyError`) re-raises unchanged with its traceback.
  `--sequential` stops at the first failure and builds nothing after it.
- `hostbootstrap update` is the explicit pipx update surface.
- `docker_ops.py` is the only place Docker is invoked.
- `_FriendlyGroup` turns the project's own refusal types into one-line errors; a `KeyError` is a
  programming error and keeps its traceback. `--context` and `--project-root` default to the working
  directory at invocation, not at import.

#### Validation

`poetry run python -m hostbootstrap.test_all` holds these cases in `tests/test_cli.py`, all passing:

- `_stub_self_check_passing` stubs `_arch_default` and records `authority`, `arch-check` and
  `quality-gates` into one ordered event list shared with the `docker_ops.build`/`push` fakes; `base build`
  and `base build-and-push` each assert `["authority", "arch-check", "quality-gates", "build", ...]`.
- A CliRunner case per base command whose gate stub raises `ClickException`, and one whose arch stub
  raises, asserts `docker_ops.build` and `docker_ops.push` were never called.
- `test_native_architecture_requires_request_host_and_engine_match` adds an AMD64 engine with
  request = host = ARM64 and asserts `ClickException` matching `Docker engine=amd64`.
- `test_quality_gates_run_all_python_core_and_demo_commands` asserts a literal expected list of
  `(label, command, cwd)` for the non-style gates, including `--ghc-options=-Werror` and cwd
  `context/core` and `context/demo`, rather than calling `cli._quality_gates`.
- A `_style_gates` case monkeypatches `cli._FORMATTER_ARGV_BUDGET` down to a few hundred characters over a
  synthetic root holding a handful of sources, and asserts every formatter gate's
  `len(subprocess.list2cmdline(gate.command))` stays within it, the chunks together name every source
  exactly once, and the labels read `Haskell formatter over <root> (part i/n)`; the existing
  `test_style_gates_enumerate_sources_and_skip_the_modules_fourmolu_cannot_read` keeps its unsuffixed
  `Haskell formatter over <root>` lookups because its roots fit in one chunk.
- The concurrency cases use a build fake that awaits `asyncio.sleep(0)` and records start and end events:
  the concurrent case asserts interleaving (`cuda-start` before `cpu-end`), the `--sequential` case asserts
  strict nesting; a cpu-fails case asserts nonzero exit, the cuda `published and validated` line, and
  `pushed == [cuda tag]`, and its `--sequential` variant asserts nothing ran after the cpu failure; a
  both-fail case (each flavor raising `CommandError`) asserts one `ClickException` whose message holds a
  `[cpu]` and a `[cuda]` line, each with its formatted error; a case where cpu raises `CommandError` and
  cuda raises `KeyError("x")` asserts `result.exception` is that `KeyError` instance.
- A `--context` case and a `build` case run under `monkeypatch.chdir(tmp_path)` with no option and assert
  the captured root is `tmp_path.resolve()`; a `run --offline --cabal-file x.cabal` case, shaped like
  `test_build_threads_explicit_cabal_selection_and_offline`, asserts the `_load_project` stub receives
  `selected_cabal_file == Path("x.cabal")` and the `bootstrap.bootstrap` fake receives `offline is True`.
- A command raising `KeyError()` surfaces the `KeyError` itself (`result.exception`), not `IndexError`.
- A parametrized `_maintainer_command_authority` case starts from the passing environment and fails
  exactly one condition per row: the Poetry `name`, a missing `.git`, a missing `poetry.lock`, a prefix
  other than the checkout's `.venv`, `sys.prefix == sys.base_prefix`, an executable outside the prefix,
  `find_spec` returning `None` for one of `ruff`/`black`/`mypy`/`pytest`, and `tomllib.loads` raising
  `TOMLDecodeError`; each row asserts `None`. The passing environment is a synthetic checkout under
  `tmp_path` (`pyproject.toml` with `name = "hostbootstrap"`, a `.git` directory, `poetry.lock`, and a
  `.venv` holding the executable), reached by monkeypatching `cli.__file__` to
  `<tmp>/hostbootstrap/cli.py`, `sys.prefix` and `sys.executable` into `<tmp>/.venv`, `sys.base_prefix` to
  another directory, and `importlib.util.find_spec` to succeed; a baseline row with no condition removed
  asserts a `MaintainerCommandAuthority` whose `repository_root` is the synthetic root.

#### Remaining Work

- `tests/test_cli.py`: add the parametrized one-condition-fails `_maintainer_command_authority` case over
  the synthetic `tmp_path` checkout, with `cli.__file__`, `sys.prefix`, `sys.base_prefix`,
  `sys.executable` and `importlib.util.find_spec` monkeypatched as `#### Validation` states.

- `tests/test_cli.py`: rewrite `_stub_self_check_passing` into the ordered-event recorder (stubbing
  `_arch_default`) and add the gate-raises and arch-raises cases asserting no Docker call, for both base
  commands.
- `tests/test_cli.py`: add the engine-mismatch case, the literal quality-gate list, the interleaving,
  nesting, partial-failure and both-fail cases, the `run --offline --cabal-file` case, and replace
  `test_default_project_root_is_current_directory` with the `chdir` invocation case.
- `cli._style_gates`: add `_FORMATTER_ARGV_BUDGET: Final[int] = 16_384`, counted in characters of
  `subprocess.list2cmdline(argv)`, and split each formatter root's sources into chunks whose argv stays
  within it, one `_QualityGate` per chunk labelled `Haskell formatter over <root> (part i/n)` when n > 1
  and `Haskell formatter over <root>` otherwise; add the chunking test that monkeypatches the budget down.
- `cli._FriendlyGroup.invoke`: factor the per-type translation into `_friendly_message(exc) -> str | None`
  (a `CommandError`, a `FileNotFoundError` with a known hint, an `httpx.HTTPError`, a `RuntimeError`; `None`
  for anything else, including a `KeyError` and an unknown `FileNotFoundError`), which `invoke` uses so an
  exception without a friendly message re-raises unchanged.
- `cli._run_base_targets`: in the concurrent branch, if every failed flavor's exception has a
  `_friendly_message`, raise one `ClickException` listing `[label] <message>` per failed flavor; otherwise
  re-raise the first exception that has none, unchanged; add the both-fail case and the cpu-`CommandError`
  plus cuda-`KeyError` case.
- `cli._FriendlyGroup.invoke`: drop `KeyError` from the caught types and the `KeyError` branch of
  `_format_runtime_error`, narrowing its parameter to `RuntimeError`; replace the `KeyError("bad-value")`
  row of `test_friendly_group_converts_known_errors` with the propagation case, and delete the
  `cli._format_runtime_error(KeyError("x"))` assertion in `tests/test_cli.py`.
- `cli._BASE_CONTEXT_BUILD_OPTION`: default `None`, resolved to `Path.cwd()` inside `base_build` and
  `base_build_and_push`; add the `chdir` case.

### Sprint 1.4: The Python quality gate [Active]

**Status**: Active
**Implementation**: `hostbootstrap/check_code.py`, `hostbootstrap/test_all.py`, `pyproject.toml`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Make the Python half's gate one command with no bypass.

#### Deliverables

- `check_code` runs `ruff check`, then `black --check`, then `mypy`, over `hostbootstrap`, each as
  `sys.executable -m <tool>` with cwd the repository root, so the locked venv's tools check the checkout
  from any working directory.
- `test_all` sets the `HOSTBOOTSTRAP_TEST_ALL` sentinel and invokes pytest in-process; forwarded option
  filters (`-k`, `-m`, `-q`) narrow the run, and a forwarded path or node id replaces the default `tests`
  target.
- `tests/conftest.py` requires the sentinel, so there is one supported suite entry point.
- An unfiltered `test_all` run measures line and branch coverage of `hostbootstrap` and fails below
  `fail_under = 100`, so the host static gate holds the coverage floor rather than a separate manual
  command.
- `pyproject.toml` declares no pytest marker that no test applies, and its `description` names the thin
  host bootstrapper for project binaries.

#### Validation

Both commands pass from the repository root. Dated evidence: `235 passed` in 1.43 seconds, and
`ruff`/`black`/`mypy` clean, on x86_64 Ubuntu 24.04.4 LTS with Python 3.12.3 and Poetry 2.4.1
(2026-09-09). Closure adds these cases in `tests/test_dev_runners.py`, all passing under
`poetry run python -m hostbootstrap.test_all`:

- `test_check_code_main_success_and_fail_fast` asserts the full step argv: `ruff check hostbootstrap`,
  `black --check hostbootstrap`, `mypy hostbootstrap`, each launched through `sys.executable -m` with cwd
  the repository root.
- A `test_all` case forwarding `tests/test_cli.py` asserts the pytest args are `["tests/test_cli.py"]`;
  the existing `-k models` case still asserts `["tests", "-k", "models"]`.
- A `test_all` case with a stubbed coverage report below 100 returns nonzero after a passing pytest run,
  and a filtered run skips the coverage check.

#### Remaining Work

- `hostbootstrap/test_all.py`: on an unfiltered run, start `coverage.Coverage()` (configured from
  `pyproject.toml`) before pytest runs, reload `hostbootstrap` modules imported before measurement so
  their module-level lines count, and after a passing run return nonzero when `report()` is below
  `fail_under`; set `branch = true` under `[tool.coverage.run]`; add the two coverage cases.
- `hostbootstrap/test_all.py`: prepend `tests` only when no positional (non-option) argument is forwarded;
  add the path-forwarding case.
- `hostbootstrap/check_code.py`: launch each tool as `(sys.executable, "-m", tool, ...)` with
  `cwd=Path(__file__).resolve().parent.parent`; pin the full argv and cwd in
  `test_check_code_main_success_and_fail_fast`.
- `pyproject.toml`: delete the unused `docker` and `slow` markers and set `description` to "Thin host
  bootstrapper for hostbootstrap project binaries (plus maintainer base-image commands)".

### Sprint 1.5: One architecture value in the bootstrapper [Active]

**Status**: Active
**Implementation**: `hostbootstrap/substrate.py`, `hostbootstrap/base_image.py`, `hostbootstrap/docker_ops.py`,
`hostbootstrap/prereqs.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

Architecture is the third closed value in the bootstrapper's vocabulary, beside the substrate name and
the image flavor. The two supported architectures are the only ones expressible, one alias table is the
single mapping into them, and every function downstream of that table takes the narrowed value rather
than re-deriving validity from text.

#### Deliverables

- `Arch` joins `SubstrateName` and `Flavor` as a closed enumeration in `hostbootstrap/substrate.py`.
- `Substrate.arch` and every tag, reference, build-argument, and download-URL producer take `Arch`.
- One alias table (`_ARCH_ALIASES`, read through `parse_arch`) maps every architecture spelling read from the host machine string or the Docker engine into `Arch`, including the Apple Silicon prerequisite check `prereqs._check_macos_arm64`, which accepts the host exactly when `parse_arch(platform.machine())` is `Arch.ARM64`; the operator `--arch` flag accepts only the canonical `Arch` values through `click.Choice`, and the build-argument boundary re-derives no validity, because its input is already narrowed.
- `normalize_architecture` in `docker_ops.py` reads that one table, so the host boundary and the Docker-engine boundary answer with the same value.
- The base-image tables keyed by architecture (`_NODE_ARCH`, `_GHCUP_ARCH`, `_AWS_ARCH`, `_PULUMI_ARCH`, `_GO_ARCH`, `_PURESCRIPT_ASSET`) are total `Mapping[Arch, str]`, so a lookup cannot miss. The bootstrapper's `_GHCUP_DOWNLOADS` is keyed by platform and `Arch` and carries pinned rows for linux/amd64, linux/arm64 and windows/amd64 only; any other pair refuses with `no pinned GHCup download for <platform>/<arch>`.
- The check runner's targets are exactly the package it checks, so no tool configuration names a path that holds nothing and no tool carries a comment explaining a skip.

#### Validation

The host static gate. `poetry run python -m hostbootstrap.check_code` type-checks the narrowed
signatures under strict `mypy`, and `poetry run python -m coverage run -m hostbootstrap.test_all`
holds the 100% line gate — which means the tests exercise both architectures rather than the one
the host happens to be. Dated evidence: `ruff`/`black`/`mypy` clean and `242 passed` at 100% line
coverage, on x86_64 Ubuntu 24.04.4 LTS with Python 3.12.3 and Poetry 2.4.1 (2026-09-12). The two
boundaries that read an outside architecture spelling — the host machine string and the Docker engine
answer — are asserted to return the same `Arch` for every alias, which is the absence guard against a
second table returning. Closure adds, in `tests/test_prereqs.py` under
`poetry run python -m hostbootstrap.test_all`, a parametrized `test_macos_checks` that accepts every
`_ARCH_ALIASES` spelling mapping to `Arch.ARM64` (`arm64`, `aarch64`, `ARM64`) and refuses `x86_64` with
`PrereqError` matching `Apple Silicon`, and `poetry run python -m hostbootstrap.check_code` clean.

#### Remaining Work

- `prereqs._check_macos_arm64`: delete the literal `{"arm64", "aarch64"}` set and accept the host exactly
  when `parse_arch(platform.machine()) is Arch.ARM64`; parametrize `test_macos_checks` over the
  `Arch.ARM64` aliases and the `x86_64` refusal. The subprocess vocabulary and the detection boundary are
  Sprint 1.6 and Sprint 1.7.

### Sprint 1.6: One way to run a command in the bootstrapper [Active]

**Status**: Active
**Implementation**: `hostbootstrap/process.py`, `hostbootstrap/prereqs.py`, `hostbootstrap/self_update.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

One module launches every subprocess the bootstrapper runs, and says what happened in one vocabulary.
A synchronous sibling of the asynchronous runner serves the callers that have no event loop, so each of
them keeps its own error type instead of re-deriving the mechanics of running a command, deciding
whether it failed, and saying which kind of failure it was.

#### Deliverables

- `process.py` carries a synchronous probe that returns a completed result or a statement that the command could not be executed at all, and a synchronous checked runner that raises on either.
- The child's stdio disposition is a closed value, so a caller names capture or inheritance rather than setting a pair of booleans.
- The prerequisite checks, substrate detection, self-update, the check runner, the maintainer quality gates, and the Windows binary handoff call them and wrap one outcome into their own error type.
- No module outside `process.py` imports `subprocess`.
- The distinction between 'ran and failed', 'could not be run' and 'timed out' survives in the outcome rather than in which exception was caught, for both runners: the asynchronous `run` reports an executable it cannot launch as `CommandError(CommandUnavailable(argv, reason))` on every platform (Windows raises `FileNotFoundError` with `filename=None`), and the CLI's missing-binary hint reads `argv[0]` from that outcome.
- Both runners decode child output as UTF-8 with `errors="replace"`, so `probe` never raises for a child's bytes.
- When a drain task of `run` raises, `run` kills the child if it is still running, awaits it, and re-raises; `_drain` reads bounded chunks rather than unbounded lines and mirrors with `errors="replace"`.

#### Validation

The host static gate, with coverage still at 100%. The prerequisite and self-update suites assert on
the failure text each module produces; those assertions are the regression test that the error
vocabulary did not change when the mechanics did. Dated evidence: `ruff`/`black`/`mypy` clean and
`249 passed` at 100% line coverage, on x86_64 Ubuntu 24.04.4 LTS with Python 3.12.3 and Poetry 2.4.1
(2026-09-12). Closure adds these cases in `tests/test_process.py` and `tests/test_cli.py`, all passing
under `poetry run python -m hostbootstrap.test_all`:

- `probe` of `sys.executable -c "import time; time.sleep(5)"` with `timeout=0.1` returns the timed-out
  outcome with a reason naming the timeout, and the prerequisite messages that render it say the command
  timed out rather than that it is missing.
- `probe` of a child writing the bytes `b"\x81\x8d\x8f\x90\x9d"` to stdout and stderr returns a
  `CommandResult` carrying U+FFFD, not an exception.
- `run` of a child writing one line longer than 64 KiB completes with the full output captured; a `run`
  whose mirror raises on write leaves no live child (`returncode` is set) and re-raises.
- `run` of a nonexistent executable raises `CommandError` whose outcome is `CommandUnavailable`, and a
  CLI case with `docker` missing prints the `_MISSING_BINARY_HINTS["docker"]` text with no traceback.
- `test_run_captures_stdout_stderr_env_and_quiet` uses `capfd` to assert nothing reaches the parent
  streams with `quiet=True`, a non-quiet companion asserts the output is mirrored, and a sentinel set in
  `os.environ` through `monkeypatch` is printed by the child to pin environment merging.

#### Remaining Work

- `process.probe`: pass `encoding="utf-8", errors="replace"` to the capturing `subprocess.run`; add the
  undecodable-bytes case.
- `process.probe`: catch `subprocess.TimeoutExpired` before `SubprocessError` and return a distinct
  timed-out outcome (a `CommandTimedOut(args, timeout)` member of `CommandOutcome`, rendered by
  `describe`); update `prereqs` and `substrate` callers that read `CommandUnavailable` so a timeout is
  reported as a timeout; add the timeout case.
- `process.run`: wrap `asyncio.create_subprocess_exec` so an `OSError` at launch raises
  `CommandError(CommandUnavailable(argv, str(exc)))`; make `cli._format_command_error` map a
  `CommandUnavailable` whose `argv[0]` basename is in `_MISSING_BINARY_HINTS` to that hint; add the
  missing-executable and CLI hint cases.
- `process.run`: wrap the drain `gather` in `try/except BaseException` that calls `process.kill()` when
  `returncode is None`, awaits `process.wait()`, and re-raises; in `_drain`, read `stream.read(65536)`
  chunks, split the decoded buffer into lines before applying the prefix (carrying a partial last line
  into the next chunk), and write to the mirror with `errors="replace"`; add the long-line and
  failing-mirror cases.
- `tests/test_process.py`: add the `capfd` quiet and non-quiet assertions and the environment-merge
  sentinel.

### Sprint 1.7: The bootstrapper's detection is the one the binary uses [Done]

**Status**: Done
**Implementation**: `hostbootstrap/substrate.py`, `hostbootstrap/bootstrap.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`

#### Objective

Something must detect the host before the binary exists, and § M gives that job to the bootstrapper.
It passes what it found to the binary it launches, so one classification of one host has one author.

#### Deliverables

- The bootstrapper hands its detected substrate and architecture to the binary through the documented invocation-context seam.
- Each seam value is one spelling of a closed vocabulary, named by a constant rather than written at the call site.
- The seam is set explicitly on the launched child — `execve` on POSIX, the child's environment on Windows — rather than left in the ambient environment to be read opportunistically.
- `documents/architecture/python_haskell_boundary.md` states which side detects, which side receives, and what a directly invoked binary sees instead.

#### Validation

The host static gate. The suite pins both handoff shapes carrying the pair, and pins that the detected
substrate reaches the seam rather than a constant. Dated evidence: `ruff`/`black`/`mypy` clean and
`251 passed` at 100% line coverage, on x86_64 Ubuntu 24.04.4 LTS with Python 3.12.3 and Poetry 2.4.1
(2026-09-12). The consuming half is Sprint 3.10: the binary reads the pair when it is set and runs its
own detection when it is invoked directly.

#### Remaining Work

None.

### Sprint 1.8: The self-update freshness check compares the commit pip would install [Planned]

**Status**: Planned
**Implementation**: `hostbootstrap/self_update.py`, `hostbootstrap/cli.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/self_update.md`

#### Objective

`hostbootstrap update --check` answers whether the installed commit equals the commit pip would install
for the ref being compared, and every way the check cannot complete is a `SelfUpdateError` with its own
message, never a traceback.

#### Deliverables

- `parse_direct_url` turns text that is not JSON into `SelfUpdateError("installed direct_url.json is
  malformed.")`, and each malformed shape raises its own message: a non-object document (`is malformed`),
  non-object `vcs_info` (`malformed VCS metadata`), a git source missing `url` or `commit_id`
  (`missing git source metadata`), a non-string `requested_revision` (`malformed requested revision`).
- `remote_commit` queries fully qualified refs (`refs/heads/<ref>`, `refs/tags/<ref>`,
  `refs/tags/<ref>^{}`) and chooses by exact name: the branch first, then the peeled tag, then the
  unpeeled tag, mirroring pip's resolution order; output with no exact match is refused with
  `SelfUpdateError`.
- When `--ref` is not given explicitly, `check_status` compares against the installed
  `requested_revision` (falling back to `main`), and the CLI prints the ref it compared against.

#### Validation

`poetry run python -m hostbootstrap.test_all` holds these cases in `tests/test_self_update.py` and
`tests/test_cli.py`, all passing:

- `test_parse_direct_url_rejects_malformed` parametrizes `(text, match)` pairs: `"{not json"` and `"[]"`
  with `is malformed`, the list `vcs_info` with `malformed VCS metadata`, the `vcs_info` lacking
  `commit_id` with `missing git source metadata`, and `requested_revision=123` with
  `malformed requested revision`; each asserts `pytest.raises(SelfUpdateError, match=...)`.
- `parse_ls_remote` cases: output holding `refs/heads/backup/main`, `refs/heads/main` and an annotated
  `refs/tags/main` with its `^{}` line returns the `refs/heads/main` sha; a tag-only output returns the
  peeled sha; an output with no exact name match raises `SelfUpdateError`.
- `test_check_status_compares_installed_to_remote` uses different installed and remote commits, asserts
  `up_to_date is False` and `remote_commit` equals the stubbed value, and records the ref passed to the
  stub.
- A `check_status` case with installed `requested_revision="v1.2"` and no explicit ref asserts the stub
  received `v1.2`; a CLI `update --check` case asserts the compared ref is printed.

#### Remaining Work

- `self_update.parse_direct_url`: wrap `json.loads` and raise `SelfUpdateError` from
  `json.JSONDecodeError`; rewrite `test_parse_direct_url_rejects_malformed` as `(text, match)` pairs
  with the `{not json` row.
- `self_update.remote_commit`/`parse_ls_remote`: query the fully qualified refs, select by exact name
  branch-first, refuse ambiguous or unmatched output; add the three `parse_ls_remote` cases.
- `self_update.check_status` and `cli.update_cli`: thread an explicit-or-installed ref (installed
  `requested_revision`, else `main`) and print it; rewrite `test_check_status_compares_installed_to_remote`
  with differing commits and add the requested-revision and printed-ref cases.

### Sprint 1.9: The Python suite's Haskell-source guards hold what they claim [Planned]

**Status**: Planned
**Implementation**: `tests/test_packaging.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

The two guards in `tests/test_packaging.py` that read Haskell sources fail on the regressions their names
promise: a bare-literal process target in any launch form, and a provider builder with no production call.

#### Deliverables

- `test_haskell_host_processes_do_not_launch_bare_literal_commands` scans each file whole after stripping
  `--` line comments and `{- -}` block comments, with patterns that allow any whitespace (newlines
  included) between the function name and the string literal, over `readProcessWithExitCode`,
  `readProcess`, `readCreateProcess`, `proc`, `shell`, `callProcess`, `rawSystem`, `spawnProcess` and
  `createProcess`.
- `test_provider_surface_has_one_dispatch_and_no_definition_only_builders` counts a builder's occurrences
  after excluding its module's export list and every `^name\s*::` signature and `^name\b.*=` defining
  equation line, and requires at least one remaining occurrence.

#### Validation

`poetry run python -m hostbootstrap.test_all` passes on the current tree, and these self-test cases in
`tests/test_packaging.py` pass: the literal-target scanner flags a synthetic source with
`readProcessWithExitCode` and `"docker"` on separate lines and a `spawnProcess "wsl"` line, and ignores
the same text inside a comment; the builder counter reports zero uses for a synthetic module holding only
an export, a signature and an equation of a builder.

#### Remaining Work

- `tests/test_packaging.py`: factor the scanner and the use counter into helpers over source text, apply
  the comment stripping, multi-line patterns and extended function list, and the export/signature/equation
  exclusion; add the synthetic self-test cases.

### Sprint 1.10: The CLI help renders on a cp1252 console [Planned]

**Status**: Planned
**Implementation**: `hostbootstrap/cli.py`, `tests/test_cli.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/languages/python.md`

#### Objective

Every help page Click renders for the bootstrapper's command tree encodes in the Windows ANSI code page
(cp1252), so `hostbootstrap --help` and each subcommand's `--help` print on a native-Windows console or a
redirected stdout instead of raising `UnicodeEncodeError`. The help text itself is ASCII; the bootstrapper
does not depend on the console's encoding to show its own usage.

#### Deliverables

- Every string Click renders as help in `hostbootstrap/cli.py` is ASCII: the docstring of each command and
  group registered on `main` (including `check-code`, `test-all`, `base`, `base build` and
  `base build-and-push`) and every option `help=` text. Arrows are written `->` and dashes `-`.
- A test walks the whole command tree with the maintainer commands enabled and asserts each command's
  `help` and `short_help` and each parameter's `help` encode as cp1252, so a non-encodable character
  added later fails the suite.

#### Validation

`poetry run python -m hostbootstrap.test_all` holds these cases in `tests/test_cli.py`, all passing, and
`poetry run python -m hostbootstrap.check_code` is clean:

- `test_help_renders_under_cp1252` monkeypatches `cli._maintainer_cli_enabled` to return `True`, invokes
  `cli.main` through `CliRunner(charset="cp1252")` with `["--help"]`, `["base", "--help"]`,
  `["base", "build", "--help"]` and `["base", "build-and-push", "--help"]`, and asserts each exits 0 with
  `result.exception is None`; the top-level output contains the `check-code` and `test-all` rows.
- `test_help_text_is_cp1252_encodable` recursively visits `cli.main` and every subcommand (maintainer
  commands enabled) and asserts `text.encode("cp1252")` succeeds for every command `help`/`short_help`
  and every parameter `help`.

#### Remaining Work

- `hostbootstrap/cli.py`: replace `→` with `->` in the `check-code` docstring (`ruff -> black -> mypy`)
  and in the `base build` docstring (`local smoke -> build-and-push -> pull -> published smoke`), and any
  other non-ASCII character in a command, group or option help string.
- `tests/test_cli.py`: add `test_help_renders_under_cp1252` and `test_help_text_is_cp1252_encodable` as
  described under Validation.

## Remaining Work

- Sprint 1.1: floor refusals carry their remedy and pinned message, the long-paths advisory reads a Git
  bool, `run_doctor` dispatches exhaustively, NVIDIA file markers are read on Linux only, and the memory
  floors are pinned at their boundary.
- Sprint 1.2: the Cabal index location follows Cabal's resolution, the GHCup URL and path reach PowerShell
  as arguments, the stable binary is replaced atomically, and the discovery and driver test gaps close.
- Sprint 1.3: the base commands prove authority, arch check and gates precede any Docker call, formatter
  argv is chunked, every failed concurrent flavor is reported, `KeyError` propagates, and `--context`
  defaults at invocation.
- Sprint 1.4: an unfiltered `test_all` enforces line and branch coverage at 100, `check_code` runs the
  venv's tools from the repository root, `test_all` forwards paths, and the unused pytest markers go.
- Sprint 1.5: the Apple Silicon prerequisite check reads the host machine string through `parse_arch`
  instead of its own literal alias set.
- Sprint 1.6: `probe` decodes with replacement and reports a timeout as its own outcome, `run` reports a
  launch failure as `CommandUnavailable`, and a failing drain tears the child down.
- Sprint 1.8: the self-update check resolves refs as pip does, compares against the installed ref, and
  pins each malformed `direct_url.json` message.
- Sprint 1.9: the Haskell-source guards in `tests/test_packaging.py` catch multi-line and comment-aware
  literal process targets and definition-only builders.
- Sprint 1.10: every Click help string in `hostbootstrap/cli.py` is ASCII, and a cp1252 `CliRunner` case
  plus a command-tree encodability case pin it.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/python_haskell_boundary.md` — the ownership boundary between the two halves,
  and the host-native build and invocation of the project binary.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the Python gate and the one supported suite entry point.
- `documents/engineering/build_release.md` — the base-image publish workflow and its pre-publish gates.
- `documents/engineering/base_image.md` — the operator publication command.
- `documents/engineering/self_update.md` — the pipx update surface and its freshness check.

**Cross-references to add:**
- root `README.md` describes the two-language architecture and links to the boundary document.
- `CLAUDE.md` and `AGENTS.md` name the canonical development commands.
