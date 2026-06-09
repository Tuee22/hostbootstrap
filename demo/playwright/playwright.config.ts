import { defineConfig } from "@playwright/test";

// The e2e target is the webservice `demo web serve` runs (the incus host in a
// real demo run; localhost here). Override with BASE_URL.
export default defineConfig({
  testDir: "./tests",
  reporter: "list",
  use: {
    baseURL: process.env.BASE_URL || "http://localhost:8080",
  },
});
