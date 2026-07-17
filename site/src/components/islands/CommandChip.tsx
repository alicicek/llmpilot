import * as React from "react";

/** The brew command shown verbatim with a copy affordance. Reused in the hero
 *  and the install block. No toast theater — an inline "Copied" state. */
export default function CommandChip({ command }: { command: string }) {
  const [copied, setCopied] = React.useState(false);
  const timer = React.useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      clearTimeout(timer.current);
      timer.current = setTimeout(() => setCopied(false), 1600);
    } catch {
      /* clipboard blocked — the command is visible to select by hand */
    }
  };

  React.useEffect(() => () => clearTimeout(timer.current), []);

  return (
    <div className="inline-flex items-stretch overflow-hidden rounded-md border border-hair bg-panel">
      <code
        className="px-3.5 py-2.5 text-text"
        style={{ fontSize: "var(--fs-mono)", fontVariantNumeric: "tabular-nums" }}
      >
        <span className="text-ter select-none">$ </span>
        {command}
      </code>
      <button
        type="button"
        onClick={copy}
        aria-label="Copy install command"
        className="border-l border-hair px-3.5 text-[13px] font-semibold text-acc-tx transition-colors duration-150 hover:bg-white/5"
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}
