# PureScript

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [node.md](node.md)

> **Purpose**: Document the PureScript toolchain the base image ships.

This page documents what the base image ships for PureScript.

The base image installs the **latest upstream `purs`** for the target arch,
plus `purs-tidy` and `spago` via npm (see [node.md](node.md)). The resolver
maps the arch to the upstream asset name:

* `amd64` → `linux64.tar.gz`
* `arm64` → `linux-arm64.tar.gz`

PureScript projects use `spago` for builds and `purs-tidy` for formatting —
both shipped globally, both runnable from the container.

The `hostbootstrap-demo` worked consumer (`demo/`) uses this toolchain for its
web build: `demo web bridge` generates PureScript types from the servant API via
`purescript-bridge`, then `spago build` + `esbuild` bundle the Halogen SPA (the
live web build is exercised during the demo run).
