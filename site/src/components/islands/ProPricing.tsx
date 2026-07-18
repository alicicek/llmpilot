import * as React from "react";

/*
 * Pro pricing rendered from the same server quote the in-app paywall binds to
 * (GET /v1/quote) — the number on the site can never drift from the number
 * charged. While a launch window is open the quote carries launch.ends_at +
 * regular_full and the banner states the real end date; no quote (JS off,
 * fetch failed, no window) falls back to the regular price, never to an
 * urgency claim the server didn't make.
 */

const QUOTE_URL = "https://api.llmpilot.dev/v1/quote";

interface Quote {
  prices?: { full?: Record<string, number> };
  launch?: { ends_at?: string; regular_full?: Record<string, number> };
}

const REGULAR_FALLBACK: Record<string, number> = { gbp: 999, usd: 1299 };

function money(currency: string, minor: number): string {
  return new Intl.NumberFormat("en", {
    style: "currency",
    currency: currency.toUpperCase(),
  }).format(minor / 100);
}

function pair(amounts: Record<string, number>): string {
  const gbp = amounts.gbp != null ? money("gbp", amounts.gbp) : null;
  const usd = amounts.usd != null ? money("usd", amounts.usd) : null;
  return [gbp, usd].filter(Boolean).join(" / ");
}

export default function ProPricing() {
  const [quote, setQuote] = React.useState<Quote | null>(null);

  React.useEffect(() => {
    let alive = true;
    fetch(QUOTE_URL)
      .then((r) => (r.ok ? r.json() : null))
      .then((q) => {
        if (alive && q) setQuote(q as Quote);
      })
      .catch(() => {
        /* quiet — the static regular price is already honest */
      });
    return () => {
      alive = false;
    };
  }, []);

  const full = quote?.prices?.full ?? REGULAR_FALLBACK;
  const launch = quote?.launch;
  const endsAt = launch?.ends_at ? new Date(launch.ends_at) : null;
  const launchOn = Boolean(
    endsAt && !Number.isNaN(endsAt.getTime()) && launch?.regular_full,
  );

  return (
    <div>
      <p
        className="m-0 text-[28px] font-bold text-text"
        style={{ fontVariantNumeric: "tabular-nums" }}
      >
        {pair(full)}{" "}
        <span className="text-[15px] font-semibold text-sec">one-time</span>
      </p>
      {launchOn && endsAt && (
        <p
          className="mt-3 inline-flex items-center gap-2.5 rounded-md border border-hair bg-panel px-3.5 py-2 text-[13.5px] text-text"
          title={endsAt.toISOString()}
        >
          <span
            aria-hidden="true"
            className="h-2 w-2 rounded-full bg-amber"
          />
          Launch price until{" "}
          {new Intl.DateTimeFormat("en", {
            day: "numeric",
            month: "short",
            hour: "2-digit",
            minute: "2-digit",
            hour12: false,
            timeZone: "UTC",
          }).format(endsAt)}
          {" UTC — then "}
          {pair(launch!.regular_full!)}.
        </p>
      )}
    </div>
  );
}
