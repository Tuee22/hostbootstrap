import { test, expect } from "@playwright/test";

// The headline e2e (Sprint 13.6): the Halogen SPA (built from the
// purescript-bridge types) renders its tabs, and the budget view it fetches
// from the warp/wai API reports that the demo's pods fit the budget.

test("the SPA renders all three tabs", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "hostbootstrap-demo" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Overview" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Budget" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Status" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Accelerator" })).toBeVisible();
});

test("the Budget tab shows the fitsBudget verdict", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Budget" }).click();
  await expect(page.locator("#fits")).toHaveText("fits: true");
});

test("GET /api/budget returns the fitsBudget view", async ({ request }) => {
  const res = await request.get("/api/budget");
  expect(res.ok()).toBeTruthy();
  const body = await res.json();
  expect(body.fits).toBe(true);
  expect(body.cpu).toBe(6);
});

// The accelerator Add e2e (Sprint 13.17 / 18.5): polymorphic on
// EXPECTED_ACCELERATOR_BACKEND, which `assertE2EInVM` sets to the substrate's
// backend name ONLY after it has polled the ingress and confirmed a daemon is
// serving. When set, the UI result must come from the real JIT-built worker —
// the exact `Float` sum, the daemon's backend identity, and a non-empty artifact
// hash — so a fake in-process fallback cannot pass. When unset (no daemon lane,
// e.g. windows-cpu, or a plain code-check render), the web server must NOT
// compute in process: it reports the no-fallback "unavailable" state.
test("the Accelerator tab computes via the daemon (or reports no in-process fallback)", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Accelerator" }).click();
  await page.locator("#add-left").fill("1.5");
  await page.locator("#add-right").fill("2.25");
  await page.locator("#add-button").click();
  const expectedBackend = process.env.EXPECTED_ACCELERATOR_BACKEND;
  if (expectedBackend) {
    // A daemon is connected: 1.5 + 2.25 must come back from the built worker.
    await expect(page.locator("#add-result")).toHaveText("3.75");
    await expect(page.locator("#add-backend")).toHaveText(expectedBackend);
    await expect(page.locator("#add-artifact")).toHaveText(/^[0-9a-f]{16}$/);
    // The whole API/worker chain is Float32: 2^24 + 1 rounds back to 2^24.
    await page.locator("#add-left").fill("16777216");
    await page.locator("#add-right").fill("1");
    await page.locator("#add-button").click();
    await expect(page.locator("#add-result")).toHaveText("16777216");
  } else {
    // No daemon: no in-process fallback — the endpoint reports unavailable.
    await expect(page.locator("#add-error")).toHaveText("accelerator daemon unavailable");
    await expect(page.locator("#add-backend")).toHaveText("unavailable");
  }
});

// The polymorphic e2e (Sprint 20.4): the SPA's #message element renders the
// config-driven message the harness's active variant deployed. EXPECTED_MESSAGE is
// passed per-variant by `assertE2EInVM`, so the same spec proves both variants
// ("Hello, world!" and "Hello, Universe!") really are config-driven end to end.
test("the SPA renders the config-driven message", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#message")).toHaveText(process.env.EXPECTED_MESSAGE!);
});
