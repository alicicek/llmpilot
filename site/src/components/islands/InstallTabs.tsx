import * as React from "react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "../ui/tabs";

/*
 * The tabbed install block. Every command is real and verifiable against the
 * shipped release tooling: the .app download is a GitHub release link, brew
 * and cask match the tap files release-local.sh publishes, and curl runs the
 * brew install via /install.sh served from this site.
 */
interface Target {
  id: string;
  label: string;
  command: string;
  note?: string;
}

const TARGETS: Target[] = [
  { id: "app", label: "Download .app", command: "", note: "Signed & notarized — from GitHub Releases." },
  { id: "brew", label: "brew", command: "brew install alicicek/tap/llmpilot", note: "The CLI + daemon." },
  { id: "cask", label: "cask", command: "brew install --cask alicicek/tap/llmpilot", note: "The menu bar app." },
  { id: "curl", label: "curl", command: "curl -fsSL https://llmpilot.dev/install.sh | sh", note: "Runs the brew install for you." },
];

const RELEASES = "https://github.com/alicicek/llmpilot/releases/latest";

function CopyRow({ command }: { command: string }) {
  const [copied, setCopied] = React.useState(false);
  const timer = React.useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  React.useEffect(() => () => clearTimeout(timer.current), []);
  return (
    <div className="flex items-stretch overflow-hidden rounded-md border border-hair bg-panel">
      <code
        className="flex-1 overflow-x-auto px-3.5 py-2.5 text-text"
        style={{ fontSize: "var(--fs-mono)", fontVariantNumeric: "tabular-nums" }}
      >
        <span className="text-ter select-none">$ </span>
        {command}
      </code>
      <button
        type="button"
        aria-label="Copy install command"
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(command);
            setCopied(true);
            clearTimeout(timer.current);
            timer.current = setTimeout(() => setCopied(false), 1600);
          } catch {
            /* clipboard blocked */
          }
        }}
        className="border-l border-hair px-3.5 text-[13px] font-semibold text-acc-tx transition-colors duration-150 hover:bg-white/5"
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

export default function InstallTabs() {
  return (
    <Tabs defaultValue="app" className="w-full max-w-xl">
      <TabsList>
        {TARGETS.map((t) => (
          <TabsTrigger key={t.id} value={t.id}>
            {t.label}
          </TabsTrigger>
        ))}
      </TabsList>
      {TARGETS.map((t) => (
        <TabsContent key={t.id} value={t.id}>
          {t.id === "app" ? (
            <a
              href={RELEASES}
              className="inline-flex h-11 items-center justify-center rounded-md bg-primary px-5 text-[14px] font-semibold text-primary-foreground transition-[filter] duration-150 hover:brightness-110"
            >
              Download for macOS
            </a>
          ) : (
            <CopyRow command={t.command} />
          )}
          {t.note ? <p className="mt-2 text-[13px] text-ter">{t.note}</p> : null}
        </TabsContent>
      ))}
    </Tabs>
  );
}
