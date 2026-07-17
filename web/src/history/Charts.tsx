import { useEffect, useMemo, useState } from "react";
import type { State, Config } from "../api.ts";
import { fetchConfig } from "../api.ts";
import {
  fetchAnalytics,
  fetchHistory,
  fixtureAnalytics,
  fixtureBurnSamples,
  type Analytics,
  type HistorySample,
} from "./analytics.ts";
import { useIsDark } from "./colors.ts";
import { addDays, dateOnly, rangeLabel, RANGE_DAYS, type Range } from "./format.ts";
import { FiltersRow } from "./Filters.tsx";
import { QuietState } from "./ChartKit.tsx";
import { BurnRateCard } from "./BurnRate.tsx";
import { ModelMixCard } from "./ModelMix.tsx";
import { ProjectsCard } from "./Projects.tsx";
import { RhythmCard } from "./Rhythm.tsx";
import { ValueCard } from "./Value.tsx";
import { DelightFooter } from "./Delight.tsx";
import { TableView } from "./TableView.tsx";

const UNAVAILABLE = "History unavailable — daemon too old or still indexing.";

// Orchestrator for the History section — dataviz spec: form first, color
// last (already validated, see colors.ts), one filter row above everything
// it scopes, every fetch failure a designed quiet state, never a crash or a
// spinner forever.
export default function Charts(props: { state: State; fixturesMode: boolean }) {
  const { state, fixturesMode } = props;
  const dark = useIsDark();

  const [range, setRange] = useState<Range>("7d");
  const [customSelected, setCustomSelected] = useState<Set<string> | null>(null);

  const [analytics, setAnalytics] = useState<Analytics | null>(null);
  const [analyticsError, setAnalyticsError] = useState<string | null>(null);
  const [analyticsLoading, setAnalyticsLoading] = useState(false);

  const [burnSamples, setBurnSamples] = useState<HistorySample[] | null>(null);
  const [burnError, setBurnError] = useState<string | null>(null);
  const [burnLoading, setBurnLoading] = useState(false);

  const [config, setConfig] = useState<Config | null>(null);

  // Analytics: fixtures are static; live re-fetches on mount + range change.
  useEffect(() => {
    if (fixturesMode) {
      setAnalytics(fixtureAnalytics);
      setAnalyticsError(null);
      return;
    }
    let cancelled = false;
    setAnalyticsLoading(true);
    fetchAnalytics(RANGE_DAYS[range])
      .then((a) => {
        if (cancelled) return;
        setAnalytics(a);
        setAnalyticsError(null);
      })
      .catch(() => {
        if (!cancelled) setAnalyticsError(UNAVAILABLE);
      })
      .finally(() => {
        if (!cancelled) setAnalyticsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [range, fixturesMode]);

  // Burn samples: same lifecycle (mount + filter change), always the active
  // account's current session bucket regardless of the account multi-select.
  useEffect(() => {
    if (fixturesMode) {
      setBurnSamples(fixtureBurnSamples);
      setBurnError(null);
      return;
    }
    let cancelled = false;
    setBurnLoading(true);
    fetchHistory(state.active_id, "session")
      .then((s) => {
        if (cancelled) return;
        setBurnSamples(s);
        setBurnError(null);
      })
      .catch(() => {
        if (!cancelled) setBurnError(UNAVAILABLE);
      })
      .finally(() => {
        if (!cancelled) setBurnLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [range, fixturesMode, state.active_id]);

  useEffect(() => {
    if (fixturesMode) return;
    let cancelled = false;
    fetchConfig()
      .then((c) => {
        if (!cancelled) setConfig(c);
      })
      .catch(() => {
        /* the value card falls back to $0 plan cost, honestly, when unreachable */
      });
    return () => {
      cancelled = true;
    };
  }, [fixturesMode]);

  const hasShared = useMemo(() => (analytics?.cells ?? []).some((c) => c.account_id === ""), [analytics]);
  const accountOptions = useMemo(() => {
    const opts = state.accounts.map((a) => ({ id: a.id, label: a.label || a.email }));
    return hasShared ? [...opts, { id: "", label: "shared" }] : opts;
  }, [state.accounts, hasShared]);

  const selected = customSelected ?? new Set(accountOptions.map((o) => o.id));
  const toggle = (id: string) =>
    setCustomSelected((prev) => {
      const base = prev ?? new Set(accountOptions.map((o) => o.id));
      const next = new Set(base);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const selectAll = () => setCustomSelected(null);

  const todayStr = dateOnly(state.as_of);
  const cutoff = addDays(todayStr, -(RANGE_DAYS[range] - 1));
  const filteredCells = useMemo(() => {
    if (!analytics) return [];
    return analytics.cells.filter((c) => c.day >= cutoff && c.day <= todayStr && selected.has(c.account_id));
  }, [analytics, cutoff, todayStr, selected]);

  const accountsCaption =
    selected.size === 0
      ? "no accounts"
      : selected.size === accountOptions.length
        ? "all accounts"
        : `${selected.size} of ${accountOptions.length} accounts`;

  return (
    <div>
      <FiltersRow
        range={range}
        onRangeChange={setRange}
        accountOptions={accountOptions}
        selected={selected}
        onToggle={toggle}
        onSelectAll={selectAll}
      />
      <p className="px-4 pt-1.5 pb-1 text-[10.5px] text-ter">
        {rangeLabel(range)} · {accountsCaption}
      </p>

      {!analytics && !analyticsError && !fixturesMode ? (
        <p className="px-4 pb-4 text-[11px] text-ter">Loading history…</p>
      ) : analyticsError ? (
        <div className="p-4">
          <QuietState message={analyticsError} wide />
        </div>
      ) : (
        <>
          <div
            className={`grid grid-cols-1 gap-3 p-4 transition-opacity duration-150 sm:grid-cols-2 ${
              analyticsLoading ? "opacity-60" : ""
            }`}
          >
            <BurnRateCard
              state={state}
              analytics={analytics}
              samples={burnSamples}
              loading={burnLoading}
              error={burnError}
            />
            <ModelMixCard cells={filteredCells} dark={dark} />
            <ProjectsCard cells={filteredCells} />
            <RhythmCard hourWeekday={analytics?.hour_weekday ?? []} dark={dark} />
            <ValueCard
              cells={filteredCells}
              range={range}
              fixturesMode={fixturesMode}
              config={config}
              selectedAccountIds={[...selected].filter((id) => id !== "")}
            />
          </div>
          <DelightFooter cells={filteredCells} range={range} />
          <TableView cells={filteredCells} />
        </>
      )}
    </div>
  );
}
