import { useEffect, useState } from "react";
import { fetchConfig, saveConfig, type Config, type License, type State } from "../api.ts";
import { ShellDialog } from "./dialog.tsx";
import { LicenseSection } from "../pro/LicenseSection.tsx";

export const HISTORY_PREF_KEY = "llmpilot.showHistory";

export function showHistoryPref(): boolean {
  return localStorage.getItem(HISTORY_PREF_KEY) !== "off";
}

function Row(props: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-hairsoft py-2.5 last:border-b-0">
      <div>
        <div className="text-[12px] font-semibold">{props.label}</div>
        {props.hint && <div className="mt-0.5 text-[10.5px] text-ter">{props.hint}</div>}
      </div>
      {props.children}
    </div>
  );
}

function Toggle(props: { on: boolean; onChange: (on: boolean) => void; label: string }) {
  return (
    <button
      role="switch"
      aria-checked={props.on}
      aria-label={props.label}
      onClick={() => props.onChange(!props.on)}
      className={`relative h-[20px] w-[34px] rounded-full transition-colors duration-150 ${
        props.on ? "bg-accent" : "bg-rail"
      }`}
    >
      <i
        className={`absolute top-[2px] h-[16px] w-[16px] rounded-full bg-white shadow transition-[left] duration-150 ${
          props.on ? "left-[16px]" : "left-[2px]"
        }`}
      />
    </button>
  );
}

// Settings: daemon behavior lives in config.json over /v1/config; pure
// display preferences (History visibility) stay local to this browser.
export function SettingsDialog(props: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  state: State | null;
  showHistory: boolean;
  onShowHistory: (on: boolean) => void;
  onOpenStatusline: () => void;
  license: License | null;
  onTurnOn: () => void;
  onReloadLicense: () => void;
  offline?: boolean;
}) {
  const [cfg, setCfg] = useState<Config | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!props.open || props.offline) return;
    fetchConfig()
      .then((c) => {
        setCfg(c);
        setErr(null);
      })
      .catch(() => setErr("Settings unreachable — daemon not running or too old."));
  }, [props.open, props.offline]);

  const patch = (fn: (c: Config) => Config) => {
    setCfg((prev) => {
      const next = fn(prev ?? {});
      saveConfig(next).catch(() =>
        setErr("Save failed — the daemon didn't take the change."),
      );
      return next;
    });
  };

  const notifOn = !(cfg?.notifications?.disabled ?? false);
  const thresholds = cfg?.notifications?.thresholds?.join(", ") ?? "75, 90";
  const autoOn = !(cfg?.autopilot?.disabled ?? false);

  return (
    <ShellDialog open={props.open} onOpenChange={props.onOpenChange} title="Settings">
      {err && (
        <p className="rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] text-warn">
          {err}
        </p>
      )}
      <div>
        <LicenseSection
          license={props.license}
          offline={props.offline}
          onTurnOn={() => {
            props.onOpenChange(false);
            props.onTurnOn();
          }}
          onReload={props.onReloadLicense}
        />
        <Row label="Show History" hint="The charts section under the board.">
          <Toggle on={props.showHistory} onChange={props.onShowHistory} label="Show History" />
        </Row>
        <Row
          label="Auto-switch"
          // No explicit threshold = adaptive time-to-wall (2026-08-13) —
          // the old `?? 90` fabricated a number the autopilot no longer
          // uses on a default install.
          hint={
            cfg?.autopilot?.threshold_percent != null
              ? `Switches to the account with headroom near ${cfg.autopilot.threshold_percent}%.`
              : "Switches when an account is ≈8 min from its limit, judged from live burn."
          }
        >
          <Toggle
            on={autoOn}
            onChange={(on) =>
              patch((c) => ({ ...c, autopilot: { ...c.autopilot, disabled: !on } }))
            }
            label="Auto-switch"
          />
        </Row>
        <Row label="Statusline" hint="Segments, presets, and a live preview of your terminal line.">
          <button
            onClick={() => {
              props.onOpenChange(false);
              props.onOpenStatusline();
            }}
            className="rounded-lg border border-hair px-2.5 py-1 text-[11.5px] text-sec transition-colors duration-150 hover:bg-wash"
          >
            Customize statusline
          </button>
        </Row>
        <Row label="Usage notifications" hint={`Notifies when a bucket crosses ${thresholds}%.`}>
          <Toggle
            on={notifOn}
            onChange={(on) =>
              patch((c) => ({ ...c, notifications: { ...c.notifications, disabled: !on } }))
            }
            label="Usage notifications"
          />
        </Row>
        {(props.state?.accounts ?? []).map((a) => (
          <Row
            key={a.id}
            label={`Plan cost — ${a.label || a.email}`}
            hint="Monthly cost, used by the value readout in History."
          >
            <div className="flex items-center gap-1 text-[12px] text-sec">
              $
              <input
                type="number"
                min={0}
                aria-label={`Monthly plan cost for ${a.label || a.email}`}
                className="w-[72px] rounded-md border border-hair bg-win px-2 py-1 text-right text-[12px]"
                value={cfg?.plan_cost_monthly?.[a.id] ?? ""}
                placeholder="200"
                onChange={(e) => {
                  const v = e.target.value === "" ? undefined : Number(e.target.value);
                  patch((c) => {
                    const costs = { ...c.plan_cost_monthly };
                    if (v === undefined || Number.isNaN(v)) delete costs[a.id];
                    else costs[a.id] = v;
                    return { ...c, plan_cost_monthly: costs };
                  });
                }}
              />
              /mo
            </div>
          </Row>
        ))}
      </div>
    </ShellDialog>
  );
}
