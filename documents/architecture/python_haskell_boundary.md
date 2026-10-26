# Python / Haskell Boundary

**Status**: Authoritative source
**Supersedes**: the offline/common-path and winget-installed-Haskell narratives
**Referenced by**: [documents index](../README.md), [build and run model](build_and_run_model.md), [prerequisites](../engineering/prerequisites.md), [self update](../engineering/self_update.md)

> **Purpose**: Define the thin Python bootstrapper's actual pre-binary responsibilities, project
> selection contract, and online/offline behavior.

## TL;DR

In the ordinary project path, Python selects one top-level Cabal file, validates one filename/package/
executable identity, provisions the host build toolchain (on Linux the C build libraries, then GHCup, the
pinned GHC, and GHCup's recommended Cabal, which is not pinned), builds host-native, and hands off to the
project binary. Online builds refresh only a missing/stale package index; `--offline` requires the
toolchain/index/store to be present and forbids provisioning or index/network resolution. Haskell owns
every later project config and lifecycle action. Explicit pipx self-update and repository maintainer
commands are separate distribution surfaces, not exceptions that move project runtime ownership into
Python.

## Current Status

The ownership, selection, and verified-download boundaries are implemented, and Windows intentionally uses
a child subprocess rather than POSIX process replacement. These points fall short of the contract this
page states:

- **The Cabal index location ignores Cabal's own resolution.** `cabal_index_path` reads `CABAL_DIR` and
  otherwise `~/.cabal`; it does not resolve `%APPDATA%\cabal` on Windows or the XDG cache location. On a
  Windows host without `CABAL_DIR` the index therefore reads as missing, so every online build runs
  `cabal update` and `--offline` always refuses. The target resolution order is `CABAL_DIR`, then
  `%APPDATA%\cabal` on Windows, then `~/.cabal` when it is a directory, then `$XDG_CACHE_HOME/cabal` or
  `~/.cache/cabal`. The offline driver cases, the online stale-index case, and the
  `run --offline --cabal-file` case that the online/offline row of [Validation](#validation) relies on are
  not yet in the suites.
- **The asynchronous runner raises the OS launch exception.** A command `process.run` cannot start
  raises the operating system's exception rather than `CommandError` carrying `CommandUnavailable`; the
  target is that outcome on every platform, with the CLI's missing-binary hint read from it.
- **The Apple Silicon check keeps its own alias set.** `_check_macos_arm64` compares
  `platform.machine()` against a literal `arm64`/`aarch64` set instead of accepting the host exactly when
  `parse_arch` returns `Arch.ARM64`.

[The Python pre-binary floor phase](../../DEVELOPMENT_PLAN/phase-1-python-pre-binary-floor.md) owns
these three.

- **The receiver admits a pair the sender cannot produce, and the seam guard is textual.**
  `parseStatedHost` accepts a stated `apple-silicon` paired with `amd64`, and `SubstrateSpec` checks the
  bootstrapper's spellings with a whole-file infix match, so a spelling that survives only in a comment
  satisfies it. The target refuses that pair with the Intel-Mac message `classify` gives and matches the
  definition lines of `hostbootstrap/substrate.py`.
  [The host-tools and substrate-detection phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md)
  owns both.

Phase status belongs in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Ownership boundary

Python owns only work that must happen before a project binary exists:

1. discover one top-level `*.cabal` file, or consume an explicit `--cabal-file` selection;
2. parse exactly one package `name` and one `executable` stanza;
3. require the selected filename stem, package name, and executable name to be identical;
4. assert the pre-binary host floor;
5. on Linux only, ensure the C build libraries GHC and the dependency closure link against
   (`build-essential`, `libgmp-dev`, `libncurses-dev`, `libtinfo-dev`, `pkg-config`, `zlib1g-dev`): one
   all-of `dpkg-query -s` probe, and when any is missing, `sudo -n apt-get update` followed by
   `sudo -n apt-get install -y` of the whole set;
6. ensure GHCup, GHC 9.12.4, and Cabal (GHCup's recommended version, `ghcup install cabal --set`; only GHC
   is pinned);
7. classify the local Cabal index and refresh it only when missing/stale in online mode;
8. build the executable with a repo-local store and copy it to `.build/<identity>` only when its bytes
   changed;
9. invoke the copied binary's exact private identity-install entry, which creates no config and returns no key
   material to Python;
10. invoke it with the requested arguments.

Each command runs a prefix of that list:

| Command | Steps |
|---|---|
| `doctor` | 4 only: it detects the host and asserts the floor, and reads no project |
| `build` | 1–9: it builds, installs the identity, and prints the binary path without invoking it |
| `run` | 1–10 |

The installed distribution also owns the explicit `update` command. In a source checkout, the
maintainer-only command set additionally exposes base-image build/publish and repository check/test
wrappers. Those operator- or agent-invoked distribution tasks are outside the project handoff described above:
they neither initialize project config nor perform provider, project-image, cluster, service, test-run,
or teardown lifecycle work.

On POSIX, handoff uses `exec`. On Windows, Python launches the binary as a child and returns its exit code;
it does not replace the Python process. Documentation should not claim identical process provenance on
all platforms.

The Haskell project binary owns config, installed project cryptography, Docker/runtime reconciliation,
provider frames, project-image build, cluster/workload lifecycle, services, tests, and teardown. Immediately
after the stable copy, Python asks that binary to install or validate its handoff secret/public pair, distinct
build-signing key, and distinct activation secret/public pair. This is an execution handoff, not transferred
cryptographic ownership: Python neither generates, reads, returns, nor interprets those keys. `project init`
continues to own only explicit project configuration initialization.

New logic goes to Haskell by default — reusable host primitives in `hostbootstrap-core`, consumer-specific
actions in the project binary — and a Python addition must be justified by the pre-binary constraint
([§ M](../../DEVELOPMENT_PLAN/development_plan_standards.md#m-python-thin--haskell-core-boundary)).

## One way to run a command

`hostbootstrap/process.py` is the only module in the bootstrapper that launches a subprocess, in two
shapes: an asynchronous runner that streams and captures a long build's output, and a synchronous probe
for the short host questions asked before any event loop exists. The probe names the child's stdio
disposition with a closed value rather than with a pair of booleans.

A command fails in two different ways, and every caller cares which: it ran and returned non-zero, or it
never started. The probe returns that distinction as a value — a completed result, or a statement that
the command was unavailable and why — so the prerequisite checks, host detection, self-update, and the
maintainer quality gates each wrap one value into their own error type instead of deriving the same fact
from which exception they happened to catch.

The asynchronous runner does not carry that distinction as a value. A command that cannot be started
raises the operating system's exception (for example `FileNotFoundError`) out of the runner; only a
command that ran and exited non-zero becomes a `CommandError` from its checked form. The target is that
the runner reports a launch failure as `CommandUnavailable` too, so no caller tells "unavailable" from
"failed" by the exception it caught (see [Current Status](#current-status)).

## Who detects the host

The bootstrapper detects the outer-host realization, because something must classify the host before a
project binary exists and
[§ M](../../DEVELOPMENT_PLAN/development_plan_standards.md#m-python-thin--haskell-core-boundary) gives
that job to the side that runs first. The binary **receives** that
answer; it does not classify the same host a second time.

The seam is the pair of values the bootstrapper sets on the binary it launches:

```text
HOSTBOOTSTRAP_HOST_SUBSTRATE = apple-silicon | linux-cpu | linux-gpu | windows-cpu | windows-gpu
HOSTBOOTSTRAP_HOST_ARCH      = amd64 | arm64
```

The bootstrapper sends one spelling of each closed vocabulary, and it sets the pair explicitly on the
handoff — `execve` on POSIX, the child's environment on Windows — layered over its own environment rather
than relying on the binary to inherit it. This pair is the only environment input the Python bootstrapper
sets on the binary, and it is a host statement, not configuration. Typed configuration remains Dhall,
owned by the binary. Other environment-carried coordinates belong to the binary's own launch contracts
(for example the service activation variables in
[composition methodology](composition_methodology.md)) and are not part of this seam.

The receiver does not authenticate the sender. `HostBootstrap.Substrate.detect` reads the two variables
from its process environment and trusts any pair it finds, whoever set it: a shell that exports them, or
a process launched by a binary that received them and inherited its environment, presents the same
statement as the bootstrapper. The receiver is also more permissive than the sender: it parses the
architecture with the same alias set as host detection, so `x86_64` and `aarch64` are accepted alongside
`amd64` and `arm64`, and a stated `apple-silicon` paired with `amd64` is currently admitted (see
[Current Status](#current-status)).

A binary whose environment carries neither variable falls back to its own detection —
`HostBootstrap.Substrate.detectHere`, labelled as the fallback where it lives. A pair that arrives
half-set is refused rather than fallen back from: the sender claimed the seam, so re-deriving what it
meant to say is how the two sides come to disagree.

The binary's suite (`SubstrateSpec`) reads `hostbootstrap/substrate.py` and asserts that both field
names and all seven vocabulary spellings appear in it as quoted string literals. That is a textual
presence check: it catches a renamed field or spelling, but not a mapping in the bootstrapper that
drifts while the literals remain, and a spelling that survives only in a comment currently satisfies it
(see [Current Status](#current-status)).

## Closed vocabularies

The bootstrapper names three things with closed enumerations rather than with text: the outer-host
realization (`SubstrateName`), the base-image family (`Flavor`), and the architecture (`Arch`, whose two
members are `amd64` and `arm64`). `Substrate.arch` carries the third, so a detected host's architecture
is already narrowed by the time anything reads it.

One alias table in `hostbootstrap/substrate.py` maps the machine string `platform.machine()` reports and
the answer `docker info` renders into `Arch`, and `parse_arch` is the reader both of those boundaries go
through, so the host boundary and the Docker-engine boundary cannot disagree about what `aarch64` means.
Two inputs do not go through the table:

- the maintainer `base` commands' `--arch` flag is a choice over the canonical spellings only, so it
  accepts `amd64` and `arm64` and rejects `x86_64` and `aarch64` as a usage error;
- the Apple Silicon prerequisite check compares `platform.machine()` against its own literal set
  (`arm64`, `aarch64`) rather than calling `parse_arch` (see [Current Status](#current-status)).

Every tag, image reference, build argument, download URL, and per-architecture lookup table downstream
takes `Arch`, which is why none of them re-derives validity. A per-architecture table can still lack an
entry: the GHCup download table, for example, has no Windows `arm64` row (see
[network and offline behavior](#network-and-offline-behavior)).

## Project discovery

The CLI accepts `--project-root` plus optional `--cabal-file`. Without explicit selection, more than one
top-level `.cabal` file is a fail-fast ambiguity. The selected file must be an existing direct child of
the project root. Its three build identities must agree:

```text
project identity = cabal-file stem = package name = executable stanza name
```

The parser is intentionally small and line-oriented; it validates the top-level package field and sole
executable stanza needed by the bootstrap boundary rather than pretending to be a general Cabal parser.
The Haskell entrypoint additionally compares its declared project name to the actual invoked executable
name before command dispatch, so a renamed/mismatched binary cannot select a different sibling config
namespace.

## Network and offline behavior

Online mode permits network work when required:

- `_build_native` runs `cabal update` only when the secure Hackage index is missing or older than seven
  days (by file modification time). The index is `packages/hackage.haskell.org/01-index.tar` under
  `CABAL_DIR` when that variable is set, else under `~/.cabal` (see [Current Status](#current-status) for
  the resolution Cabal itself uses on Windows and XDG hosts).
- Linux refreshes the apt package index and installs the C build libraries with `sudo -n apt-get` when the
  all-of probe reports any of them missing.
- Linux downloads the pinned architecture-specific GHCup binary with resolved `curl`.
- Windows on `amd64` downloads the pinned GHCup executable with PowerShell `Invoke-WebRequest`. Windows on
  `arm64` has no pinned download, so a host without GHCup refuses with "no pinned GHCup download"; the
  bootstrap does not support it.
- Apple Silicon installs GHCup with `brew install ghcup`. Its provenance is Homebrew's current formula,
  not a version or digest pinned here.
- GHCup installs and Cabal dependency resolution require their upstream indexes/artifacts when not
  cached.

`--offline` is explicit and fail-closed:

- on Linux, a missing C build library refuses before any apt command;
- an absent GHCup/GHC/Cabal probe refuses before any installer/download;
- a missing Cabal index refuses before Cabal; a present but stale index is accepted;
- Cabal receives `--offline`, so an unresolved cached dependency is reported as an offline-cache
  failure;
- no package-index update runs.

## Download provenance

GHCup bootstrap provenance is immutable code data: version `0.2.6.2`, architecture-specific HTTPS URL,
and the SHA-256 published in that release's `SHA256SUMS`, for Linux `amd64`/`arm64` and Windows `amd64`.
Those hosts download to a temporary file, verify its digest in Python, and install it only after a match.
No bootstrap script is piped to a shell. Apple Silicon is outside this pin: Homebrew supplies GHCup, so
its provenance is Homebrew's. GHC and Cabal are installed by GHCup on every host.

Winget is a Windows host prerequisite and is used by later Windows reconcilers. It does **not** install
the Haskell toolchain in the current Python bootstrap; PowerShell downloads GHCup, and GHCup installs
GHC/Cabal.

## Host-native and container builds

The host-native build and later Linux container build both use the consumer's host-compatible
`cabal.project`; the inherited Cabal store is an opportunistic cache and misses resolve normally. See
[build and run model](build_and_run_model.md). Python does not build the project image.

## Config boundary

Python does not read, generate, or initialize Dhall. `project init`, `service init`, and the test config
generator are project-binary surfaces. A normal config-gated command fails if the executable-sibling
config is absent.

## Validation

These suites hold the boundary (Python under `tests/`, Haskell under
`core/hostbootstrap-core/test/`):

| Obligation | Suite |
|---|---|
| Cabal selection ambiguity and every stem/package/executable mismatch fail before build | `tests/test_bootstrap.py` |
| the installed identity matches the invoked executable before dispatch | `AuthoritySpec` |
| POSIX exec and Windows child-process provenance are surfaced | `tests/test_bootstrap.py` |
| a command that cannot be launched is reported as such, not as the failure of a command that ran | `tests/test_process.py`, `tests/test_bootstrap.py`, `tests/test_cli.py`, `tests/test_dev_runners.py` |
| online/offline modes, the Linux build-library refusal, and fresh-index/unchanged-copy no-ops behave as declared | `tests/test_bootstrap.py`, `tests/test_cli.py` |
| Linux checks its download prerequisites | `tests/test_prereqs.py` |
| every pinned GHCup download (Linux, Windows `amd64`) is digest-verified before installation | `tests/test_bootstrap.py` |
| the host-native project never imports an in-image absolute freeze | `tests/test_warm_store.py` |
| the host-seam field names and spellings appear in the bootstrapper | `SubstrateSpec` |

Phase status belongs in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [prerequisites](../engineering/prerequisites.md) — asserted host floor.
- [build and run model](build_and_run_model.md) — one Cabal project for host, in-VM, and image builds, and
  downstream lifecycle.
- [base image](../engineering/base_image.md) — image-input provenance target.
- [self update](../engineering/self_update.md) — explicit Python distribution update.
