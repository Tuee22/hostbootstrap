# Node

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [purescript.md](purescript.md)

> **Purpose**: Document the Node.js toolchain the base image ships.

This page documents what the base image ships for Node.js.

The base image installs the **latest upstream Node.js** for the target arch
(resolved on the host by `hostbootstrap/base_image.py`). The tarball lands at
`/usr/local`; the upstream `npm` wrapper is replaced with a small shim
pointing at `npm-cli.js` so the executable name survives upstream layout
changes.

## Global packages

The image globally installs:

* `@playwright/test`, `playwright`
* `esbuild`, `typescript`
* `purs-tidy`, `spago`

That set is the minimal toolchain every project needs to build, type-check,
and run browser tests.

## Caches

* `NPM_CONFIG_CACHE=/opt/cache/npm`
* `NPM_CONFIG_PREFIX=/opt/build/node/global`
