import { useEffect, useState } from "react";
import { adoptAccount, fetchDetected, type DetectedDir } from "../api.ts";

// Empty fleet = first run. Detect logged-in Claude accounts on this Mac and
// adopt them with one click — the UI flow IS onboarding; `llmpilot init` is
// the power-user shortcut, never the required path.
export function FirstRun() {
  const [detected, setDetected] = useState<DetectedDir[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    fetchDetected()
      .then(setDetected)
      .catch(() => setDetected([]));
  }, []);

  const candidates = (detected ?? []).filter((d) => !d.registered);

  return (
    <div className="mx-auto mt-16 w-[480px] max-w-[92vw]">
      <h1 className="text-[15px] font-bold tracking-[-0.01em]">Adopt your accounts</h1>
      <p className="mt-1.5 text-[12px] leading-relaxed text-sec">
        llmpilot watches every Claude account on this Mac — live limits, auto-switch
        before a wall, fresh windows on your schedule.
      </p>

      {detected === null ? (
        <p className="mt-5 text-[12px] text-ter">Looking for signed-in accounts…</p>
      ) : candidates.length === 0 ? (
        <div className="mt-5 rounded-lg border border-hairsoft bg-panel px-4 py-3 text-[12px] leading-relaxed text-sec">
          No signed-in Claude accounts found. Sign one in from your terminal —{" "}
          <code className="font-semibold">llmpilot account add</code> — and it appears
          here on its own.
        </div>
      ) : (
        <ul className="mt-5 flex flex-col">
          {candidates.map((d) => (
            <li
              key={d.config_dir}
              className="flex items-center justify-between gap-3 border-b border-hairsoft py-2.5 last:border-b-0"
            >
              <div>
                <div className="text-[12.5px] font-semibold">{d.email}</div>
                <div className="mt-0.5 text-[10.5px] text-ter">{d.config_dir}</div>
              </div>
              <button
                disabled={busy !== null}
                onClick={() => {
                  setBusy(d.config_dir);
                  setErr(null);
                  adoptAccount(d.config_dir)
                    .catch((e: Error) => setErr(e.message))
                    .finally(() => setBusy(null));
                }}
                className="rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
              >
                {busy === d.config_dir ? "Adopting…" : "Adopt account"}
              </button>
            </li>
          ))}
        </ul>
      )}

      {err && (
        <p className="mt-3 rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] text-warn">
          {err}
        </p>
      )}

      <p className="mt-5 text-[10.5px] leading-relaxed text-ter">
        Adopting reads each account's credential once — macOS asks with a Keychain
        prompt; choose "Always Allow" so the daemon can watch limits unattended.
        Tokens never leave this Mac.
      </p>
    </div>
  );
}
