# Python / Haskell Boundary

**Status**: Authoritative source
**Supersedes**: the offline/common-path and winget-installed-Haskell narratives
**Referenced by**: [documents index](../README.md), [build and run model](build_and_run_model.md), [prerequisites](../engineering/prerequisites.md), [self update](../engineering/self_update.md)

> **Purpose**: Define the thin Python bootstrapper's actual pre-binary responsibilities, project
> selection contract, and online/offline behavior.

## TL;DR

In the ordinary project path, Python selects one top-level Cabal file, validates one filename/package/
executable identity, provisions the pinned Haskell tools, builds host-native, and hands off to the
project binary. Online builds refresh only a missing/stale package index; `--offline` requires the
toolchain/index/store to be present and forbids provisioning or index/network resolution. Haskell owns
every later project config and lifecycle action. Explicit pipx self-update and repository maintainer
commands are separate distribution surfaces, not exceptions that move project runtime ownership into
Python.

## Current Status

The ownership, selection, verified-download, and explicit offline boundaries are implemented. Windows
intentionally uses a child subprocess rather than POSIX process replacement. Phase status belongs in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Ownership boundary

For `doctor`/`build`/`run`, Python owns only work that must happen before a project binary exists:

1. discover one top-level `*.cabal` file, or consume an explicit `--cabal-file` selection;
2. parse exactly one package `name` and one `executable` stanza;
3. require the selected filename stem, package name, and executable name to be identical;
4. assert the pre-binary host floor;
5. ensure GHCup, GHC 9.12.4, and Cabal;
6. classify the local Cabal index and refresh it only when missing/stale in online mode;
7. build the executable with a repo-local store and copy it to `.build/<identity>` only when its bytes
   changed;
8. invoke the copied binary's exact private identity-install entry, which creates no config and returns no key
   material to Python;
9. invoke it with the requested arguments.

The installed distribution also owns the explicit `update` command. In a source checkout, the
maintainer-only command set additionally exposes base-image build/publish and repository check/test
wrappers. Those operator-invoked distribution tasks are outside the project handoff described above:
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

## Who detects the host

The bootstrapper detects the outer-host realization, because something must classify the host before a
project binary exists and § M gives that job to the side that runs first. The binary **receives** that
answer; it does not classify the same host a second time.

The seam is the pair of values the bootstrapper sets on the binary it launches:

```text
HOSTBOOTSTRAP_HOST_SUBSTRATE = apple-silicon | linux-cpu | linux-gpu | windows-cpu | windows-gpu
HOSTBOOTSTRAP_HOST_ARCH      = amd64 | arm64
```

Each value is one spelling of a closed vocabulary, and the pair is set explicitly on the handoff —
`execve` on POSIX, the child's environment on Windows — rather than left in the ambient environment for
the binary to pick up. This is the one place a governed document presents an environment value as a
supported input, and it is a statement from a known sender to a known receiver, not configuration.
Typed configuration remains Dhall, owned by the binary.

A binary invoked directly, with no bootstrapper in front of it, sees no such pair and falls back to its
own detection — `HostBootstrap.Substrate.detectHere`, labelled as the fallback where it lives. A pair
that arrives half-set is refused rather than fallen back from: the sender claimed the seam, so
re-deriving what it meant to say is how the two sides come to disagree.

The binary's suite reads the bootstrapper's source and asserts that both field names and all seven
vocabulary spellings appear there, so the two ends of the seam are checked against each other rather
than agreed by comment.

## Closed vocabularies

The bootstrapper names three things with closed enumerations rather than with text: the outer-host
realization (`SubstrateName`), the base-image family (`Flavor`), and the architecture (`Arch`, whose two
members are `amd64` and `arm64`). `Substrate.arch` carries the third, so a detected host's architecture
is already narrowed by the time anything reads it.

One alias table in `hostbootstrap/substrate.py` maps every outside spelling — the machine string
`platform.machine()` reports, the answer `docker info` renders, and the operator's `--arch` flag — into
`Arch`. `parse_arch` is that table's only reader, so the host boundary and the Docker-engine boundary
cannot disagree about what `aarch64` means. Every tag, image reference, build argument, download URL, and
per-architecture lookup table downstream takes `Arch`, which is why none of them re-derives validity and
why a lookup keyed by architecture cannot miss.

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

- `_build_native` runs `cabal update` only when the secure Hackage index is missing or older than the
  declared freshness window.
- Linux downloads the pinned architecture-specific GHCup binary with resolved `curl`.
- Windows downloads the pinned GHCup executable with PowerShell `Invoke-WebRequest`.
- GHCup installs and Cabal dependency resolution require their upstream indexes/artifacts when not
  cached.

`--offline` is explicit and fail-closed:

- an absent GHCup/GHC/Cabal probe refuses before any installer/download;
- a missing Cabal index refuses before Cabal;
- Cabal receives `--offline`, so an unresolved cached dependency is reported as an offline-cache
  failure;
- no package-index update runs.

## Download provenance

GHCup bootstrap provenance is immutable code data: version `0.2.6.2`, architecture-specific HTTPS URL,
and the SHA-256 published in that release's `SHA256SUMS`. Linux and Windows download to a temporary file,
verify its digest in Python, and install it only after a match. No bootstrap script is piped to a shell.

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

The boundary is closed only when tests prove:

- Cabal selection ambiguity and every stem/package/executable mismatch fail before build;
- the Haskell declared name and invoked executable identity agree before dispatch;
- POSIX exec and Windows child-process provenance are documented and surfaced;
- a command that cannot be launched is reported as such, not as the failure of a command that ran;
- online/offline modes and fresh-index/unchanged-copy no-ops behave as declared;
- Linux checks its download prerequisites;
- every downloaded bootstrap artifact is verified before execution;
- the host-native project never imports an in-image absolute freeze.

Phase status belongs in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [prerequisites](../engineering/prerequisites.md) — asserted host floor.
- [build and run model](build_and_run_model.md) — two Cabal projects and downstream lifecycle.
- [base image](../engineering/base_image.md) — image-input provenance target.
- [self update](../engineering/self_update.md) — explicit Python distribution update.
