import { useState } from "react";
import { ShellDialog } from "./dialog.tsx";

// `claude auth login` is an interactive browser OAuth flow that needs a real
// terminal — the honest move is a clean handoff, not a broken in-app wrapper
// (UX grill outcome 7, 2026-07-10).
export function AddAccountDialog(props: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const [copied, setCopied] = useState(false);
  const cmd = "llmpilot account add";

  return (
    <ShellDialog open={props.open} onOpenChange={props.onOpenChange} title="Add account">
      <p className="text-[12px] leading-relaxed text-sec">
        Signing in happens in your terminal — Claude's login opens a browser and needs a
        real shell. Run this, sign in, and the new account appears here on its own:
      </p>
      <div className="flex items-center gap-2 rounded-lg border border-hairsoft bg-panel px-3 py-2">
        <code className="flex-1 text-[12px] font-semibold">{cmd}</code>
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
      <p className="text-[11px] leading-relaxed text-ter">
        First read of a new account triggers one macOS Keychain prompt — choose
        "Always Allow" so the daemon can keep watching it unattended.
      </p>
    </ShellDialog>
  );
}
