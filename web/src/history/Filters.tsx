import { DropdownMenu } from "radix-ui";
import { RANGE_DAYS, type Range } from "./format.ts";

const RANGE_TABS: { key: Range; label: string }[] = [
  { key: "today", label: "Today" },
  { key: "7d", label: "7d" },
  { key: "30d", label: "30d" },
  { key: "1y", label: "1y" },
];

// One filter row above every chart it scopes (dataviz interaction spec):
// date range first, then a dimension filter. Standard HTML controls styled
// to the pack's chrome, not chart marks.
export function FiltersRow(props: {
  range: Range;
  onRangeChange: (r: Range) => void;
  accountOptions: { id: string; label: string }[];
  selected: Set<string>;
  onToggle: (id: string) => void;
  onSelectAll: () => void;
}) {
  const allSelected = props.selected.size === props.accountOptions.length;
  const accountsLabel =
    props.selected.size === 0
      ? "no accounts"
      : allSelected
        ? "all accounts"
        : `${props.selected.size} of ${props.accountOptions.length} accounts`;

  return (
    <div className="flex items-center gap-2.5 px-4 pt-3">
      <div role="radiogroup" aria-label="Date range" className="flex rounded-md border border-hair p-0.5">
        {RANGE_TABS.map((t) => (
          <button
            key={t.key}
            role="radio"
            aria-checked={props.range === t.key}
            onClick={() => props.onRangeChange(t.key)}
            className={`rounded-[5px] px-2.5 py-1 text-[11px] font-medium transition-colors duration-150 ${
              props.range === t.key ? "bg-acc-tx text-white dark:bg-accent" : "text-sec hover:text-text"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button className="rounded-md border border-hair px-2.5 py-1 text-[11px] text-sec hover:text-text">
            {accountsLabel}
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="start"
            sideOffset={6}
            className="min-w-[180px] rounded-lg border border-hair bg-win p-1 shadow-window"
          >
            <DropdownMenu.Label className="px-2.5 py-1 text-[9px] font-bold tracking-[0.07em] text-ter">
              ACCOUNTS
            </DropdownMenu.Label>
            {props.accountOptions.map((a) => (
              <DropdownMenu.CheckboxItem
                key={a.id}
                checked={props.selected.has(a.id)}
                onSelect={(e) => e.preventDefault()}
                onCheckedChange={() => props.onToggle(a.id)}
                className="flex cursor-default items-center gap-1.5 rounded-md px-2.5 py-1.5 text-[12px] outline-none data-highlighted:bg-panel"
              >
                <span className="inline-block w-[13px] text-accent" aria-hidden>
                  <DropdownMenu.ItemIndicator>✓</DropdownMenu.ItemIndicator>
                </span>
                {a.label}
              </DropdownMenu.CheckboxItem>
            ))}
            <DropdownMenu.Separator className="my-1 h-px bg-hairsoft" />
            <DropdownMenu.Item
              onSelect={(e) => {
                e.preventDefault();
                props.onSelectAll();
              }}
              className="cursor-default rounded-md px-2.5 py-1.5 text-[11.5px] text-sec outline-none data-highlighted:bg-panel"
            >
              Select all
            </DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    </div>
  );
}

export { RANGE_DAYS };
