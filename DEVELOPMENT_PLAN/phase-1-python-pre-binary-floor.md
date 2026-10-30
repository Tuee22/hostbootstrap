# Phase 1 — Python pre-binary floor

**Status**: Done
**Depends on**: Phase 0 (governance and documentation standards)
**Substrates**: linux-cpu
**Gate**: `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root
**Gate kind**: deferred
**Gate evidence**: 2026-10-26 ; `hostbootstrap-cpu-gate-20261026`, x86_64 Ubuntu 24.04 CPU-only container on WSL2 Linux 6.18.33.2, Python 3.12.3, Poetry 2.5.1 ;
`poetry run python -m hostbootstrap.check_code && poetry run python -m hostbootstrap.test_all` ; pass ;
covers 816a21c91f8455bdc87f2d4d820bedd23589c364e87a4fd8e99eaf6cb971571f
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

### Sprint 1.1: Host floor assertion and prerequisites [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases:

- In `tests/test_prereqs.py`, `test_passwordless_sudo_checks` pins the exact probe and root early return;
  `test_ubuntu_check` accepts Ubuntu 24.04 and refuses the other distro/version rows.
  `test_xcode_clt_check`, `test_homebrew_check`, `test_curl_check`, `test_winget_check`, and
  `test_powershell_check` assert prerequisite remedies.
- `test_git_long_paths_enabled_reads_config` pins Git's bool-normalizing argv;
  `test_run_doctor_dispatches_by_substrate` covers every constructor, and
  `test_doctor_stops_at_first_missing_prerequisite` proves fail-fast ordering.
- In `tests/test_substrate.py`, `test_has_nvidia_gpu_from_marker` excludes an executable probe, while
  `test_windows_gpu_detection_does_not_read_linux_markers` proves the Windows marker exemption.
  `test_unknown_arch_raises`, `test_detect_darwin_intel_rejected`, and `test_detect_unknown_system`
  pin the three refusal messages.
- In `tests/test_resources.py`, `test_assert_build_minimums_passes_above_floor` includes the exact
  CPU and memory floors; `test_assert_build_minimums_rejects_below_floor` includes the one-byte-below
  total and available memory rows.

#### Remaining Work

None.

### Sprint 1.2: Native toolchain preparation and binary build [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases in `tests/test_bootstrap.py`:

- `test_discover_project_rejects_every_identity_mismatch` includes the stem-only mismatch, and
  `test_discover_project_accepts_cabal_section_keyword_case` accepts `Executable demo`.
- `test_cabal_index_path_honors_cabal_dir` and `test_cabal_index_location_follows_cabal_resolution`
  cover explicit `CABAL_DIR`, Windows `%APPDATA%`, legacy `.cabal`, and the XDG cache defaults.
- `test_verified_ghcup_download_installs_only_matching_digest` pins HTTPS curl arguments and the hash;
  `test_verified_ghcup_download_supports_windows_powershell` pins separate URL and quoted-path arguments.
- `test_copy_publishes_a_new_file_and_preserves_an_open_old_handle` exercises atomic replacement;
  `test_windows_busy_binary_is_renamed_before_replacement` covers the Windows fallback;
  `test_copy_missing_source_preserves_the_installed_binary` and
  `test_copy_permission_refusal_without_a_replaceable_windows_binary_cleans_up` prove failure cleanup.
- `test_driver_threads_offline_and_preserves_build_cwd` covers both drivers, online stale-index update,
  offline propagation, and exact build/list-bin working directories. The recorder fixtures in
  `tests/conftest.py` assert the toolchain environment.
  `test_fresh_host_ghc_install_failure_stops_before_build` proves install failure propagation.
- `test_native_build_command`, `test_native_build_command_offline`, `test_cabal_update_command`, and
  `test_native_listbin_command` pin both OS argv rows; `test_bootstrap_linux_gpu_builds_host_native`
  pins the full command sequence including its library probe.
- `test_posix_exec_project_binary_rehomes_to_project_root_then_execs` covers process replacement;
  `test_windows_exec_project_binary_exits_with_child_status` covers child status.

#### Remaining Work

None.

### Sprint 1.3: The operator CLI surface [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases in `tests/test_cli.py`:

- `test_maintainer_authority_requires_each_repository_condition` covers the synthetic passing checkout
  and each individual refusal. `test_base_authority_architecture_and_quality_precede_docker` pins both
  commands' ordered preflight; `test_base_preflight_failure_makes_no_docker_mutation` covers each refusal.
- `test_native_architecture_requires_request_host_and_engine_match` includes the engine mismatch.
  `test_quality_gates_run_all_python_core_and_demo_commands` pins literal labels, argv, and cwd;
  `test_style_gates_run_before_the_cabal_legs` pins style ordering.
- `test_formatter_argv_is_chunked_under_the_windows_budget` covers quoted lengths, source membership,
  chunk labels, and an oversized path. Single chunks retain their labels in
  `test_style_gates_enumerate_sources_and_skip_the_modules_fourmolu_cannot_read`.
- `test_concurrent_flavors_interleave_and_sequential_flavors_finish_in_order` proves both schedules.
  `test_failed_flavor_retains_other_publication_unless_sequential` proves partial publication reporting
  and fail-fast behavior. `test_concurrent_failures_report_every_flavor_or_preserve_programming_error`
  proves aggregate messages and original exception preservation.
- `test_friendly_group_preserves_key_errors` includes an argument-free error;
  `test_friendly_group_reraises_unknown_file_not_found` preserves an unrecognized launch exception.
- `test_base_default_context_follows_invocation_directory` covers both base commands after `chdir`;
  `test_default_project_root_is_current_directory` covers `build` after `chdir`.
  `test_run_threads_explicit_cabal_selection_and_offline` pins selection and offline forwarding.
- `test_build_then_publish_smokes_before_and_after_registry_mutation` pins local smoke, push, pull,
  digest lookup, and smoke against the published digest in order.

The preceding Linux CPU gate covered digest
`ac8dff76e3a45fd5d8c4b7f169f7be50afe889c1100c2cc319ead6b0f4abc979` on 2026-10-26;
that evidence was superseded by the formatter inventory change below.

The Phase 3.8 direct-WSL change removes the interpreter's last CPP route; its obsolete
`_FORMATTER_UNREADABLE` entry is removed here with the formatter source inventory. On 2026-10-26,
the complete Python gate passed again on native Windows (376 tests, 6.77 seconds) and the same
Linux CPU container (376 tests, 7.18 seconds), each with 1,585/1,585 statements and 460/460 branches
covered. The canonical covered-source digest below was remeasured after that source change.

#### Remaining Work

None.

### Sprint 1.4: The Python quality gate [Done]

**Status**: Done
**Implementation**: `hostbootstrap/check_code.py`, `hostbootstrap/test_all.py`, `pyproject.toml`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Make the Python half's gate one command with no bypass.

#### Deliverables

- `check_code` runs `ruff check`, then `black --check`, then `mypy`, over `hostbootstrap`, each as
  `sys.executable -m <tool>` with cwd the repository root, so the locked venv's tools check the checkout
  from any working directory.
- `test_all` sets the `HOSTBOOTSTRAP_TEST_ALL` sentinel and invokes pytest in-process; forwarded
  options (`-k`, `-m`, `-q`) retain their pytest meaning, and a forwarded path or node id replaces
  the default `tests` target.
- `tests/conftest.py` requires the sentinel, so there is one supported suite entry point.
- An unfiltered `test_all` run measures line and branch coverage of `hostbootstrap` and fails below
  `fail_under = 100`, so the host static gate holds the coverage floor rather than a separate manual
  command.
- `pyproject.toml` declares no pytest marker that no test applies, and its `description` names the thin
  host bootstrapper for project binaries.

#### Validation

`tests/test_dev_runners.py` contains these cases under the supported Python runner:

- `test_check_code_main_success_and_fail_fast` pins the locked interpreter's exact module argv;
  `test_check_code_run_returns_the_tool_exit_code` pins repository-root cwd.
- `test_test_all_main_sets_sentinel_and_forwards_args` pins the sentinel and `-k` forwarding;
  `test_test_all_forwards_paths_and_options` covers paths, node ids, and option values.
- `test_test_all_enforces_coverage_after_a_passing_full_run` covers passing and failing coverage and
  pytest failure propagation. `test_test_all_filtered_run_does_not_measure_partial_coverage` covers
  argument-bearing invocations.
- `test_coverage_reload_orders_real_dependencies_before_their_consumers` checks dependency ordering
  using actual imported modules. `test_module_entrypoints_exit` covers the module entry points without
  starting a nested measured suite.

On 2026-10-26, `poetry run python -m hostbootstrap.check_code` and the unfiltered
`poetry run python -m hostbootstrap.test_all` pass on native Windows (Python 3.14.7, Poetry 2.4.1)
and the CPU-only Ubuntu 24.04 container `hostbootstrap-cpu-gate-20261026` (Python 3.12.3,
Poetry 2.5.1, Linux 6.18.33.2 WSL2 kernel). Each test run passes 376 cases with 100% coverage:
1,585/1,585 statements and 460/460 branches. These are the Python legs of the host static gate.

The complete native Windows host static gate also passes: `cabal test all --test-options=--hide-successes`
from `core/` passes all 2,550 cases in 367.80 seconds; plain `cabal test all` from `demo/` passes its
consumer suite and its included 2,550 core cases (404.96 seconds), alongside the two Python legs above.
The Cabal commands initialize a UTF-8 console with `chcp 65001` and restore its original code page.
The provider-live component reports its declared unrequested-lane `Unsupported`, without claiming a
live provider run. An earlier standalone core attempt reported four failed cases; the subsequent full
standalone run and the demo's included core run pass. No failure cause is inferred from the rerun.

The CPU container has no NVIDIA file markers or GPU device and its real detector reports `linux-cpu` /
`amd64`. It runs the working-tree files in a native Linux checkout with its own in-project Poetry venv.
`HostBootstrap.Digest.measurePathSetDigest` measures `hostbootstrap`, `tests` and `pyproject.toml` as
`ac8dff76e3a45fd5d8c4b7f169f7be50afe889c1100c2cc319ead6b0f4abc979`; the tested Linux checkout's
byte-framed path/content measurement agrees. No baseline confirmation is claimed from the Windows
Python run alone.

#### Remaining Work

None.

### Sprint 1.5: One architecture value in the bootstrapper [Done]

**Status**: Done
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

`tests/test_substrate.py`'s `test_one_alias_table_serves_the_host_and_the_docker_engine` applies every
architecture alias to both boundaries. `tests/test_prereqs.py`'s parametrized `test_macos_checks`
accepts ARM64 aliases, including uppercase and padded spellings, and refuses `x86_64` with the
Apple Silicon message. `tests/test_bootstrap.py`'s
`test_verified_ghcup_download_rejects_unpinned_platform_arch` proves the pinned-download boundary.
`poetry run python -m hostbootstrap.check_code` checks the narrowed signatures under strict mypy.
The dated Python gate and line-and-branch coverage evidence are recorded in Sprint 1.4.

#### Remaining Work

None.

### Sprint 1.6: One way to run a command in the bootstrapper [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases in `tests/test_process.py`:

- `test_probe_reports_a_timeout_distinct_from_an_unavailable_command` exercises both stdio rows with
  a real timed-out child, including the checked-runner outcome.
- `test_probe_replaces_undecodable_output_and_merges_environment` pins replacement decoding and
  parent environment inheritance. `test_run_captures_stdout_stderr_env_and_quiet` proves quiet capture;
  `test_run_mirrors_output_with_a_prefix` proves non-quiet output.
- `test_run_captures_lines_larger_than_the_stream_limit` captures a 200,000-byte line;
  `test_drain_preserves_split_utf8_and_replaces_for_the_mirror_encoding` covers split UTF-8 and a
  restricted mirror encoding.
- `test_run_reports_an_executable_it_cannot_launch` pins the asynchronous launch refusal.
  `test_run_reaps_the_child_when_the_mirror_fails` observes the real child's exit;
  `test_run_awaits_an_already_exited_child_on_drain_failure` covers the completed-child branch.

`tests/test_cli.py`'s `test_missing_docker_launch_has_its_install_hint` pins the operator hint.
`tests/test_prereqs.py`'s `test_required_probe_timeout_reports_timeout` and
`tests/test_self_update.py`'s `test_self_update_renders_timeout` pin timeout-specific refusal text.
The dated Python gate and 100% line-and-branch coverage evidence are recorded in Sprint 1.4.

#### Remaining Work

None.

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

### Sprint 1.8: The self-update freshness check compares the commit pip would install [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases in `tests/test_self_update.py`:

- `test_parse_direct_url_rejects_malformed` pairs malformed JSON and metadata shapes with their
  specific refusal text.
- `test_remote_commit_invokes_git` pins all three qualified refs;
  `test_parse_ls_remote_selects_exact_branch_before_tag` covers exact branch precedence, lightweight-tag
  fallback, unmatched output, and ambiguity refusal.
  `test_parse_ls_remote_prefers_peeled_annotated_tag_commit` covers peeled-tag selection.
- `test_check_status_compares_installed_to_remote` uses different commits and records the ref;
  `test_check_status_selects_the_installed_or_explicit_ref` covers the installed revision, `main`
  fallback, and explicit override.

In `tests/test_cli.py`, `test_update_check_reports_up_to_date` and
`test_update_check_reports_available_update` assert the compared ref is printed for both results.
The dated Python gate evidence is recorded in Sprint 1.4.

#### Remaining Work

None.

### Sprint 1.9: The Python suite's Haskell-source guards hold what they claim [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases in `tests/test_packaging.py`:

- `test_haskell_host_processes_do_not_launch_bare_literal_commands` and
  `test_provider_surface_has_one_dispatch_and_no_definition_only_builders` apply both guards to the tree.
- `test_literal_process_scanner_reads_multiline_calls_and_ignores_comments` covers every launch
  spelling, multiline literals, and nested comments;
  `test_literal_process_scanner_keeps_comment_markers_inside_strings` protects real string content.
- `test_provider_builder_counter_requires_an_expression_use` proves exports, imports, signatures,
  defining equations, and string mentions contribute no production use, while an expression does.

The dated Python gate evidence is recorded in Sprint 1.4.

#### Remaining Work

None.

### Sprint 1.10: The CLI help renders on a cp1252 console [Done]

**Status**: Done
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

`poetry run python -m hostbootstrap.test_all` executes these cases in `tests/test_cli.py`:

- `test_help_renders_under_cp1252` enables maintainer commands and renders top-level, base-group,
  base-build, and base-build-and-push help through `CliRunner(charset="cp1252")`. Every invocation exits
  successfully without an exception; top-level help lists `check-code` and `test-all`.
- `test_help_text_is_cp1252_encodable` visits every command, subcommand, and parameter with maintainer
  commands enabled, requiring ASCII text and successful cp1252 encoding for all help strings.

The dated clean Python code check and test results are recorded in Sprint 1.4.

#### Remaining Work

None.

## Remaining Work

None.

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
