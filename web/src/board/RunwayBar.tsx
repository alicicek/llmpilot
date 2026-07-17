// One row per usage bucket in the lane header: label · 8px bar · "N% ·
// resets HH:MM". Color by server severity else percent — the reserved
// status trio (calm/warn/crit), never decorative. Stale snapshots drain to
// gray (pack rule 5): data the daemon can't vouch for drops its meaning
// color, it doesn't borrow a wrong one.
import type { Bucket } from "../api.ts";
import { bucketLabel, bucketSeverity, fmtDowFromIso, fmtHMFromIso, isSameDay, type Severity } from "./severity.ts";

const FILL: Record<Severity, string> = {
  calm: "bg-ter",
  warn: "bg-warnraw",
  crit: "bg-crit",
};

export interface RunwayBarProps {
  bucket: Bucket;
  refIso: string;
  stale: boolean;
}

export default function RunwayBar({ bucket, refIso, stale }: RunwayBarProps) {
  const sev = bucketSeverity(bucket);
  const fill = stale ? "bg-ter" : FILL[sev];
  const resetText = bucket.resets_at
    ? isSameDay(bucket.resets_at, refIso)
      ? `resets ${fmtHMFromIso(bucket.resets_at)}`
      : `resets ${fmtDowFromIso(bucket.resets_at)} ${fmtHMFromIso(bucket.resets_at)}`
    : null;

  return (
    <div className="mt-[5px] flex items-center gap-[7px]">
      <span className="w-[15px] shrink-0 text-[9px] font-semibold text-ter">{bucketLabel(bucket)}</span>
      <span className="h-2 flex-1 overflow-hidden rounded-sm bg-hairsoft">
        <span
          className={`block h-full rounded-sm ${fill} ${stale ? "opacity-40" : ""}`}
          style={{ width: `${Math.min(100, Math.max(0, bucket.percent))}%` }}
        />
      </span>
      <span className="w-[104px] shrink-0 text-right text-[9.5px] text-ter">
        {bucket.percent}% {resetText ? `· ${resetText}` : ""}
      </span>
    </div>
  );
}
