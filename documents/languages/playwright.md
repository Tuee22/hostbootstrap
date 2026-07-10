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

The npm packages are installed globally under `/opt/build/node/global`. A
project-local Playwright config or spec that imports `@playwright/test` without a
local `node_modules` tree runs with
`NODE_PATH=/opt/build/node/global/lib/node_modules` so Node resolves the
base-provided package.

`/root/.npm` is removed after install to keep the image lean.

The `hostbootstrap-demo` worked consumer (`demo/`) runs its end-to-end suite with
this Playwright runtime through the standardized test harness. The shared
`project up` stack brings up an isolated kind cluster, loads the already-built
`hostbootstrap-demo:local` project image into it, and deploys the web chart pod
(the pod's entrypoint is the demo binary, which runs `service run` — the
`Web` variant — to bind the warp/wai webservice on `:8080`), so the cluster's
NodePort serves before any case runs. The `e2e-tabs` case in the harness's case
matrix does not bring up its own stack; it only starts the same project image as
a one-off container with `--network host` (the VM host network). That container
sets `BASE_URL` to the NodePort the VM publishes on its own localhost
(`http://localhost:30080`), sets `NODE_PATH` to
`/opt/build/node/global/lib/node_modules` as above, and runs `playwright test`
from `/workspace/demo/playwright`. Its `playwright.config.ts` declares one project
per engine, so every spec runs on all three browsers the base image installs
(Chromium, Firefox, WebKit) with no extra download at validation time.

The current `e2e-tabs` spec also opens the Accelerator tab and asserts the Add
path reports `accelerator daemon unavailable` rather than a web-computed sum; the
real sum+metadata assertion remains the accelerator daemon integration gate.

The `e2e-tabs` spec is **polymorphic** across the suite's config variants. The
harness exports `EXPECTED_MESSAGE` per variant, and the spec reads that env var
rather than a hardcoded string: in addition to the tabs and `/api/budget`, it
asserts the SPA `#message` element matches whichever message the active deployment
set. So the demo's two variants (`"Hello, world!"` then `"Hello, Universe!"`) run
the same spec against whatever message each deployment carries — still on all three
browsers.

The demo e2e path resolves Playwright from the project image, which carries the
base image's global installation: it does not pull `mcr.microsoft.com/playwright:*`,
does not run `npm install`, and does not use `npx` during validation.
