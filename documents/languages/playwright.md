# Playwright

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md), [node.md](node.md)

> **Purpose**: Document the Playwright browsers and runtime the base image ships.

This page documents what the base image ships for Playwright.

The base image installs Playwright globally and runs
`playwright install --with-deps chromium firefox webkit`, so the three
browser engines plus their apt-side runtime dependencies are present in the
image.

Browsers live at `/ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`). Tests that
expect that path automatically pick them up.

`/root/.npm` is removed after install to keep the image lean.

The `hostbootstrap-demo` worked consumer (`demo/`) runs its end-to-end suite with
this Playwright runtime: `demo web serve` serves the webservice on the incus host
and the container-side Playwright run targets that host `baseURL` (the live e2e
run is exercised during the demo run).
