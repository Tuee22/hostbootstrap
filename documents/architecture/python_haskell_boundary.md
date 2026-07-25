# Python / Haskell Boundary

**Status**: Authoritative source
**Supersedes**: the offline/common-path and winget-installed-Haskell narratives
**Referenced by**: [documents index](../README.md), [build and run model](build_and_run_model.md), [prerequisites](../engineering/prerequisites.md), [self update](../engineering/self_update.md)

> **Purpose**: Define the thin Python bootstrapper's actual pre-binary responsibilities and the
> provenance/offline gaps that remain.

## TL;DR

In the ordinary project path, Python discovers exactly one top-level Cabal file, provisions the pinned
Haskell tools, performs an online host build, and hands off to the project binary. It does not currently
offer verified downloads, an offline mode, or explicit Cabal-file selection; Haskell owns every later
project config and lifecycle action. Explicit pipx self-update and repository maintainer commands are
separate distribution surfaces, not exceptions that move project runtime ownership into Python.

## Current Status

The ownership boundary is implemented, but the network, provenance, project-discovery, and Windows
process-handoff limitations below remain open. Phase status belongs in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Ownership boundary

For `doctor`/`build`/`run`, Python owns only work that must happen before a project binary exists:

1. discover one top-level `*.cabal` file in the selected project root;
2. derive the **project** identifier from that filename;
3. parse that file for exactly one `executable` stanza and derive the executable name separately;
4. assert the pre-binary host floor;
5. ensure GHCup, GHC 9.12.4, and Cabal;
6. run `cabal update`;
7. build the executable with a repo-local store and copy it to `.build/<executable>`;
8. invoke it with the requested arguments.

The installed distribution also owns the explicit `update` command. In a source checkout, the
maintainer-only command set additionally exposes base-image build/publish and repository check/test
wrappers. Those operator-invoked distribution tasks are outside the project handoff described above:
they neither initialize project config nor perform provider, project-image, cluster, service, test-run,
or teardown lifecycle work.

On POSIX, handoff uses `exec`. On Windows, Python uses `subprocess.run` and returns the child's exit code;
it does not replace the Python process. Documentation should not claim identical process provenance on
all platforms.

The Haskell project binary owns config, Docker/runtime reconciliation, provider frames, project-image
build, cluster/workload lifecycle, services, tests, and teardown.

## Project discovery

The current CLI accepts `--project-root`, not an explicit Cabal-file option. Discovery requires exactly
one top-level `.cabal` file. Its filename stem and its single `executable` stanza may differ:

```text
project identity    = cabal-file stem
binary identity     = executable stanza name
```

The bootstrapper's stable output path uses the executable name. Descriptions that say it merely derives
the binary name from the Cabal filename are incomplete.

The parser is intentionally small and line-oriented; it is not a full Cabal parser. The target accepts an
explicit Cabal-file selection when discovery is ambiguous, parses the package/project identity with a
real Cabal-aware mechanism, and enforces **one identity** across Cabal package name, sole executable,
config filename, image name, and project namespace. If distinct identities are genuinely required, the
unused parallel identity must be eliminated from lifecycle naming rather than silently tolerated.

## Network and offline behavior

The current path is online:

- `_build_native` runs `cabal update` on every build, even when GHC/Cabal are already installed.
- Linux downloads the pinned architecture-specific GHCup binary with resolved `curl`.
- Windows downloads the pinned GHCup executable with PowerShell `Invoke-WebRequest`.
- GHCup installs and Cabal dependency resolution require their upstream indexes/artifacts when not
  cached.

Therefore “offline after installation” and “no network call on the common path” are false. Linux
asserts `curl` as part of the pre-binary floor before using it.

The target offline mode must be explicit:

- `--offline` forbids index refresh and all downloads;
- every required tool/index/package must be proven present before build;
- missing cache content produces a deterministic refusal naming the artifact;
- normal online mode may refresh, but reports that network access is required.

## Download provenance

GHCup bootstrap provenance is immutable code data: version `0.2.6.2`, architecture-specific HTTPS URL,
and the SHA-256 published in that release's `SHA256SUMS`. Linux and Windows download to a temporary file,
verify its digest in Python, and install it only after a match. No bootstrap script is piped to a shell.

Winget is a Windows host prerequisite and is used by later Windows reconcilers. It does **not** install
the Haskell toolchain in the current Python bootstrap; PowerShell downloads GHCup, and GHCup installs
GHC/Cabal.

## Host-native and container builds

The host-native build uses the consumer's host `cabal.project` and `.build/cabal-store`. The later Linux
container build uses a distinct container-only project file that imports the base image's absolute
freeze. See [build and run model](build_and_run_model.md). Python does not build the project image.

## Config boundary

Python does not read, generate, or initialize Dhall. `project init`, `service init`, and the test config
generator are project-binary surfaces. A normal config-gated command fails if the executable-sibling
config is absent.

## Validation

The boundary is closed only when tests prove:

- filename and executable identities are handled distinctly;
- POSIX exec and Windows subprocess provenance are documented and surfaced;
- online/offline modes behave as declared;
- Linux checks its download prerequisites;
- every downloaded bootstrap artifact is verified before execution;
- the host-native project never imports an in-image absolute freeze.

Phase status belongs in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [prerequisites](../engineering/prerequisites.md) — asserted host floor.
- [build and run model](build_and_run_model.md) — two Cabal projects and downstream lifecycle.
- [base image](../engineering/base_image.md) — image-input provenance target.
- [self update](../engineering/self_update.md) — explicit Python distribution update.
