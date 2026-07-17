import { useState } from "react";
import { ApiError, cancelTrial, claimRecovery, fetchLicense, recoverLicense, type License } from "../api.ts";
import { licenseErrorCopy } from "./errors.ts";

// Settings → License. Shows status, the trial countdown + exact charge date,
// one-click cancel (consumer-law checklist c), recover-by-email (uniform copy —
// no enumeration), and a reveal/copy affordance for the license id. The signed
// entitlement token is never shown. Storage note is honest about multi-Mac.

interface Props {
  license: License | null;
  offline?: boolean;
  onTurnOn: () => void;
  onReload: () => void;
}

const linkBtn = "text-[11.5px] text-acc-tx hover:underline focus:outline-none focus-visible:underline";
const smallBtn =
  "rounded-lg border border-hair px-2.5 py-1 text-[11.5px] text-sec transition-colors duration-150 hover:bg-wash focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

function fmtDate(iso: string): string {
  const locale = typeof navigator !== "undefined" ? navigator.language : "en-GB";
  return new Date(iso).toLocaleDateString(locale, { day: "numeric", month: "long", year: "numeric" });
}

function statusLine(l: License): { title: string; hint: string } {
  switch (l.status) {
    case "trialing": {
      const days = l.trial?.days_left ?? 0;
      const left = `${days} ${days === 1 ? "day" : "days"} left`;
      const charge = l.trial?.charge_date ? ` · charges ${fmtDate(l.trial.charge_date)}` : "";
      return { title: "Free trial", hint: `${left}${charge}. Cancel anytime below.` };
    }
    case "lifetime":
      return { title: "Pro — lifetime", hint: "Bought once, yours for good." };
    case "lapsed":
      return { title: "Paused", hint: "Your trial ended. Schedules are kept; nothing was deleted." };
    case "revoked":
      return { title: "Paused", hint: "This purchase was refunded or disputed." };
    default:
      return { title: "Not active", hint: "The autopilot is off. Turn it on to have it watch your windows." };
  }
}

export function LicenseSection({ license, offline, onTurnOn, onReload }: Props) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [revealed, setRevealed] = useState<string | null>(null);

  if (license && !license.available) {
    return (
      <section aria-label="License" className="border-b border-hairsoft py-2.5">
        <div className="text-[12px] font-semibold">llmpilot Pro</div>
        <p className="mt-0.5 text-[10.5px] leading-relaxed text-ter">
          This is a source build — the autopilot is not included. Switching, statusline, cockpit, and
          analytics keep working. The official app at llmpilot.dev includes Pro.
        </p>
      </section>
    );
  }

  const l = license ?? { status: offline ? "unknown" : "none", available: true, active: false, nocard_trial_used: false };
  const s = statusLine(l as License);
  const canCancel = l.status === "trialing";
  const showTurnOn = l.status === "none" || l.status === "lapsed" || l.status === "revoked";

  const doCancel = async () => {
    setBusy(true);
    setNote(null);
    try {
      await cancelTrial();
      setConfirming(false);
      onReload();
    } catch (e) {
      setNote(e instanceof Error ? e.message : "Cancel could not complete — try again.");
    } finally {
      setBusy(false);
    }
  };

  const doRecover = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setNote(null);
    try {
      await recoverLicense(email);
      // Uniform copy regardless of whether the address is on file.
      setNote("If that email has a purchase, a recovery link is on its way. Open it on this Mac.");
      setEmail("");
    } catch (err) {
      setNote(err instanceof Error ? err.message : "Could not send the email — try again.");
    } finally {
      setBusy(false);
    }
  };

  const doClaim = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setNote(null);
    try {
      await claimRecovery(code.trim());
      setCode("");
      setNote("Restored — Pro is back on.");
      onReload();
    } catch (err) {
      const mapped = err instanceof ApiError ? licenseErrorCopy(err.code) : null;
      setNote(mapped ?? (err instanceof Error ? err.message : "This code is invalid or expired."));
    } finally {
      setBusy(false);
    }
  };

  const reveal = async () => {
    try {
      const full = await fetchLicense(true);
      setRevealed(full.license_id ?? full.license_id_masked ?? null);
    } catch {
      setNote("Could not read the license id.");
    }
  };

  return (
    <section aria-label="License" className="border-b border-hairsoft py-2.5">
      <div className="flex items-center justify-between gap-4">
        <div>
          <div className="text-[12px] font-semibold">{s.title}</div>
          <div className="mt-0.5 text-[10.5px] text-ter">{s.hint}</div>
        </div>
        {showTurnOn && (
          <button className={smallBtn} onClick={onTurnOn}>
            Turn on the autopilot
          </button>
        )}
        {canCancel && !confirming && (
          <button className={smallBtn} onClick={() => setConfirming(true)}>
            Cancel trial
          </button>
        )}
      </div>

      {confirming && (
        <div className="mt-2 rounded-lg border border-hair bg-panel px-3 py-2">
          <p className="text-[11.5px] text-text">Cancel the trial? The autopilot pauses now and you are not charged.</p>
          <div className="mt-2 flex items-center gap-3">
            <button
              className="rounded-lg bg-crit-deep px-2.5 py-1 text-[11.5px] font-semibold text-white disabled:opacity-60"
              onClick={doCancel}
              disabled={busy}
            >
              Cancel the trial
            </button>
            <button className={linkBtn} onClick={() => setConfirming(false)} disabled={busy}>
              Keep the trial
            </button>
          </div>
        </div>
      )}

      {l.license_id_masked && (
        <div className="mt-2 flex items-center gap-3 text-[10.5px] text-ter">
          <span>License {revealed ?? l.license_id_masked}</span>
          {!revealed ? (
            <button className={linkBtn} onClick={reveal}>
              Show
            </button>
          ) : (
            <button
              className={linkBtn}
              onClick={() => void navigator.clipboard?.writeText(revealed)}
            >
              Copy
            </button>
          )}
        </div>
      )}

      <form className="mt-2.5 flex items-center gap-2" onSubmit={doRecover}>
        <input
          type="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          aria-label="Email to recover a purchase"
          className="w-[180px] rounded-md border border-hair bg-win px-2 py-1 text-[11.5px]"
        />
        <button className={smallBtn} type="submit" disabled={busy}>
          Restore by email
        </button>
      </form>

      <form className="mt-2 flex items-center gap-2" onSubmit={doClaim}>
        <input
          type="text"
          required
          value={code}
          onChange={(e) => setCode(e.target.value)}
          placeholder="recovery code"
          aria-label="Recovery code from your email"
          className="w-[180px] rounded-md border border-hair bg-win px-2 py-1 font-mono text-[11.5px]"
        />
        <button className={smallBtn} type="submit" disabled={busy}>
          Restore with code
        </button>
      </form>

      <p className="mt-2 text-[10px] leading-relaxed text-ter">
        Stored on this Mac. Other Macs turn on Pro by email — enter the code from
        the email above.
      </p>

      {!note && licenseErrorCopy((l as License).error_code) && (
        <p className="mt-2 rounded-lg border border-hair bg-panel px-3 py-1.5 text-[11px] text-sec" role="alert">
          {licenseErrorCopy((l as License).error_code)}
        </p>
      )}

      {note && (
        <p className="mt-2 rounded-lg border border-hair bg-panel px-3 py-1.5 text-[11px] text-sec" role="status">
          {note}
        </p>
      )}
    </section>
  );
}
