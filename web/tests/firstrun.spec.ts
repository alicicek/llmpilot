import { test, expect, type Page } from "@playwright/test";
import { walkBenefits, walkProblem, walkToPrice } from "./flow.ts";

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

test("the problem is taught first, then accounts, then the ask; the add fills a real gauge", async ({
  page,
}) => {
  await mockDaemon(page, { detected: oneDetected });
  await page.goto("/?pro=paywall");

  // ① the wall — before anything is asked for. No paywall, no toolbar, and
  // no exit: the corridor only opens at the price.
  await expect(page.getByRole("heading", { name: /You know this moment/ })).toBeVisible();
  await expect(page.getByRole("button", { name: "Fresh window" })).toBeHidden();
  await expect(page.getByTestId("paywall-close")).toBeHidden();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();
  await page.getByRole("button", { name: "Continue" }).click();

  // ② with a single identity the screen tells the glance story and never
  // implies a second account exists.
  await expect(page.getByTestId("edu-blind-solo")).toBeVisible();
  await expect(page.getByText(/accounts are signed in on this Mac/)).toBeHidden();
  await page.getByRole("button", { name: "Continue" }).click();

  // ③ accounts — with one detected, adding is the only forward path.
  await expect(page.getByRole("heading", { name: /Let's find yours/ })).toBeVisible();
  await expect(page.getByText("real-adopted@example.dev")).toBeVisible();
  await expect(page.getByRole("button", { name: "I'll sign in later" })).toBeHidden();

  // Add → the daemon state gains the account → the row's gauge fills to the
  // REAL percentage (first sight of their own data).
  await page.getByRole("button", { name: "Add account" }).click();
  await expect(page.getByText("42%")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();

  // ④ one genuine account cannot show a switch — it says so.
  await expect(page.getByRole("heading", { name: /It moves you/ })).toBeVisible();
  await expect(page.getByText(/on a demo fleet/)).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  // ⑤ then the scheduled window.
  await expect(page.getByTestId("edu-windows-board")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();

  // ⑥⑦⑧ the ask comes last, and only ⑧ states a price.
  await walkToPrice(page);
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
  await walkProblem(page);

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
  await expect(page.getByRole("heading", { name: /It moves you/ })).toBeVisible();
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
  // tour=false on a failed license fetch, so the education screens are
  // absent and the accounts screen is the whole flow.
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Let's find yours/ })).toBeVisible();
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
  await walkProblem(page);
  await expect(page.getByRole("button", { name: "I'll sign in later" })).toBeHidden();
  await page.getByRole("button", { name: "Add account" }).click();
  await expect(page.getByText(/keychain denied/i)).toBeVisible();
  await page.getByRole("button", { name: "I'll sign in later" }).click();
  await expect(page.getByRole("heading", { name: /It moves you/ })).toBeVisible();
});

test("quote_stale restarts the ask with the NEW terms and the remedy line", async ({
  page,
}) => {
  // The one path where two different non-null quotes flow through the
  // paywall: the worker refuses drifted terms (409 quote_stale), the app
  // re-quotes, and the buyer must walk the NEW terms rather than sit on a
  // commit screen quoting the old ones. Under SPEC-127 that means the ask
  // restarts at ⑥ and the price is re-stated on ⑧.
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
  await walkProblem(page);
  await walkBenefits(page);
  await walkToPrice(page);
  await expect(page.getByText("£9.99").first()).toBeVisible();
  await page.getByTestId("checkout-start").click();

  // The refusal restarts the ask at ⑥: the receipt is back on screen and the
  // commit screen is gone, so nothing can be bought under the old terms.
  await expect(page.getByTestId("receipt-table")).toBeVisible();
  await expect(page.getByTestId("checkout-start")).toBeHidden();

  // Walking forward again states the RELOADED price, with the remedy beside
  // the button that was pressed.
  await walkToPrice(page);
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();
  await expect(page.getByText("£10.99").first()).toBeVisible();
  await expect(page.getByTestId("checkout-error")).toContainText(/terms changed/i);
});

test("a licence that answers after the flow opens still gets the full ladder", async ({ page }) => {
  // An empty fleet mounts the flow as soon as /v1/state lands, which can be
  // BEFORE /v1/license answers — so `tour` is false on a perfectly normal
  // unlicensed build. Freezing that reduced the ladder to the accounts step
  // alone, and once the licence arrived showOnboarding held the flow open
  // while its only forward control called onExit: stuck on accounts forever.
  await mockDaemon(page, { detected: oneDetected });
  await page.route("**/v1/license/quote", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        trial_days: 4,
        charge_date: "2026-08-08T00:00:00Z",
        prices: { full: { gbp: 999 }, discount: { gbp: 599 } },
      }),
    }),
  );
  await page.route("**/v1/license", async (route) => {
    await new Promise((r) => setTimeout(r, 700));
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: '{"available":true,"active":false,"status":"none","nocard_trial_used":false}',
    });
  });

  await page.goto("/");
  // The late licence must open the ladder, not strand the accounts screen.
  await expect(page.getByRole("heading", { name: /You know this moment/ })).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId(/^edu-blind-/)).toBeVisible();
});

test("one identity spelled two ways is one account, not two", async ({ page }) => {
  // The fleet and .claude.json can disagree on casing. A case-sensitive
  // dedupe counted them separately, so ② announced a second account that
  // does not exist — and offered the headroom to match.
  await mockDaemon(page, {
    detected: [
      { config_dir: "/Users/x/.claude-alt", email: "REAL-Adopted@Example.dev", registered: false },
    ],
  });
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
  await page.goto("/?pro=paywall");
  await page.getByRole("button", { name: "Continue" }).click();

  // adoptedState holds real-adopted@example.dev; detection returns the same
  // person in different case. One identity → the solo story, no invented
  // second account.
  await expect(page.getByTestId("edu-blind-solo")).toBeVisible();
  await expect(page.getByText(/accounts are signed in on this Mac/)).toBeHidden();
});

test("declining before the reminder is answered lands on the question, not a dead money button", async ({
  page,
}) => {
  // The paywall reopened from the banner is NOT a guided run, so ⑥ and ⑦
  // carry a ✕ — and pressing it decline-ladders past the reminder question.
  // Landing on the lower offer with no answer rendered an ENABLED checkout
  // button that did nothing, and the route back to the question was replaced
  // by "No thanks": the decline path was unbuyable. (Only reachable with a
  // real license fetch — the ?pro= fixture always forces the guided flow.)
  await mockDaemon(page, { detected: [] });
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
      body: JSON.stringify({
        trial_days: 4,
        charge_date: "2026-08-08T00:00:00Z",
        prices: { full: { gbp: 999 }, discount: { gbp: 599 } },
      }),
    }),
  );
  await page.route("**/v1/license", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: '{"available":true,"active":false,"status":"none","nocard_trial_used":false}',
    }),
  );
  // Already onboarded → the guided flow is done; this is the banner path.
  await page.addInitScript(() => localStorage.setItem("llmpilot.pro.onboarded", "yes"));

  await page.goto("/");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByTestId("receipt-table")).toBeVisible();

  // ✕ = decline. It must ask the skipped question rather than jump to a
  // price screen whose button cannot fire.
  await page.getByTestId("paywall-close").click();
  await expect(page.getByTestId("remind-headline")).toBeVisible();
  await page.getByRole("button", { name: "1 day before" }).click();
  await page.getByTestId("remind-continue").click();

  // The decline is still honoured: the lower price, with a live button.
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await expect(page.getByTestId("checkout-start")).toBeEnabled();
});

test("a trial too short to offer a reminder choice never locks the flow", async ({ page }) => {
  // trial_days is server-controlled. At 1 day the offsets list [2,1] filtered
  // to "< days" is EMPTY, so the reminder screen would have no chips, its
  // Continue would stay disabled forever, and the guided flow gives it no ✕
  // — an unescapable screen behind a suppressed toolbar.
  await mockDaemon(page, { detected: [] });
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
      body: JSON.stringify({
        trial_days: 1,
        charge_date: "2026-08-06T00:00:00Z",
        prices: { full: { gbp: 999 }, discount: { gbp: 599 } },
      }),
    }),
  );
  await page.route("**/v1/license", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: '{"available":true,"active":false,"status":"none","nocard_trial_used":false}',
    }),
  );

  await page.goto("/");
  await walkProblem(page);
  await walkBenefits(page);
  // The unanswerable question is skipped entirely: the receipt goes straight
  // to a price screen with a working button.
  await expect(page.getByTestId("receipt-table")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId("checkout-start")).toBeEnabled();
  await expect(page.getByTestId("remind-continue")).toBeHidden();
});

test("no accounts detected: the empty state offers skip → the wall on the demo fleet → no dead-end", async ({
  page,
}) => {
  await mockDaemon(page, { detected: [] });
  await page.goto("/?pro=paywall");
  await walkProblem(page);

  // Empty accounts screen with a forward path.
  await expect(page.getByRole("heading", { name: /Let's find yours/ })).toBeVisible();
  await expect(page.getByText(/No signed-in Claude accounts found/i)).toBeVisible();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();

  // Sign-in-later → the switch demo runs on the demo fleet.
  await page.getByRole("button", { name: "I'll sign in later" }).click();
  await expect(page.getByRole("heading", { name: /It moves you/ })).toBeVisible();
  await expect(page.getByText(/on a demo fleet/)).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByRole("button", { name: "Continue" }).click();

  // The ask last; dismissing a skipped run (✕ through the decline offer)
  // lands on the working board (its honest empty state), not back on the
  // accounts screen — no re-trap and no lost skip.
  await walkToPrice(page);
  await expect(page.getByText(/charged once/i).first()).toBeVisible();
  await page.getByTestId("paywall-close").click();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByText(/charged once/i).first()).toBeHidden();
  await expect(page.getByRole("heading", { name: /Let's find yours/ })).toBeHidden();
  await expect(page.getByText(/nothing here is scheduled/i)).toBeVisible();
});
