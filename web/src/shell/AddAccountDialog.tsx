import { useEffect, useRef, useState } from "react";
import { ShellDialog } from "./dialog.tsx";
import {
  adoptAccount,
  adoptMove,
  completeLogin,
  fetchBrowserLoginStatus,
  startBrowserLogin,
  startLogin,
  type DetectedDir,
} from "../api.ts";

// "Sign in with Claude" — two zero-terminal paths, the user picks:
//   • BROWSER (recommended): the daemon runs a loopback listener; we open the
//     approval page in the real browser (1Password works), and it redirects
//     back automatically — no paste. We just watch the fleet for the account.
//   • IN THIS WINDOW: the native login window (its own webview) inside the
//     cockpit app; a plain browser gets the browser+paste flow instead.
// The terminal command stays as the documented last-ditch fallback.

type Phase = "idle" | "starting" | "browserWait" | "awaiting" | "completing" | "done";

function nativeLoginBridge(): { postMessage: (m: string) => void } | undefined {
  if (typeof window === "undefined") return undefined;
  return (
    window as unknown as {
      webkit?: { messageHandlers?: { startLogin?: { postMessage: (m: string) => void } } };
    }
  ).webkit?.messageHandlers?.startLogin;
}

// openExternal sends a URL to the real browser. In the native cockpit window a
// target=_blank navigation is intercepted and handed to the system browser;
// in a plain browser it opens a tab.
function openExternal(url: string) {
  const a = document.createElement("a");
  a.href = url;
  a.target = "_blank";
  a.rel = "noreferrer";
  document.body.appendChild(a);
  a.click();
  a.remove();
}

// DetectedSection is the "already signed in on this Mac" list — the fix for
// the carryover bug (only the first of N detected dirs ever got an adopt
// affordance). Each unregistered dir gets two verbs: an additive watch-only
// adopt, or a destructive move into the switchable fleet (two-step confirm,
// same precedent as StashPanel's discard — no one-click destroy).
function DetectedSection({
  detected,
  fleetDir,
  onChanged,
}: {
  detected: DetectedDir[];
  fleetDir: string;
  onChanged: () => void;
}) {
  const [busy, setBusy] = useState<{ dir: string; action: "adopt" | "move" } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [confirmMove, setConfirmMove] = useState<string | null>(null);
  const [moveNotes, setMoveNotes] = useState<Record<string, string>>({});

  // Unregistered dirs get both verbs. A dir whose account is registered as
  // WATCHED (pinned) keeps the migration verb — that is the primary
  // flow (add as watched, then move), and three other strings in the product
  // point the user here. A dir already moved is informational only.
  // Every folder except the fleet's own slot is worth listing: unregistered
  // ones can be adopted or moved, a watched account's folder keeps the
  // migration verb, a moved-and-still-empty one is informational, and a
  // folder someone signed back into after a move needs the verb that
  // resolves it — filtering by registration hid exactly that last case.
  const candidates = detected.filter((d) => d.config_dir !== fleetDir);
  // The section outlives its own list: a completed move empties the
  // candidates, and unmounting here would take an outcome warning with it —
  // a partial retirement silently reported as success.
  const notes = Object.entries(moveNotes);
  if (candidates.length === 0 && notes.length === 0) return null;

  const runAdopt = (dir: string) => {
    setBusy({ dir, action: "adopt" });
    setErr(null);
    adoptAccount(dir)
      .then(onChanged)
      .catch((e: Error) => setErr(e.message))
      .finally(() => setBusy(null));
  };

  const runMove = (dir: string) => {
    setBusy({ dir, action: "move" });
    setErr(null);
    setConfirmMove(null);
    adoptMove(dir)
      .then((res) => {
        setMoveNotes((m) => {
          const next = { ...m };
          if (res.outcome === "clone_suspect") {
            next[dir] =
              res.note ||
              "A second copy of this sign-in may still exist — llmpilot will not switch to it until that's resolved.";
          } else {
            // A later clean move of the same folder resolves the earlier
            // warning — a note that is no longer true must not linger.
            delete next[dir];
          }
          return next;
        });
        onChanged();
      })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setBusy(null));
  };

  return (
    <section className="rounded-lg border border-hairsoft bg-panel px-3 py-2.5">
      <h2 className="text-[11.5px] font-bold tracking-[-0.01em]">Already signed in on this Mac</h2>
      {candidates.length > 0 && (
      <ul className="mt-1.5 flex flex-col">
        {candidates.map((d) => (
          <li key={d.config_dir} className="border-b border-hairsoft py-2 last:border-b-0 last:pb-0">
            <div className="min-w-0">
              <div className="truncate text-[12px] font-semibold">{d.email}</div>
              <div className="mt-0.5 truncate text-[10px] text-ter">{d.config_dir}</div>
            </div>
            {d.moved ? (
              <p className="mt-1 text-[10.5px] leading-relaxed text-ter">
                Already moved into the fleet.
              </p>
            ) : d.signed_in === false ? (
              // The folder names an account but holds no sign-in. Both verbs
              // refuse here, so neither is offered — the user gets the one
              // thing that changes the state instead.
              <p className="mt-1 text-[10.5px] leading-relaxed text-ter">
                Signed out — this folder remembers the account, but its sign-in is gone. Run{" "}
                <code className="font-semibold">claude</code> in that folder and sign in again to
                use it here.
              </p>
            ) : (
              <>
                <p className="mt-1 text-[10px] leading-relaxed text-ter">
                  {d.registered
                    ? "llmpilot already knows this account. Moving this copy leaves one sign-in — it won't refresh the account while two exist."
                    : "Add as watched keeps its usage visible without ever switching to it. Move into the fleet makes it switchable."}
                </p>
                <div className="mt-1.5 flex flex-wrap items-center gap-2">
                  {!d.registered && (
                  <button
                    disabled={busy !== null}
                    onClick={() => runAdopt(d.config_dir)}
                    className="rounded-md border border-hair px-2.5 py-1 text-[11px] font-semibold text-sec hover:text-text disabled:opacity-50"
                  >
                    {busy?.dir === d.config_dir && busy.action === "adopt" ? "Adding…" : "Add as watched"}
                  </button>
                  )}
                  <button
                    disabled={busy !== null}
                    onClick={() => {
                      if (confirmMove === d.config_dir) {
                        runMove(d.config_dir);
                      } else {
                        setConfirmMove(d.config_dir);
                      }
                    }}
                    onBlur={() => setConfirmMove((c) => (c === d.config_dir ? null : c))}
                    className="rounded-md border border-hairsoft px-2.5 py-1 text-[11px] font-semibold text-sec hover:text-warn disabled:opacity-50"
                  >
                    {busy?.dir === d.config_dir && busy.action === "move"
                      ? "Moving…"
                      : confirmMove === d.config_dir
                        ? "Move it — confirm"
                        : "Move into the fleet"}
                  </button>
                </div>
                {confirmMove === d.config_dir && (
                  <p className="mt-1.5 text-[10px] leading-relaxed text-warn">
                    The sign-in leaves {d.config_dir} — a terminal using that folder will need to sign
                    in again.
                  </p>
                )}
              </>
            )}
          </li>
        ))}
      </ul>
      )}
      {/* Outcome notes live at SECTION level, not in the row: a completed
          move drops its dir from the list, and a warning that unmounts with
          the row would flash for a frame and vanish — a partial retirement
          reported as success. */}
      {notes.map(([dir, note]) => (
        <p
          key={dir}
          className="mt-2 rounded-md border border-warnbd bg-warnbg px-2.5 py-2 text-[10.5px] leading-relaxed text-warn"
        >
          {note}
        </p>
      ))}
      {err && (
        <p className="mt-2 rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] text-warn">
          {err}
        </p>
      )}
    </section>
  );
}

export function AddAccountDialog(props: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  detected: DetectedDir[];
  /** the fleet's own config dir — the one folder that is never listed, since
   *  the account signed in there is already switchable. */
  fleetDir: string;
  onDetectedChange: () => void;
}) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [url, setUrl] = useState("");
  const [paste, setPaste] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const attemptId = useRef("");
  const onOpenChange = useRef(props.onOpenChange);
  onOpenChange.current = props.onOpenChange;
  const cmd = "llmpilot account add";

  const reset = () => {
    setPhase("idle");
    setUrl("");
    setPaste("");
    setError(null);
  };

  // Refresh detected dirs every time the dialog opens — the shipped bug was
  // a list that only ever loaded once and never shrank as accounts got
  // adopted.
  const onDetectedChange = useRef(props.onDetectedChange);
  onDetectedChange.current = props.onDetectedChange;
  useEffect(() => {
    if (props.open) onDetectedChange.current();
  }, [props.open]);

  // While waiting on the browser sign-in, poll THIS attempt's status — the
  // daemon completes the exchange+install when the browser redirects back and
  // records the outcome under the attempt id (a fleet-size check would never
  // complete on a re-login and could false-positive on a concurrent add).
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
          setPhase("done");
          setTimeout(() => onOpenChange.current(false), 1200);
          return;
        }
        if (s.status === "failed") {
          setError(s.error || "Sign-in failed — try again.");
          setPhase("idle");
          return;
        }
      } catch {
        // transient (daemon busy); keep polling
      }
      if (cancelled) return;
      if (Date.now() - started < 5 * 60_000) {
        timer = window.setTimeout(() => void tick(), 2000);
      } else {
        setError("Didn't detect a completed sign-in — finish it in your browser, or try again.");
        setPhase("idle");
      }
    };
    timer = window.setTimeout(() => void tick(), 2000);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [phase]);

  const browserSignIn = async () => {
    setError(null);
    setPhase("starting");
    try {
      const s = await startBrowserLogin();
      attemptId.current = s.attempt_id;
      setUrl(s.authorize_url);
      openExternal(s.authorize_url);
      setPhase("browserWait");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPhase("idle");
    }
  };

  const windowSignIn = async () => {
    const bridge = nativeLoginBridge();
    if (bridge) {
      // Native app: the in-app login window handles it (its own webview).
      bridge.postMessage("open");
      props.onOpenChange(false);
      return;
    }
    // Plain browser: fall back to the hosted-callback + paste flow.
    setError(null);
    setPhase("starting");
    try {
      const s = await startLogin();
      setUrl(s.authorize_url);
      setPhase("awaiting");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPhase("idle");
    }
  };

  const submitCode = async () => {
    const raw = paste.trim();
    const hash = raw.indexOf("#");
    if (hash <= 0 || hash === raw.length - 1) {
      setError("That's not the full code — copy everything shown, including the part after #.");
      return;
    }
    setError(null);
    setPhase("completing");
    try {
      await completeLogin(raw.slice(0, hash), raw.slice(hash + 1));
      setPhase("done");
      setTimeout(() => props.onOpenChange(false), 1200);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPhase("awaiting");
    }
  };

  return (
    <ShellDialog
      open={props.open}
      onOpenChange={(o) => {
        if (!o) reset();
        props.onOpenChange(o);
      }}
      title="Add account"
    >
      {phase === "idle" && (
        <DetectedSection
          detected={props.detected}
          fleetDir={props.fleetDir}
          onChanged={onDetectedChange.current}
        />
      )}
      {phase === "done" ? (
        <p className="text-[12px] leading-relaxed text-sec">
          Signed in — the account is joining your fleet now.
        </p>
      ) : phase === "browserWait" ? (
        <>
          <p className="text-[12px] leading-relaxed text-sec">
            Finish signing in in your browser — your password manager works there. This updates
            on its own the moment you're done.
          </p>
          <div className="flex items-center gap-2">
            <button
              onClick={() => openExternal(url)}
              className="rounded-md border border-hair px-2.5 py-1.5 text-[11.5px] font-semibold text-sec hover:text-text"
            >
              Reopen browser
            </button>
            <button
              onClick={reset}
              className="rounded-md px-2.5 py-1.5 text-[11.5px] font-semibold text-ter hover:text-sec"
            >
              Cancel
            </button>
          </div>
        </>
      ) : phase === "awaiting" || phase === "completing" ? (
        <>
          <p className="text-[12px] leading-relaxed text-sec">
            Approve the sign-in on claude.com, then paste the code it shows you here.
          </p>
          <a
            href={url}
            target="_blank"
            rel="noreferrer"
            className="self-start rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white dark:bg-accent"
          >
            Open claude.com
          </a>
          <div className="flex items-center gap-2">
            <input
              value={paste}
              onChange={(e) => setPaste(e.target.value)}
              placeholder="Paste code here"
              spellCheck={false}
              className="min-w-0 flex-1 rounded-lg border border-hairsoft bg-panel px-3 py-2 font-mono text-[12px]"
            />
            <button
              onClick={() => void submitCode()}
              disabled={phase === "completing" || paste.trim() === ""}
              className="rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
            >
              {phase === "completing" ? "Adding…" : "Add account"}
            </button>
          </div>
        </>
      ) : (
        <>
          <p className="text-[12px] leading-relaxed text-sec">
            Sign in with your Claude account and it joins the fleet — no terminal needed.
          </p>
          <div className="flex flex-col gap-2">
            <button
              onClick={() => void browserSignIn()}
              disabled={phase === "starting"}
              className="self-start rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
            >
              {phase === "starting" ? "Starting…" : "Sign in with your browser"}
            </button>
            <button
              onClick={() => void windowSignIn()}
              disabled={phase === "starting"}
              className="self-start rounded-md border border-hair px-3 py-1.5 text-[11.5px] font-semibold text-sec hover:text-text disabled:opacity-50"
            >
              Sign in in this window
            </button>
          </div>
          <p className="text-[11px] leading-relaxed text-ter">
            The browser option works with 1Password and skips any code-pasting. "In this window"
            keeps it inside the app.
          </p>
        </>
      )}
      {error && (
        <p className="rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] leading-relaxed text-warn">
          {error}
        </p>
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
