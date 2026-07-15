import { defineConfig, devices } from "@playwright/test";

// The e2e target is the webservice `demo web serve` runs (the incus host in a
// real demo run; localhost here). Override with BASE_URL.
//
// The suite runs against all three browser engines the base image installs
// (`playwright install --with-deps chromium firefox webkit`), so every spec is
// exercised on Chromium, Firefox, and WebKit. The base image is the source of
// the browsers, so this needs no extra download at validation time.
export default defineConfig({
  testDir: "./tests",
  reporter: "list",
  // The demo intentionally has one accelerator daemon/worker session. Running
  // browser projects concurrently would turn their three Add requests into
  // artificial contention, so exercise the engines serially.
  workers: 1,
  use: {
    baseURL: process.env.BASE_URL || "http://localhost:8080",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
  ],
});
