import { test, expect, type Page } from "@playwright/test";

// P5: the doctor panel. It renders what `llmpilot doctor` prints — the same
// engine, served over GET /v1/doctor — and it repairs nothing itself. The
// rules under test: findings are ranked, every button maps to a verb the
// engine already accepts, a clean fleet earns an all-clear that names what was
// checked, and a check that could not run NEVER renders as passing.

const iso = "2026-07-26T10:00:00Z";

const state = {
  accounts: [
    {
      id: "fleet-1",
      label: "main",
      email: "main@example.dev",
      config_dir: "/Users/x/.claude",
      keychain_service: "Claude Code-credentials",
      pinned: false,
      snapshot: { account_id: "fleet-1", as_of: iso, buckets: [{ kind: "session", percent: 20 }] },
    },
  ],
  active_id: "fleet-1",
  events: [],
  stash: [],
  schedules: [],
  as_of: iso,
};

const checks = [
  { id: "daemon", title: "the daemon", state: "ok" },
  { id: "login_item", title: "the login item", state: "ok" },
  { id: "duplicate_accounts", title: "duplicate sign-ins", state: "finding" },
  { id: "shared_subscription", title: "shared subscriptions", state: "ok" },
  { id: "frozen_accounts", title: "frozen accounts", state: "finding" },
  { id: "watched_lanes", title: "watched lanes", state: "finding" },
];

const report = {
  as_of: iso,
  clean: false,
  problems: 2,
  findings: [
    {
      id: "duplicate_identity",
      check: "duplicate_accounts",
      severity: "critical",
      title: "main and work are the same Claude account",
      detail: "They are one sign-in (same sign-in email), so they share one set of limits.",
      accounts: ["main", "work"],
      remedy: { verb: "none", label: "Keep one lane — the other cannot add runway" },
    },
    {
      id: "account_frozen",
      check: "frozen_accounts",
      severity: "warning",
      title: "main is showing its last known numbers",
      detail: "Its stored sign-in expired while it sat idle.",
      accounts: ["main"],
      remedy: { verb: "switch", label: "Switch to it", target: "fleet-1", command: "llmpilot switch main" },
    },
    {
      id: "watched_lane",
      check: "watched_lanes",
      severity: "info",
      title: "alt is watched, not switchable",
      detail: "It signs in from its own folder, so llmpilot watches its limits.",
      accounts: ["alt"],
      remedy: {
        verb: "move_into_fleet",
        label: "Move into the fleet",
        target: "/Users/x/.claude-alt",
        command: "llmpilot open",
      },
    },
  ],
  checks,
};

async function mockDaemon(page: Page, doctor: unknown) {
  const switched: string[] = [];
  await page.route("**/v1/state", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(state) }),
  );
  await page.route("**/v1/events", (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/event-stream",
      body: `retry: 10000\nevent: state\ndata: ${JSON.stringify(state)}\n\n`,
    }),
  );
  await page.route("**/v1/doctor", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(doctor) }),
  );
  await page.route("**/v1/detect", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify([
        { config_dir: "/Users/x/.claude-alt", email: "alt@example.dev", registered: true, moved: false },
      ]),
    }),
  );
  await page.route("**/v1/switch", (route) => {
    switched.push((route.request().postDataJSON() as { account_id: string }).account_id);
    return route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
  });
  await page.route("**/v1/schedules", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "[]" }),
  );
  await page.route("**/v1/config", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
  );
  return switched;
}

test("findings are ranked, and every button is a verb the engine accepts", async ({ page }) => {
  const switched = await mockDaemon(page, report);
  await page.goto("/");

  const panel = page.getByRole("region", { name: "Fleet health" });
  await expect(panel).toBeVisible();
  await expect(panel.getByText("2 problems found")).toBeVisible();

  // Ranked: critical, then warning, then the note.
  const titles = await panel.locator("li span.truncate").allInnerTexts();
  expect(titles[0]).toContain("are the same Claude account");
  expect(titles[1]).toContain("last known numbers");
  expect(titles[2]).toContain("watched, not switchable");

  // A finding with nothing to press renders NO button — offering one the
  // engine would refuse is the failure this guard exists to prevent.
  const dup = panel.locator("li", { hasText: "are the same Claude account" });
  await expect(dup.getByRole("button")).toHaveCount(0);
  await expect(dup.getByText("Keep one lane")).toBeVisible();

  // The switch remedy calls the verb the engine accepts, with its target.
  const frozen = panel.locator("li", { hasText: "last known numbers" });
  await frozen.getByRole("button", { name: "Switch to it" }).click();
  await expect.poll(() => switched).toEqual(["fleet-1"]);

  // The migration remedy opens the dialog that owns that verb — and the verb
  // is really there, on the folder the finding named.
  const watched = panel.locator("li", { hasText: "watched, not switchable" });
  await watched.getByRole("button", { name: "Move into the fleet" }).click();
  const section = page.locator("section", { hasText: "Already signed in on this Mac" });
  await expect(section).toBeVisible();
  await expect(
    section.locator("li", { hasText: "alt@example.dev" }).getByRole("button", { name: "Move into the fleet" }),
  ).toBeVisible();
});

test("a clean fleet earns an all-clear that names what was checked", async ({ page }) => {
  await mockDaemon(page, {
    as_of: iso,
    clean: true,
    problems: 0,
    findings: [],
    checks: checks.map((c) => ({ ...c, state: "ok" })),
  });
  await page.goto("/");

  const panel = page.getByRole("region", { name: "Fleet health" });
  await expect(panel.getByText(`No problems found — all ${checks.length} checks ran.`)).toBeVisible();
  await expect(panel.getByText("Not checked")).toHaveCount(0);

  // The all-clear can be audited: it names every check it ran.
  await panel.getByRole("button", { name: "What was checked" }).click();
  await expect(panel.getByText(/Checked:.*the daemon.*duplicate sign-ins/)).toBeVisible();
});

test("a check that could not run never renders as passing", async ({ page }) => {
  await mockDaemon(page, {
    as_of: iso,
    clean: false,
    problems: 0,
    findings: [],
    checks: [
      { id: "daemon", title: "the daemon", state: "ok" },
      {
        id: "shared_subscription",
        title: "shared subscriptions",
        state: "not_checked",
        why: "llmpilot has no organization id stored for alt, so it cannot tell whether they share a subscription",
      },
    ],
  });
  await page.goto("/");

  const panel = page.getByRole("region", { name: "Fleet health" });
  // Wait for the panel to RENDER before asserting an absence — it is null
  // until its fetch resolves, and a negative assertion would pass trivially.
  await expect(panel.getByText("No problems found, but 1 of 2 checks could not run")).toBeVisible();
  await expect(panel.getByText(/^No problems found — all/)).toHaveCount(0);
  // The blind spot is named, with its reason.
  await expect(panel.getByText("Not checked (1)")).toBeVisible();
  await expect(panel.getByText(/shared subscriptions — llmpilot has no organization id/)).toBeVisible();
});

test("a sweep that could not run says so instead of vanishing", async ({ page }) => {
  await mockDaemon(page, report);
  // A daemon older than this cockpit has no /v1/doctor. Hiding the panel would
  // read as "nothing to report" — a clean bill by omission.
  await page.unroute("**/v1/doctor");
  await page.route("**/v1/doctor", (route) => route.fulfill({ status: 404, body: "not found" }));
  await page.goto("/");

  const panel = page.getByRole("region", { name: "Fleet health" });
  await expect(panel.getByText("llmpilot could not check the fleet")).toBeVisible();
  await expect(panel.getByText(/nothing below is a clean bill of health/)).toBeVisible();
  await expect(panel.getByText(/^No problems found/)).toHaveCount(0);
});

test("a report with no checks at all is refused, not rendered", async ({ page }) => {
  await mockDaemon(page, report);
  // A document carrying no checks is not a health report — rendering it printed
  // "all 0 checks ran", which says nothing about the fleet while looking like
  // an answer.
  await page.unroute("**/v1/doctor");
  await page.route("**/v1/doctor", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ as_of: iso, clean: true, problems: 0, findings: [], checks: [] }),
    }),
  );
  await page.goto("/");

  const panel = page.getByRole("region", { name: "Fleet health" });
  await expect(panel.getByText("llmpilot could not check the fleet")).toBeVisible();
  await expect(panel.getByText(/without a single health check/)).toBeVisible();
  await expect(panel.getByText(/checks ran/)).toHaveCount(0);
});

test("a report that contradicts itself is called out, not counted", async ({ page }) => {
  await mockDaemon(page, report);
  // clean:false with nothing wrong and nothing unchecked can only come from a
  // daemon whose flag is wrong. Printing "0 of N checks could not run" would be
  // a number that means nothing; the terminal says this same sentence.
  await page.unroute("**/v1/doctor");
  await page.route("**/v1/doctor", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        as_of: iso,
        clean: false,
        problems: 0,
        findings: [],
        checks: checks.map((c) => ({ ...c, state: "ok" })),
      }),
    }),
  );
  await page.goto("/");
  const panel = page.getByRole("region", { name: "Fleet health" });
  await expect(panel.getByText("This report does not add up")).toBeVisible();
  await expect(panel.getByText(/0 of \d+ checks could not run/)).toHaveCount(0);
});

test("a clean flag over real problems is not an all-clear", async ({ page }) => {
  await mockDaemon(page, { ...report, clean: true });
  await page.goto("/");
  const panel = page.getByRole("region", { name: "Fleet health" });
  // The engine cannot emit this pair; a daemon whose flag is wrong can.
  await expect(panel.getByText("2 problems found")).toBeVisible();
  await expect(panel.getByText(/^No problems found/)).toHaveCount(0);
});

test("a clean flag over a blind spot is not an all-clear", async ({ page }) => {
  await mockDaemon(page, {
    ...report,
    clean: true,
    problems: 0,
    findings: [],
    checks: [
      { id: "daemon", title: "the daemon", state: "ok" },
      { id: "frozen_accounts", title: "frozen accounts", state: "not_checked", why: "the daemon is not running" },
    ],
  });
  await page.goto("/");
  const panel = page.getByRole("region", { name: "Fleet health" });
  // The positive first: the panel is null until its fetch resolves, so an
  // absence assertion on its own would pass before anything rendered.
  await expect(panel.getByText("Not checked (1)")).toBeVisible();
  // Only a daemon whose flag is wrong produces this pair — the panel must not
  // print a clean bill directly above a blind spot it is also rendering.
  await expect(panel.getByText(/^No problems found — all/)).toHaveCount(0);
});

