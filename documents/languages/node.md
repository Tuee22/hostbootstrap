# Node

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [purescript.md](purescript.md)

> **Purpose**: Document the Node.js toolchain the base image ships.

This page documents what the base image ships for Node.js.

The rolling workflow selects the latest Node.js LTS release that publishes the target architecture. The
tarball lands at
`/usr/local`; the tarball's `npm`, `npx`, and `corepack` links are removed, and `npm` is replaced with a
small shim pointing at `npm-cli.js` so the executable name survives upstream layout changes. Nothing
relinks `corepack`, so the image provides no Corepack-managed `yarn` or `pnpm`. The layer then upgrades npm
past the LTS-bundled version to its latest release with `npm install -g npm` into `/usr/local`.

## Global packages

The image globally installs the latest published versions of the following, with no version pins and no
compatibility check between them beyond the image build succeeding:

* `@playwright/test`, `playwright`
* `esbuild`, `typescript`
* `purs-tidy`, `spago`

That set is the minimal toolchain every project needs to build, type-check,
and run browser tests.

## Cache and global prefix

* Cache: `NPM_CONFIG_CACHE=/opt/cache/npm`
* Global prefix: `NPM_CONFIG_PREFIX=/opt/build/node/global`; global packages land under
  `/opt/build/node/global/lib/node_modules`, and their executables in `/opt/build/node/global/bin`, which
  is on `PATH`.
