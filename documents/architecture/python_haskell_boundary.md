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

On POSIX, handoff uses `exec`. On Windows, Python uses `subprocess.run` and returns the child's exit code;
it does not replace the Python process. Documentation should not claim identical process provenance on
all platforms.

The Haskell project binary owns config, installed project cryptography, Docker/runtime reconciliation,
provider frames, project-image build, cluster/workload lifecycle, services, tests, and teardown. Immediately
after the stable copy, Python asks that binary to install or validate its handoff secret/public pair, distinct
build-signing key, and distinct activation secret/public pair. This is an execution handoff, not transferred
cryptographic ownership: Python neither generates, reads, returns, nor interprets those keys. `project init`
continues to own only explicit project configuration initialization.

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
- POSIX exec and Windows subprocess provenance are documented and surfaced;
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
