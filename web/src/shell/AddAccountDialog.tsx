import { useEffect, useRef, useState } from "react";
import { ShellDialog } from "./dialog.tsx";
import {
  ApiError,
  cancelBrowserLogin,
  fetchBrowserLoginStatus,
  startBrowserLogin,
  submitLoginCode,
} from "../api.ts";

// "Sign in with Claude": the daemon runs Claude Code's own sign-in, which
// opens the browser itself; we poll THIS attempt until it lands. If the
// browser didn't open, the sign-in page's link and a paste field finish it.
// The terminal command stays as the documented last-ditch fallback.

type Phase = "idle" | "starting" | "browserWait" | "done";

function doneMessage(outcome?: string, email?: string): string {
  const who = email || "The account";
  if (outcome === "active") return `${who} is signed in — Claude Code is using it.`;
  if (outcome === "updated") return `${who} is signed in again.`;
  return `${who} joined your fleet — switch to it any time.`;
}

function sentence(s: string): string {
  if (!s) return s;
  const out = s[0].toUpperCase() + s.slice(1);
  return /[.?…]$/.test(out) ? out : `${out}.`;
}

export function AddAccountDialog(props: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [manualUrl, setManualUrl] = useState("");
  const [paste, setPaste] = useState("");
  const [pasteBusy, setPasteBusy] = useState(false);
  const [pasteError, setPasteError] = useState<string | null>(null);
  const [done, setDone] = useState("");
  const [doneWarn, setDoneWarn] = useState(false);
  const requested = useRef<string | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [claudeMissing, setClaudeMissing] = useState(false);
  const [copied, setCopied] = useState(false);
  const attemptId = useRef("");
  const onOpenChange = useRef(props.onOpenChange);
  onOpenChange.current = props.onOpenChange;
  const cmd = "llmpilot account add";

  const reset = () => {
    setPhase("idle");
    setManualUrl("");
    setPaste("");
    setPasteBusy(false);
    setPasteError(null);
    setDone("");
    setDoneWarn(false);
    setError(null);
    setClaudeMissing(false);
    attemptId.current = "";
  };

  // While waiting, poll THIS attempt's status — the daemon records the
  // outcome under the attempt id (a fleet-size check would never complete on
  // a re-sign-in and could false-positive on a concurrent add).
  useEffect(() => {
    if (phase !== "browserWait") return;
    let cancelled = false;
    let timer = 0;
    const started = Date.now();
    const tick = async () => {
      if (cancelled) return;
      try {
        const s = await fetchBrowserLoginStatus(attemptId.current);
        if (cancelled) return;
        if (s.status === "done") {
          const landed = s.email ?? "";
          const want = requested.current;
          setPhase("done");
          if (want && landed && want.toLowerCase() !== landed.toLowerCase()) {
            setDoneWarn(true);
            setDone(
              `You approved as ${landed}, not ${want}. ${landed} is signed in; to fix ${want}, sign in again and pick that account in your browser.`,
            );
            return;
          }
          if (!want && s.existing === "true" && landed) {
            setDoneWarn(true);
            setDone(
              `${landed} is already in your fleet — its sign-in is fresh now. To add a different account, sign out of claude.ai in your browser first, then sign in again.`,
            );
            return;
          }
          setDone(doneMessage(s.outcome, s.email) + (s.note ? ` ${s.note}` : ""));
          if (!s.note) setTimeout(() => onOpenChange.current(false), 1800);
          return;
        }
        if (s.status === "failed") {
          setError(s.error ? sentence(s.error) : "Sign-in didn't finish — try again.");
          setPasteBusy(false);
          setPhase("idle");
          return;
        }
        if (s.manual_url) setManualUrl(s.manual_url);
      } catch (e) {
        if (e instanceof ApiError && e.code === "unknown_attempt") {
          // The daemon restarted and forgot this attempt.
          setError("This sign-in ended when llmpilot restarted — start it again.");
          setPhase("idle");
          return;
        }
        // transient (daemon busy); keep polling
      }
      if (cancelled) return;
      if (Date.now() - started < 11 * 60_000) {
        timer = window.setTimeout(() => void tick(), 1500);
      } else {
        setError("The sign-in timed out — start it again.");
        setPhase("idle");
      }
    };
    timer = window.setTimeout(() => void tick(), 1500);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [phase]);

  const signIn = async (email?: string) => {
    reset();
    requested.current = email;
    setPhase("starting");
    try {
      const s = await startBrowserLogin(email);
      attemptId.current = s.attempt_id;
      setPhase("browserWait");
    } catch (e) {
      if (e instanceof ApiError && e.code === "claude_missing") {
        setClaudeMissing(true);
        setError(
          "llmpilot signs you in through Claude Code, which isn't installed on this Mac. Install it, then try again.",
        );
      } else {
        setError(sentence(e instanceof Error ? e.message : String(e)));
      }
      setPhase("idle");
    }
  };

  const cancel = () => {
    const id = attemptId.current;
    if (id) void cancelBrowserLogin(id).catch(() => {});
    reset();
  };

  const submitCode = async () => {
    const code = paste.trim();
    if (!code || pasteBusy) return;
    setPasteBusy(true);
    setPasteError(null);
    try {
      await submitLoginCode(attemptId.current, code);
    } catch (e) {
      setPasteBusy(false);
      setPasteError(sentence(e instanceof Error ? e.message : String(e)));
    }
  };

  return (
    <ShellDialog
      open={props.open}
      onOpenChange={(o) => {
        if (!o) {
          reset();
          requested.current = undefined;
        }
        props.onOpenChange(o);
      }}
      title="Add account"
    >
      {phase === "done" ? (
        doneWarn ? (
          <>
            <p className="rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] leading-relaxed text-warn">
              {done}
            </p>
            <button
              onClick={() => void signIn(requested.current)}
              className="self-start rounded-md border border-hair px-2.5 py-1.5 text-[11.5px] font-semibold text-sec hover:text-text"
            >
              Sign in again
            </button>
          </>
        ) : (
          <p className="text-[12px] leading-relaxed text-sec">{done}</p>
        )
      ) : phase === "browserWait" ? (
        <>
          <p className="text-[12px] leading-relaxed text-sec">
            Finish signing in in your browser. This updates on its own the moment you approve.
          </p>
          <div className="flex items-center gap-2">
            <button
              onClick={cancel}
              className="rounded-md px-2.5 py-1.5 text-[11.5px] font-semibold text-ter hover:text-sec"
            >
              Cancel
            </button>
          </div>
          <details className="text-[11px] text-ter">
            <summary className="cursor-pointer select-none">Browser didn't open?</summary>
            <div className="mt-2 flex flex-col gap-2">
              <a
                href={manualUrl || undefined}
                target="_blank"
                rel="noreferrer"
                aria-disabled={!manualUrl}
                className={`self-start rounded-md border border-hair px-2.5 py-1.5 text-[11.5px] font-semibold text-sec hover:text-text ${manualUrl ? "" : "pointer-events-none opacity-50"}`}
              >
                Open the sign-in page
              </a>
              <p className="leading-relaxed">Approve there, then paste the code the page shows.</p>
              <div className="flex items-center gap-2">
                <input
                  value={paste}
                  onChange={(e) => setPaste(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") void submitCode();
                  }}
                  placeholder="Paste code"
                  spellCheck={false}
                  disabled={pasteBusy}
                  className="min-w-0 flex-1 rounded-lg border border-hairsoft bg-panel px-3 py-2 font-mono text-[12px]"
                />
                <button
                  onClick={() => void submitCode()}
                  disabled={pasteBusy || paste.trim() === ""}
                  className="rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
                >
                  {pasteBusy ? "Adding…" : "Add account"}
                </button>
              </div>
              {pasteError && <p className="leading-relaxed text-warn">{pasteError}</p>}
            </div>
          </details>
        </>
      ) : (
        <>
          <p className="text-[12px] leading-relaxed text-sec">
            Sign in with your Claude account. Your browser opens, and the account joins the fleet
            when you approve — adding an account never switches Claude Code.
          </p>
          <button
            onClick={() => void signIn(error ? requested.current : undefined)}
            disabled={phase === "starting"}
            className="self-start rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
          >
            {phase === "starting" ? "Starting…" : error ? "Try again" : "Sign in with Claude"}
          </button>
        </>
      )}
      {error && (
        <div className="rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] leading-relaxed text-warn">
          <p>{error}</p>
          {claudeMissing && (
            <a
              href="https://code.claude.com/docs/en/setup"
              target="_blank"
              rel="noreferrer"
              className="mt-1 inline-block font-semibold underline"
            >
              Install Claude Code
            </a>
          )}
        </div>
      )}
      {phase !== "done" && (
        <details className="text-[11px] text-ter">
          <summary className="cursor-pointer select-none">Prefer the terminal?</summary>
          <div className="mt-2 flex items-center gap-2 rounded-lg border border-hairsoft bg-panel px-3 py-2">
            <code className="flex-1 text-[12px] font-semibold text-sec">{cmd}</code>
            <button
              className="rounded-md border border-hair px-2.5 py-1 text-[11px] font-semibold text-sec hover:text-text"
              onClick={() => {
                void navigator.clipboard.writeText(cmd).then(() => {
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1500);
                });
              }}
            >
              {copied ? "Copied ✓" : "Copy"}
            </button>
          </div>
          <p className="mt-2 leading-relaxed">
            Run it, sign in, and the account appears here on its own. First read of a new
            account triggers one macOS Keychain prompt — choose "Always Allow" so the daemon
            can keep watching it unattended.
          </p>
        </details>
      )}
    </ShellDialog>
  );
}
