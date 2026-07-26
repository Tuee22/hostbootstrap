# PureScript

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [node.md](node.md)

> **Purpose**: Document the PureScript toolchain the base image ships.

This page documents what the base image ships for PureScript.

The rolling workflow installs the current upstream `purs` release for the target architecture, plus
current compatible `purs-tidy` and `spago` versions via npm (see [node.md](node.md)). Architecture maps
to the upstream asset:

* `amd64` → `linux64.tar.gz`
* `arm64` → `linux-arm64.tar.gz`

PureScript projects use `spago` for builds and `purs-tidy` for formatting —
both shipped globally, both runnable from the container.

The `hostbootstrap-demo` worked consumer (`demo/`) uses this toolchain for its
web build: the build-image bridge step generates PureScript types from the `warp`/`wai` webservice's API
types via `purescript-bridge`, then `spago build` + `esbuild` bundle the Halogen SPA. The web
build runs while `project up` builds the project image, so the live `spago build` +
`esbuild` bundle is exercised as part of standing up the persistent stack. The
bridge-generated `BudgetView` carries the demo's `message` field, so the SPA
`#message` element cannot drift from the API type it renders.
