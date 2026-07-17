// Red now-line + time bubble spanning all lanes, past-time wash to its left.
import { HEADER_PX, toPx } from "./geometry.ts";
import { fmtHM } from "../schedule.ts";

export default function NowLine({ nowMinutes }: { nowMinutes: number }) {
  const left = HEADER_PX + toPx(nowMinutes);
  return (
    <>
      <div
        className="pointer-events-none absolute inset-y-0 top-[30px] bg-wash"
        style={{ left: HEADER_PX, width: toPx(nowMinutes) }}
      />
      <div className="pointer-events-none absolute inset-y-0 top-[14px] z-[7] w-[1.5px] bg-crit opacity-90" style={{ left }} />
      <div
        className="pointer-events-none absolute top-0 z-[8] -translate-x-1/2 whitespace-nowrap rounded-full bg-crit-deep px-[7px] py-px text-[9.5px] font-bold text-white"
        style={{ left }}
      >
        {fmtHM(nowMinutes)}
      </div>
    </>
  );
}
