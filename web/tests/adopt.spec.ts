import { test, expect, type Page } from "@playwright/test";

// P4: a multi-account user must never be stranded. With a NON-EMPTY fleet
// (the state that used to hide every remaining sign-in) the cockpit still
// surfaces the other Claude accounts on this Mac, offers the additive watch
// adopt and the destructive migration behind a two-step confirm, and stops
// offering a Switch verb the engine refuses on a pinned lane.

const iso = "2026-07-26T10:00:00Z";

function account(over: Record<string, unknown>) {
  return {
    id: "fleet-1",
    label: "main",
    email: "main@example.dev",
    config_dir: "/Users/x/.claude",
    keychain_service: "Claude Code-credentials",
    pinned: false,
    snapshot: {
      account_id: "fleet-1",
      as_of: iso,
      buckets: [{ kind: "session", percent: 20 }],
    },
    ...over,
  };
}

const state = {
  accounts: [
    account({}),
    account({
      id: "watched-1",
      label: "alt",
      email: "alt@example.dev",
      config_dir: "/Users/x/.claude-alt",
      pinned: true,
      snapshot: { account_id: "watched-1", as_of: iso, buckets: [{ kind: "session", percent: 5 }] },
    }),
  ],
  active_id: "fleet-1",
  events: [],
  stash: [],
  schedules: [],
  as_of: iso,
};

const detected = [
  // The watched account's own dir: registered (adopted as watched) but PINNED
  // — the product tells the user to move it into the fleet from here, so the
  // verb must be reachable.
  { config_dir: "/Users/x/.claude-alt", email: "alt@example.dev", registered: true, moved: false },
  { config_dir: "/Users/x/.claude-two", email: "two@example.dev", registered: false, moved: false },
  {
    config_dir: "/Users/x/.claude-three",
    email: "three@example.dev",
    registered: false,
    moved: false,
  },
  { config_dir: "/Users/x/.claude", email: "main@example.dev", registered: true, moved: false },
  // Signed back into after a move: registered (llmpilot knows the account),
  // moved:false (the daemon re-verified and the folder holds a sign-in
  // again). The cockpit must offer the verb that resolves it.
  { config_dir: "/Users/x/.claude-back", email: "back@example.dev", registered: true, moved: false },
];

async function mockDaemon(page: Page) {
  const calls: string[] = [];
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
  await page.route("**/v1/detect", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(detected) }),
  );
  await page.route("**/v1/adopt/move", (route) => {
    calls.push("move:" + (route.request().postDataJSON() as { config_dir: string }).config_dir);
    return route.fulfill({
      status: 201,
      contentType: "application/json",
      body: JSON.stringify({ account: { id: "moved" }, outcome: "complete", note: "" }),
    });
  });
  await page.route("**/v1/schedules", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "[]" }),
  );
  await page.route("**/v1/config", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
  );
  return calls;
}

test("a non-empty fleet still surfaces the other sign-ins, and the migration needs a second click", async ({
  page,
}) => {
  const calls = await mockDaemon(page);
  await page.goto("/");

  // The board is up (non-empty fleet) — the state that used to hide adopt.
  await expect(page.getByText("main@example.dev").first()).toBeVisible();

  // Discovery: the toolbar control carries the count of unregistered dirs.
  const addAccount = page.getByRole("button", { name: /Add account/ });
  await expect(addAccount).toContainText("2");

  await addAccount.click();

  // Both unregistered dirs are listed, above the sign-in buttons.
  const section = page.locator("section", { hasText: "Already signed in on this Mac" });
  await expect(section.getByText("two@example.dev")).toBeVisible();
  await expect(section.getByText("three@example.dev")).toBeVisible();
  // The fleet's OWN folder is the only one never listed.
  await expect(section.getByText("main@example.dev")).toHaveCount(0);
  // A folder signed back into after a move keeps the verb that resolves it —
  // without it the user is stranded while refreshes stay paused.
  const back = section.locator("li", { hasText: "back@example.dev" });
  await expect(back.getByRole("button", { name: "Move into the fleet" })).toBeVisible();
  await expect(back.getByRole("button", { name: "Add as watched" })).toHaveCount(0);
  // ...but a registered WATCHED (pinned) one keeps the migration verb, with
  // no second "add as watched" — that is the flow the board copy points at.
  const watched = section.locator("li", { hasText: "alt@example.dev" });
  await expect(watched.getByRole("button", { name: "Move into the fleet" })).toBeVisible();
  await expect(watched.getByRole("button", { name: "Add as watched" })).toHaveCount(0);

  const row = section.locator("li", { hasText: "two@example.dev" });
  await expect(row.getByRole("button", { name: "Add as watched" })).toBeVisible();

  // The destructive verb states its consequence BEFORE it runs, and one
  // click is not enough.
  const move = row.getByRole("button", { name: "Move into the fleet" });
  await move.click();
  await expect(row.getByText(/will need to sign in again/i)).toBeVisible();
  expect(calls).toEqual([]);

  await row.getByRole("button", { name: /confirm/i }).click();
  await expect.poll(() => calls).toEqual(["move:/Users/x/.claude-two"]);
});

test("a clone-suspect migration keeps saying so after the list refreshes", async ({ page }) => {
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
  await page.route("**/v1/schedules", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "[]" }),
  );
  await page.route("**/v1/config", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
  );
  // After the move the dir reports registered — the row drops out of the list.
  let moved = false;
  await page.route("**/v1/detect", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(
        moved
          ? [{ config_dir: "/Users/x/.claude-two", email: "two@example.dev", registered: true, moved: false }]
          : [{ config_dir: "/Users/x/.claude-two", email: "two@example.dev", registered: false, moved: false }],
      ),
    }),
  );
  await page.route("**/v1/adopt/move", (route) => {
    moved = true;
    return route.fulfill({
      status: 201,
      contentType: "application/json",
      body: JSON.stringify({
        account: { id: "moved" },
        outcome: "clone_suspect",
        note: "The sign-in is in the fleet, but a copy is still readable in /Users/x/.claude-two — llmpilot will not refresh this account until you sign in to it again.",
      }),
    });
  });

  await page.goto("/");
  await page.getByRole("button", { name: /Add account/ }).click();
  const row = page.locator("li", { hasText: "two@example.dev" });
  await row.getByRole("button", { name: "Move into the fleet" }).click();
  await row.getByRole("button", { name: /confirm/i }).click();

  // The outcome is stated honestly and stays stated. The row also REMAINS —
  // a clone-suspect move leaves a copy in that folder, so the verb that
  // resolves it must stay reachable (never "Add as watched", which would
  // register a second row for an account llmpilot already knows).
  await expect(page.getByText(/will not refresh this account/)).toBeVisible();
  const row2 = page.locator("li", { hasText: "two@example.dev" });
  await expect(row2.getByRole("button", { name: "Move into the fleet" })).toBeVisible();
  await expect(row2.getByRole("button", { name: "Add as watched" })).toHaveCount(0);
});

test("a pinned lane offers no Switch verb and says what the account is for", async ({ page }) => {
  await mockDaemon(page);
  await page.goto("/");

  // The pinned lane renders, and says what the account IS for — no blame,
  // and a pointer to the verb that makes it switchable.
  await expect(page.getByText("alt@example.dev")).toBeVisible();
  await expect(page.getByText(/Watched — signs in from its own folder/)).toBeVisible();
  await expect(page.getByText(/Move it into the fleet .* to make it switchable/)).toBeVisible();
  // The engine refuses a pinned target, so no surface may offer the verb.
  // The only other lane is the ACTIVE one, which never offers it either.
  await expect(page.getByRole("button", { name: /^switch to/i })).toHaveCount(0);
});
