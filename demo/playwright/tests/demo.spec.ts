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
