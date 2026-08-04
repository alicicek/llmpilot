import { defineConfig } from "@playwright/test";

// The E2E happy path runs against a REAL sandboxed daemon (embedded UI, fake
// accounts, throwaway keychain) started by scripts/e2e-cockpit.sh, which
// exports E2E_BASE_URL before invoking `pnpm exec playwright test`.
export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  retries: 0,
  workers: 1, // one shared daemon; mutations must not race
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:0",
    viewport: { width: 1440, height: 1000 },
    // Every fresh context looks like a first-time user, so the guided tour
    // would open over each spec's board and swallow its clicks. Specs that
    // are not about the tour start as someone who has already seen it;
    // tour.spec.ts clears this to exercise the real first-run behavior.
    storageState: {
      cookies: [],
      origins: [
        {
          origin: process.env.E2E_BASE_URL ?? "http://127.0.0.1:0",
          localStorage: [{ name: "llmpilot.tour.seen", value: "yes" }],
        },
      ],
    },
  },
  reporter: [["list"]],
});
