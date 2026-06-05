# hostbootstrap

A small host-installed Python CLI and a tiny family of prebuilt base container
images. Together they replace per-project bootstrap shells and redundant
multi-language Dockerfiles with one shared toolchain pulled from Docker Hub and
one declarative, typed `hostbootstrap.dhall` per project.

The current contract is intentionally narrow:

- each project declares one target per hardware substrate (`apple-silicon`,
  `linux-cpu`, `linux-gpu`)
- each substrate chooses one execution model (`Container`, `HostBinary`, or
  `HostDaemon`)
- each target chooses either `Cluster` lifecycle or `NoCluster`
- cluster lifecycle is always forwarded to the project command as
  `cluster up`, `cluster down`, or `cluster delete`
- `HostDaemon` daemon processes run only in the foreground via
  `hostbootstrap daemon run`
- hostbootstrap never writes launchd/systemd units and never configures Docker
  containers to restart after reboot

The full config schema is
[`documents/engineering/schema.md`](documents/engineering/schema.md). Detailed
language and engineering notes live under [`documents/`](documents/README.md).

## What You Get

- **Four prebuilt base images** on Docker Hub:
  `docker.io/tuee22/hostbootstrap:basecontainer-{cpu,cuda}-{amd64,arm64}`.
  They carry GHC 9.12, Cabal, pinned fourmolu/hlint, Go, Node, PureScript,
  Playwright, Python, Poetry, kube tools, LLVM/C++, Rust, optional CUDA, and a
  warm Haskell store.
- **One CLI** (`hostbootstrap`) that detects the host, validates host
  prerequisites, builds the selected target, runs project commands, and forwards
  cluster lifecycle to the project command.
- **No service-manager ownership**. After reboot, the operator calls
  `hostbootstrap cluster up` again and starts any host daemon with
  `hostbootstrap daemon run`. If a deployment needs automatic restart, the
  operator owns that external launchd/systemd wrapper.

Single-arch tags only, never manifest lists. The CLI always knows the host arch,
so it references the one correct arch tag directly.

Derived projects follow the rules in
[`documents/engineering/derived_project_standards.md`](documents/engineering/derived_project_standards.md):
inherit the base image, match the warm-store `cabal.project` contract, gate
image builds on `<project> check-code`, link executables statically at `-O2`,
and never rebuild what the warm store already builds.

## Installing The CLI

Install `pipx` first:

```bash
# Apple Silicon / macOS
brew install pipx
pipx ensurepath

# Ubuntu 24.04
sudo apt update
sudo apt install -y pipx
pipx ensurepath
```

Then install hostbootstrap as an isolated host CLI app:

```bash
pipx install "git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"
```

For local development against a checkout:

```bash
pipx install --force /path/to/hostbootstrap
```

hostbootstrap provisions its own native `dhall-to-json` binary on first use. It
downloads a pinned, SHA256-verified static release into
`~/.cache/hostbootstrap/` and uses that one exclusively.

To develop hostbootstrap itself:

```bash
poetry install
poetry run python -m hostbootstrap.check_code
poetry run python -m hostbootstrap.test_all
```

`check_code` and `test_all` are module entry points under `hostbootstrap/`, not
shell commands on `PATH`.

## The Config

The schema is injected by the CLI as `H`; project files need no import line.

```dhall
let container =
      H.Model.Container
        H.Container::{ dockerfile = "docker/app.Dockerfile" }

in  H.config
      { project = "app"
      , substrates =
        [ H.entry H.Substrate.AppleSilicon (H.noCluster container)
        , H.entry H.Substrate.LinuxCpu (H.noCluster container)
        , H.entry H.Substrate.LinuxGpu (H.noCluster container)
        ]
      }
```

The `project` value is also the command name. Containers must expose it as a
tini-wrapped entrypoint:

```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/app"]
```

Host-native models build `exe:<project>` into `.build/<project>` using the
standard templated Cabal command:

```bash
cabal install --installdir .build --install-method=copy --overwrite-policy=always exe:<project>
```

## Lifecycles

`NoCluster` targets support `hostbootstrap build` and `hostbootstrap run`.
Cluster commands fail fast because there is no project cluster lifecycle to
forward. This is the right choice for command-oriented projects such as MCTS:

```bash
hostbootstrap run test all
hostbootstrap run bench criterion
```

`Cluster` targets support the cluster command group. hostbootstrap builds the
selected model, then forwards lifecycle to the same project command used by
`run`:

```bash
hostbootstrap cluster up
hostbootstrap daemon run
hostbootstrap cluster down
hostbootstrap cluster delete
```

For `Container`, those commands run inside a one-shot `docker run --rm` with the
declared mounts. For `HostBinary`, they run as `.build/<project> cluster ...`.
For `HostDaemon`, cluster commands still only forward
`.build/<project> cluster ...`. The configured daemon is run separately and in
the foreground:

```bash
hostbootstrap daemon run
```

That foreground process is owned by the invoking shell, test harness, launchd
unit, or systemd unit. hostbootstrap does not write PID files, redirect logs, or
restart a crashed daemon.

No Docker run emitted by hostbootstrap includes `--restart`, and no host daemon is
installed as a launchd/systemd unit.

Every `hostbootstrap run ...` and cluster handoff receives the selected target
context:

| variable | value |
|---|---|
| `HOSTBOOTSTRAP_TARGET` | selected substrate entry (`apple-silicon`, `linux-cpu`, or `linux-gpu`) |
| `HOSTBOOTSTRAP_MODEL` | selected model (`container`, `host-binary`, or `host-daemon`) |
| `HOSTBOOTSTRAP_LIFECYCLE` | selected lifecycle (`cluster` or `no-cluster`) |

This context lets a project command resolve target-specific behavior while
hostbootstrap still forwards the same project command shape for every target.

## Force Target

Normally hostbootstrap selects the substrate entry matching the detected host.
For matrix validation on a single machine, build/run/cluster commands accept
`--force-target`:

```bash
hostbootstrap cluster up --force-target apple-silicon
hostbootstrap cluster down --force-target apple-silicon
hostbootstrap run --force-target linux-gpu test all
```

The forced target chooses the declared model and base-image flavor. The actual
host still controls how the build is executed, so forcing an Apple target on a
Linux host does not run macOS prerequisite checks.

`doctor` intentionally has no `--force-target`; it validates the actual host.

## Model Summary

| Model | Build/run shape | Cluster lifecycle |
|---|---|---|
| `Container` | Build project image, run tini-wrapped project entrypoint | one-shot `docker run --rm <image> cluster ...` |
| `HostBinary` | Build `.build/<project>` | `.build/<project> cluster ...` |
| `HostDaemon` | Build `.build/<project>` | `.build/<project> cluster ...`; daemon runs separately via `hostbootstrap daemon run` |

`HostDaemon` has one required field, `daemon`, which contains the arguments
appended to `.build/<project>` when `hostbootstrap daemon run` executes the
long-running foreground process.

## CLI Surface

| Command | What it does |
|---|---|
| `hostbootstrap doctor` | Detect host; validate prerequisites for the detected target |
| `hostbootstrap build [--force-target <substrate>]` | Build the selected target |
| `hostbootstrap run [--force-target <substrate>] [args...]` | Build if needed, then pass args to the project entrypoint |
| `hostbootstrap cluster up [--force-target <substrate>]` | Forward project `cluster up` for `Cluster` targets |
| `hostbootstrap cluster down [--force-target <substrate>]` | Forward project `cluster down` for `Cluster` targets |
| `hostbootstrap cluster delete [--force-target <substrate>]` | Forward project `cluster delete` for `Cluster` targets |
| `hostbootstrap daemon run [--force-target <substrate>]` | Run the selected `HostDaemon` process in the foreground |
| `hostbootstrap base build` | Cold-rebuild base image(s) locally |
| `hostbootstrap base build-and-push` | Cold-rebuild and push base image(s) |

All project state under `.data/` is preserved by hostbootstrap commands. Any
deeper cluster-state deletion is the project command's responsibility.

## Repository Map

```text
hostbootstrap/
├── docker/basecontainer.Dockerfile
├── hostbootstrap/
│   ├── base_image.py
│   ├── cli.py
│   ├── dhall/package.dhall
│   ├── docker_ops.py
│   ├── models/
│   │   ├── container.py
│   │   ├── host_binary.py
│   │   └── host_daemon.py
│   ├── prereqs.py
│   ├── spec.py
│   └── substrate.py
├── support/haskell-deps/
├── tests/
└── documents/
```
