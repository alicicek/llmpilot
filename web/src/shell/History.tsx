import { useState } from "react";
import type { State } from "../api.ts";
import Charts from "../history/Charts.tsx";

// The History section under the board — collapsed by default; the charts
// (burn, model mix, projects, rhythm, value) live in history/Charts.tsx.
export function History(props: {
  state: State;
  fixturesMode: boolean;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(props.defaultOpen ?? false);

  return (
    <section aria-label="History" className="border-t border-hair">
      <button
        aria-expanded={open}
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-2 px-4 py-2.5 text-left text-[11.5px] font-semibold text-sec hover:text-text"
      >
        <span className="text-[9px]">{open ? "▼" : "▶"}</span>
        History
      </button>
      {open && <Charts state={props.state} fixturesMode={props.fixturesMode} />}
    </section>
  );
}
