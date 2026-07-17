import { useCallback, useEffect, useRef, useState } from "react";
import { fetchQuote, type Quote } from "../api.ts";
import { fixtureQuote, proFixtureParam } from "./fixtures.ts";

// The consent copy shows a charge date, and the date rolls daily while the
// binding echo carries only trial days and amount — so a quote is only
// honest while it is fresh. Past this age the paywall re-quotes instead of
// letting a cockpit that sat open overnight show yesterday's date.
const QUOTE_TTL_MS = 15 * 60 * 1000;

// The paywall's consent terms come from the worker quote (proxied by the
// daemon at GET /v1/license/quote). Prefetched the moment the app knows it is
// unlicensed so the onboarding ladder never stalls on the network. In ?pro=
// fixture mode the canned quote serves and nothing fetches.
export function useQuote(enabled: boolean): {
  quote: Quote | null;
  failed: boolean;
  reload: () => void;
} {
  const fixture = proFixtureParam !== null;
  const [quote, setQuote] = useState<Quote | null>(fixture ? fixtureQuote() : null);
  const [failed, setFailed] = useState(false);
  const inFlight = useRef(false);
  const fetchedAt = useRef(0);

  const reload = useCallback(() => {
    if (fixture || inFlight.current) return;
    inFlight.current = true;
    // Superseded terms must never stay clickable while the refetch runs:
    // no quote → the paywall disables its CTA and shows the loading state.
    setQuote(null);
    setFailed(false);
    fetchQuote()
      .then((q) => {
        fetchedAt.current = Date.now();
        setQuote(q);
      })
      .catch(() => setFailed(true))
      .finally(() => {
        inFlight.current = false;
      });
  }, [fixture]);

  useEffect(() => {
    if (!enabled || fixture) return;
    if (!quote && !failed) reload();
    // Re-quote when the current one ages out — also retries a failed fetch,
    // so a network blip self-heals without a reopen.
    const t = window.setInterval(() => {
      if (Date.now() - fetchedAt.current > QUOTE_TTL_MS) reload();
    }, 60_000);
    return () => window.clearInterval(t);
  }, [enabled, fixture, quote, failed, reload]);

  return { quote, failed, reload };
}
