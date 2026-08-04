import { test, expect, type Page } from "@playwright/test";

// add-first funnel order, both paths, against a route-mocked daemon
// (no ?fixtures= board — the funnel depends on state CHANGING after an add,
// which the static fixture harness cannot do). The license still comes from
// the ?pro=paywall fixture. SSE is mocked as one-frame streams with a short
// retry, so each reconnect delivers the current mock state.

const iso = "2026-07-22T14:32:00Z";

const emptyState = {
  accounts: [],
  active_id: "",
  events: [],
  as_of: iso,
  schedules: [],
};

const adoptedState = {
  accounts: [
    {
      id: "real-1",
      label: "real",
      email: "real-adopted@example.dev",
      config_dir: "/Users/x/.claude",
      keychain_service: "Claude Code-credentials",
      pinned: false,
      snapshot: {
        account_id: "real-1",
        as_of: iso,
        buckets: [{ kind: "session", percent: 42 }],
      },
    },
  ],
  active_id: "real-1",
  events: [],
  as_of: iso,
  schedules: [],
};

async function mockDaemon(
  page: Page,
  opts: { detected: { config_dir: string; email: string; registered: boolean }[] },
) {
  const st = { adopted: false };
  await page.route("**/v1/state", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(st.adopted ? adoptedState : emptyState),
    }),
  );
  await page.route("**/v1/events", (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/event-stream",
      body: `retry: 150\nevent: state\ndata: ${JSON.stringify(
        st.adopted ? adoptedState : emptyState,
      )}\n\n`,
    }),
  );
  await page.route("**/v1/detect", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(opts.detected),
    }),
  );
  await page.route("**/v1/adopt", (route) => {
    st.adopted = true;
    return route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
  });
  await page.route("**/v1/schedules", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "[]" }),
  );
  await page.route("**/v1/config", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
  );
  return st;
}

const oneDetected = [
  { config_dir: "/Users/x/.claude", email: "real-adopted@example.dev", registered: false },
];

test("account detected: the accounts screen renders before any paywall, the add fills a real gauge, the pitch follows", async ({
  page,
}) => {
  await mockDaemon(page, { detected: oneDetected });
  await page.goto("/?pro=paywall");

  // Accounts FIRST — no pitch, no paywall on screen, no toolbar (one path),
  // and no skip: with an account detected, adding is the only forward path.
  await expect(page.getByRole("heading", { name: "Your accounts" })).toBeVisible();
  await expect(page.getByText("real-adopted@example.dev")).toBeVisible();
  await expect(page.getByRole("button", { name: "I'll sign in later" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Fresh window" })).toBeHidden();
  await expect(
    page.getByRole("heading", { name: "Never hit a wall mid-thought" }),
  ).toBeHidden();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();

  // Add → the daemon state gains the account → the row's gauge fills to the
  // REAL percentage (first sight of their own data), the CTA becomes the
  // way forward.
  await page.getByRole("button", { name: "Add account" }).click();
  await expect(page.getByText("42%")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();

  // One genuine account cannot show a switch — the wall says it runs on a
  // demo fleet.
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await expect(page.getByText(/a preview on a demo fleet/)).toBeVisible();

  // Paywall comes last.
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText(/charged once/i).first()).toBeVisible();

  // ✕ once → the decline offer; ✕ again → the free tools keep working
  // (board, not a dead end).
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();
  await expect(page.getByText("real-adopted@example.dev")).toBeVisible();
});

test("duplicate folders collapse into one identity row; a separate account is named as the switch target", async ({
  page,
}) => {
  await mockDaemon(page, {
    detected: [
      { config_dir: "/Users/x/.claude", email: "same@example.dev", registered: false },
      { config_dir: "/Users/x/.claude-alt", email: "same@example.dev", registered: false },
      { config_dir: "/Users/x/.claude-two", email: "other@example.dev", registered: false },
    ],
  });
  await page.goto("/?pro=paywall");

  // Two identities, not three lanes of fuel.
  await expect(page.getByText("same@example.dev")).toHaveCount(1);
  await expect(page.getByText(/2 folders · one shared limit — watching both adds no headroom/)).toBeVisible();
  await expect(
    page.getByText(/A second account — this is what the autopilot switches to/),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Add 2 accounts" })).toBeVisible();

  // Opting out of everything is a live, reversible choice — Continue stays
  // enabled (a disabled sole control with no toolbar was a dead end).
  const boxes = page.getByRole("checkbox");
  await boxes.nth(0).uncheck();
  await boxes.nth(1).uncheck();
  const cta = page.getByRole("button", { name: "Continue" });
  await expect(cta).toBeEnabled();
  await cta.click();
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
});

test("no license at all (source build / failed license fetch): the accounts screen still offers an exit", async ({
  page,
}) => {
  await mockDaemon(page, { detected: [] });
  // The F1-class repro: one failed GET /v1/license makes tour=false on an
  // otherwise healthy build. The flow must never depend on it for an exit.
  await page.route("**/v1/license*", (route) =>
    route.fulfill({ status: 500, contentType: "application/json", body: '{"error":"keychain read failed"}' }),
  );
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Your accounts" })).toBeVisible();
  const skip = page.getByRole("button", { name: "I'll sign in later" });
  await expect(skip).toBeVisible();
  await skip.click();
  // Exit lands on the working board (empty state) with the toolbar back.
  await expect(page.getByText(/nothing here is scheduled/i)).toBeVisible();
  await expect(page.getByRole("button", { name: "Fresh window" })).toBeVisible();
});

test("a failed add is not a dead end: the error shows and the sign-in-later path appears", async ({
  page,
}) => {
  await mockDaemon(page, { detected: oneDetected });
  // A denied Keychain prompt surfaces as an add error; the screen must
  // keep a forward path (regression rail on the fresh-install class).
  await page.unroute("**/v1/adopt");
  await page.route("**/v1/adopt", (route) =>
    route.fulfill({ status: 500, contentType: "application/json", body: '{"error":"keychain denied"}' }),
  );
  await page.goto("/?pro=paywall");
  await expect(page.getByRole("button", { name: "I'll sign in later" })).toBeHidden();
  await page.getByRole("button", { name: "Add account" }).click();
  await expect(page.getByText(/keychain denied/i)).toBeVisible();
  await page.getByRole("button", { name: "I'll sign in later" }).click();
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
});

test("quote_stale bounces the ask to the offer with the NEW terms and the remedy line", async ({
  page,
}) => {
  // The one path where two different non-null quotes flow through the
  // paywall: the worker refuses drifted terms (409 quote_stale), the app
  // re-quotes, and re-consent must happen on a screen that STATES the new
  // price — never on the reminder screen mid-flight.
  const quoteA = {
    trial_days: 4,
    charge_date: "2026-08-08T00:00:00Z",
    prices: { full: { gbp: 999 }, discount: { gbp: 599 } },
  };
  const quoteB = { ...quoteA, prices: { full: { gbp: 1099 }, discount: { gbp: 599 } } };
  const st = { refused: false };
  await mockDaemon(page, { detected: [] });
  // Non-empty fleet so the flow starts at the wall.
  await page.unroute("**/v1/state");
  await page.route("**/v1/state", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(adoptedState) }),
  );
  await page.unroute("**/v1/events");
  await page.route("**/v1/events", (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/event-stream",
      body: `retry: 10000\nevent: state\ndata: ${JSON.stringify(adoptedState)}\n\n`,
    }),
  );
  await page.route("**/v1/license/quote", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(st.refused ? quoteB : quoteA),
    }),
  );
  await page.route("**/v1/license/checkout", (route) => {
    st.refused = true;
    return route.fulfill({
      status: 409,
      contentType: "application/json",
      body: '{"error":"terms drifted","code":"quote_stale"}',
    });
  });
  await page.route("**/v1/license", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: '{"available":true,"active":false,"status":"none","nocard_trial_used":false}',
    }),
  );

  await page.goto("/");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText("£9.99").first()).toBeVisible();
  await page.getByRole("button", { name: "Try it free for 4 days" }).click();
  await expect(page.getByText("BEFORE ANYTHING IS CHARGED")).toBeVisible();
  await page.getByRole("button", { name: "Start the 4-day free trial" }).click();

  // Back on the offer, showing the RELOADED price beside the remedy.
  // (remind-headline is the unique marker — the offer's own timeline copy
  // contains "before anything is charged" too.)
  await expect(page.getByTestId("remind-headline")).toBeHidden();
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();
  await expect(page.getByText("£10.99").first()).toBeVisible();
  await expect(page.getByTestId("checkout-error")).toContainText(/terms changed/i);
});

test("no accounts detected: the empty state offers skip → the wall on the demo fleet → no dead-end", async ({
  page,
}) => {
  await mockDaemon(page, { detected: [] });
  await page.goto("/?pro=paywall");

  // Empty accounts screen with a forward path.
  await expect(page.getByRole("heading", { name: "Your accounts" })).toBeVisible();
  await expect(page.getByText(/No signed-in Claude accounts found/i)).toBeVisible();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();

  // Sign-in-later → the wall runs on the demo fleet.
  await page.getByRole("button", { name: "I'll sign in later" }).click();
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await expect(page.getByText(/a preview on a demo fleet/)).toBeVisible();

  // Paywall last; dismissing a skipped run (✕ through the decline offer)
  // lands on the working board (its honest empty state), not back on the
  // accounts screen — no re-trap and no lost skip.
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText(/charged once/i).first()).toBeVisible();
  await page.getByTestId("paywall-close").click();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();
  await expect(page.getByRole("heading", { name: "Your accounts" })).toBeHidden();
  await expect(page.getByText(/nothing here is scheduled/i)).toBeVisible();
});
