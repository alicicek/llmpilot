// Component grammar #3 — LANE header: 208px, avatar disc, email, ACTIVE tag,
// status line, runway bars. Stale snapshots drain every color and stamp
// their age instead of guessing (pack rule 5).
import type { AccountState } from "../api.ts";
import { avatarStyle } from "./avatar.ts";
import RunwayBar from "./RunwayBar.tsx";
import { fmtDurationLeft, fmtHMFromIso, isStale, minutesUntil, staleStamp } from "./severity.ts";

export interface LaneHeaderProps {
  account: AccountState;
  active: boolean;
  nowMinutes: number;
  onSwitch: () => void;
}

// tokenNoteSevere reports whether a token note describes a dead/expired
// sign-in (critical, needs re-login) versus one merely expiring soon (warn).
function tokenNoteSevere(note: string): boolean {
  return note.includes("expired") || note.includes("sign-in");
}

export default function LaneHeader({ account, active, nowMinutes, onSwitch }: LaneHeaderProps) {
  const snap = account.snapshot;
  // Stale = the daemon says the token expired (authoritative) OR the
  // snapshot is simply old — either way the lane drains and stamps its age.
  const stale = account.stale === true || (snap ? isStale(snap.as_of, nowMinutes) : false);
  const session = snap?.buckets.find((b) => b.kind === "session");
  const initial = (account.label || account.email || "?").slice(0, 1).toUpperCase();

  let dotClass = "bg-graydot";
  let statusText = "Nothing scheduled";
  let progressPct: number | null = null;
  let timeLeft: string | null = null;

  if (session) {
    if (session.active && session.resets_at) {
      dotClass = stale ? "bg-graydot" : "bg-warnraw";
      statusText = `Mid-window — resets ${fmtHMFromIso(session.resets_at)}`;
      progressPct = session.percent;
      timeLeft = fmtDurationLeft(minutesUntil(session.resets_at, nowMinutes));
    } else {
      dotClass = stale ? "bg-graydot" : "bg-ok";
      statusText = "Idle — no active window";
    }
  }
  if (stale) dotClass = "bg-graydot";

  return (
    <div className="flex w-[240px] shrink-0 gap-[10px] border-r border-hairsoft px-3 pt-[15px]">
      <div
        className="mt-px flex h-[26px] w-[26px] shrink-0 items-center justify-center rounded-full text-[12px] font-bold text-white"
        style={avatarStyle(account.id)}
      >
        {initial}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-[6px]">
          <span className="truncate text-[12.5px] font-semibold tracking-[-0.01em]">{account.email}</span>
          {active && (
            <span className="shrink-0 rounded-full bg-okbg px-[6px] py-px text-[8.5px] font-bold tracking-[0.04em] text-ok-tx">
              ACTIVE
            </span>
          )}
          {/* Switching is the product's staple verb, so it sits on the
              identity row where the eye already is — mirroring the ACTIVE
              badge one lane up, not buried under the runway bars as a
              footnote link. */}
          {!active && !account.pinned && (
            <button
              type="button"
              onClick={onSwitch}
              aria-label={`Switch to ${account.label || account.email}`}
              data-tour="switch"
              className="shrink-0 rounded-full border border-acc-bd bg-acc-a px-[7px] py-px text-[9px] font-bold tracking-[0.04em] text-acc-tx transition-colors duration-150 hover:bg-chipbg focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd"
            >
              SWITCH
            </button>
          )}
          {account.pinned && (
            <svg
              aria-label="pinned"
              role="img"
              viewBox="0 0 14 14"
              width="10"
              height="10"
              className="shrink-0 text-ter"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.3"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <path d="M7 1.5v3.4M4.2 5 3 8.2h8L9.8 5a2.8 2.8 0 0 0-5.6 0Z" />
              <path d="M7 8.2v4.3" />
            </svg>
          )}
        </div>
        <div className="mt-[3px] flex items-center gap-[5px] text-[10.5px] text-sec">
          <i className={`h-1.5 w-1.5 shrink-0 rounded-full ${dotClass}`} />
          <span className="truncate">{statusText}</span>
        </div>
        {account.token_note && (
          <div className={`mt-[3px] text-[10px] leading-snug ${tokenNoteSevere(account.token_note) ? "text-crit" : "text-warn"}`}>
            {account.token_note}
          </div>
        )}
        {progressPct != null && (
          <>
            <div className="mt-1.5 h-1 w-32 overflow-hidden rounded-sm bg-hairsoft">
              <div
                className={`h-full rounded-sm ${stale ? "bg-graydot" : "bg-warnraw"}`}
                style={{ width: `${Math.min(100, Math.max(0, progressPct))}%` }}
              />
            </div>
            {timeLeft && <div className="mt-1 text-[9.5px] text-ter">{timeLeft}</div>}
          </>
        )}
        {snap && (
          <div className="mt-1.5 flex flex-col" data-tour={active ? "runway" : undefined}>
            {snap.buckets.map((b, i) => (
              <RunwayBar key={`${b.kind}-${b.scope ?? i}`} bucket={b} refIso={snap.as_of} stale={stale} />
            ))}
          </div>
        )}
        {stale && snap && <div className="mt-1.5 text-[9.5px] text-ter">{staleStamp(snap.as_of, nowMinutes)}</div>}
        {!active && account.pinned && (
          <p className="mt-1.5 text-[10px] leading-relaxed text-ter">
            Watched — signs in from its own folder, usage only. Move it into the fleet from Add
            account to make it switchable.
          </p>
        )}
      </div>
    </div>
  );
}
