import { test, expect, type Page } from "@playwright/test";

// adopt-first funnel order, both paths, against a route-mocked daemon
// (no ?fixtures= board — the funnel depends on state CHANGING after adopt,
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

async function mockDaemon(page: Page, opts: { detected: boolean }) {
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
      body: JSON.stringify(
        opts.detected
          ? [{ config_dir: "/Users/x/.claude", email: "real-adopted@example.dev", registered: false }]
          : [],
      ),
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

test("accounts detected: adopt renders before any paywall, pitch runs on the real fleet, paywall last", async ({
  page,
}) => {
  await mockDaemon(page, { detected: true });
  await page.goto("/?pro=paywall");

  // Adopt FIRST — no onboarding pitch, no paywall on screen.
  await expect(page.getByRole("heading", { name: "Adopt your accounts" })).toBeVisible();
  await expect(page.getByText("real-adopted@example.dev")).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Never hit a wall mid-thought" }),
  ).toBeHidden();
  await expect(page.getByText(/charged once/i)).toBeHidden();

  // Adopt → the daemon state gains the account → the pitch runs on it.
  await page.getByRole("button", { name: "Adopt account" }).click();
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await page.getByRole("button", { name: "Show me the autopilot" }).click();
  // The REAL adopted fleet, not the demo fixtures.
  await expect(page.getByText("real-adopted@example.dev")).toBeVisible();
  await expect(page.getByText("alex@example.dev")).toBeHidden();

  // Paywall comes last.
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText(/charged once/i)).toBeVisible();

  // Dismiss → the free tools keep working (board, not a dead end).
  await page.getByRole("button", { name: "Keep using the free tools for now" }).click();
  await expect(page.getByText(/charged once/i)).toBeHidden();
  await expect(page.getByText("real-adopted@example.dev")).toBeVisible();
});

test("no accounts detected: the empty state offers skip → pitch on the demo fleet → no dead-end", async ({
  page,
}) => {
  await mockDaemon(page, { detected: false });
  await page.goto("/?pro=paywall");

  // Empty adopt state with a forward path.
  await expect(page.getByRole("heading", { name: "Adopt your accounts" })).toBeVisible();
  await expect(page.getByText(/No signed-in Claude accounts found/i)).toBeVisible();
  await expect(page.getByText(/charged once/i)).toBeHidden();

  // Skip → the pitch runs on the demo fleet.
  await page.getByRole("button", { name: "Skip for now" }).click();
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await page.getByRole("button", { name: "Show me the autopilot" }).click();
  await expect(page.getByText("alex@example.dev")).toBeVisible();

  // Paywall last; dismissing a skipped-adoption run lands on the working
  // board (its honest empty state), not back on the adopt screen — the
  // "free tools" the dismissal promised, with no re-trap and no lost skip.
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText(/charged once/i)).toBeVisible();
  await page.getByRole("button", { name: "Keep using the free tools for now" }).click();
  await expect(page.getByText(/charged once/i)).toBeHidden();
  await expect(page.getByRole("heading", { name: "Adopt your accounts" })).toBeHidden();
  await expect(page.getByText(/nothing here is scheduled/i)).toBeVisible();
});
