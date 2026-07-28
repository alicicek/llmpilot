import { DropdownMenu } from "radix-ui";
import type { Connection, State } from "../api.ts";

// Native toolbar chrome per the mockup (tbar): app name, daemon pill, the
// two verbs, the gear. Segmented nav intentionally absent — one place.
export function Toolbar(props: {
  conn: Connection;
  state: State | null;
  asOfAge: string | null;
  /** unregistered config dirs detected on this Mac — 0 renders no badge. */
  detectedCount: number;
  onFreshWindow: (accountId: string) => void;
  onAddAccount: () => void;
  onSettings: () => void;
}) {
  const accounts = props.state?.accounts ?? [];
  const pillLabel =
    props.conn === "live"
      ? "Daemon active"
      : props.conn === "connecting"
        ? "Connecting"
        : props.asOfAge
          ? `Daemon down — as of ${props.asOfAge}`
          : "Daemon not running";

  return (
    <header className="flex h-[52px] items-center gap-2.5 border-b border-hair bg-toolbar px-4">
      <span className="text-[13px] font-bold tracking-[0.01em]">llmpilot</span>
      <div className="flex-1" />
      <span className="flex items-center gap-1.5 rounded-full border border-hair px-3 py-1 text-[11px] text-sec">
        <i
          className={`h-[7px] w-[7px] rounded-full ${
            props.conn === "live" ? "bg-ok shadow-[0_0_5px_var(--ok)]" : "bg-graydot"
          }`}
        />
        {pillLabel}
      </span>
      <button
        onClick={props.onAddAccount}
        className="flex items-center gap-1.5 rounded-md border border-hair px-3 py-1.5 text-[11.5px] text-sec hover:text-text"
      >
        ＋ Add account
        {props.detectedCount > 0 && (
          <span className="flex h-[15px] min-w-[15px] items-center justify-center rounded-full bg-rail px-[4px] text-[9.5px] font-bold tabular-nums text-text">
            {props.detectedCount}
          </span>
        )}
      </button>
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            disabled={accounts.length === 0}
            className="rounded-md bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
          >
            ＋ Fresh window
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="end"
            sideOffset={6}
            className="min-w-[180px] rounded-lg border border-hair bg-win p-1 shadow-window"
          >
            <DropdownMenu.Label className="px-2.5 py-1 text-[9px] font-bold tracking-[0.07em] text-ter">
              BOOK ON
            </DropdownMenu.Label>
            {accounts.map((a) => (
              <DropdownMenu.Item
                key={a.id}
                onSelect={() => props.onFreshWindow(a.id)}
                className="cursor-default rounded-md px-2.5 py-1.5 text-[12px] outline-none data-highlighted:bg-panel"
              >
                {a.label || a.email}
              </DropdownMenu.Item>
            ))}
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      <button
        aria-label="Settings"
        onClick={props.onSettings}
        className="rounded px-1.5 py-1 text-[14px] text-sec hover:text-text"
      >
        ⚙︎
      </button>
    </header>
  );
}
