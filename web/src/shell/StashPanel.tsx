import { useState } from "react";
import { adoptStash, discardStash, type StashEntry } from "../api.ts";

// A swap preserved sign-ins it could not attribute to any registered
// account. Each entry has exactly two ways out — adopt it into the fleet or
// discard it (deletes the stored credential). A dead entry (the token
// endpoint rejected its lineage) cannot be adopted: only a fresh sign-in
// recovers that account, so the button says so instead of failing.
export function StashPanel({ stash }: { stash: StashEntry[] }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  // Discard permanently deletes the only remaining copy of a credential —
  // it takes a second click to confirm (review P2: no one-click destroy).
  const [confirmDiscard, setConfirmDiscard] = useState<string | null>(null);

  if (stash.length === 0) return null;

  const run = (fingerprint: string, action: () => Promise<void>) => {
    setBusy(fingerprint);
    setErr(null);
    action()
      .catch((e: Error) => setErr(e.message))
      .finally(() => setBusy(null));
  };

  return (
    <section
      id="kept-signins"
      className="mx-auto mt-4 w-[720px] max-w-[94vw] rounded-lg border border-hairsoft bg-panel px-4 py-3"
    >
      <h2 className="text-[12.5px] font-bold tracking-[-0.01em]">
        Kept sign-ins from switching
      </h2>
      <p className="mt-0.5 text-[11px] leading-relaxed text-sec">
        A switch found these signed in but not in your fleet, so it kept them —
        add one to watch it here, or discard it to delete its stored credential.
      </p>
      <ul className="mt-2 flex flex-col">
        {stash.map((e) => (
          <li
            key={e.fingerprint}
            className="flex items-center justify-between gap-3 border-b border-hairsoft py-2 last:border-b-0"
          >
            <div className="min-w-0">
              <div className="truncate text-[12px] font-semibold">
                {e.label || "unknown account"}
              </div>
              <div className="mt-0.5 text-[10.5px] tabular-nums text-ter">
                kept {new Date(e.stashed_at).toLocaleString([], {
                  hour: "2-digit",
                  minute: "2-digit",
                  day: "2-digit",
                  month: "2-digit",
                  hour12: false,
                })}
                {e.dead && " · sign-in expired — log in to this account again to use it"}
              </div>
            </div>
            <div className="flex shrink-0 gap-2">
              <button
                disabled={busy !== null || e.dead === true}
                title={e.dead ? "sign-in expired — log in to this account again to use it" : undefined}
                onClick={() => run(e.fingerprint, () => adoptStash(e.fingerprint))}
                className="rounded-md bg-acc-tx px-2.5 py-1 text-[11px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
              >
                {busy === e.fingerprint ? "Adding…" : "Add account"}
              </button>
              <button
                disabled={busy !== null}
                onClick={() => {
                  if (confirmDiscard === e.fingerprint) {
                    setConfirmDiscard(null);
                    run(e.fingerprint, () => discardStash(e.fingerprint));
                  } else {
                    setConfirmDiscard(e.fingerprint);
                  }
                }}
                onBlur={() => setConfirmDiscard((f) => (f === e.fingerprint ? null : f))}
                className="rounded-md border border-hairsoft px-2.5 py-1 text-[11px] font-semibold text-sec hover:text-warn"
              >
                {confirmDiscard === e.fingerprint ? "Delete for good?" : "Discard sign-in"}
              </button>
            </div>
          </li>
        ))}
      </ul>
      {err && (
        <p className="mt-2 rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] text-warn">
          {err}
        </p>
      )}
    </section>
  );
}
