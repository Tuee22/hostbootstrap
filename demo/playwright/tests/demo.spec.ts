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

test("the Accelerator tab has controls and no in-process fallback", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Accelerator" }).click();
  await page.locator("#add-left").fill("1.5");
  await page.locator("#add-right").fill("2.25");
  await page.locator("#add-button").click();
  await expect(page.locator("#add-error")).toHaveText("accelerator daemon unavailable");
  await expect(page.locator("#add-backend")).toHaveText("unavailable");
});

// The polymorphic e2e (Sprint 20.4): the SPA's #message element renders the
// config-driven message the harness's active variant deployed. EXPECTED_MESSAGE is
// passed per-variant by `assertE2EInVM`, so the same spec proves both variants
// ("Hello, world!" and "Hello, Universe!") really are config-driven end to end.
test("the SPA renders the config-driven message", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#message")).toHaveText(process.env.EXPECTED_MESSAGE!);
});
