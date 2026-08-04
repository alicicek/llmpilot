// Component grammar #3 — one LANE: 240px header (geometry.HEADER_PX) +
// 1160px track, hairsoft row separator.
import type { AccountState } from "../api.ts";
import type { LaneSchedule, MidWindow } from "./classify.ts";
import LaneHeader from "./LaneHeader.tsx";
import Track from "./Track.tsx";

export interface LaneProps {
  account: AccountState;
  active: boolean;
  nowMinutes: number;
  schedules: LaneSchedule[];
  mid: MidWindow | null;
  selectedId: string | null;
  onSwitch: () => void;
  onSelect: (id: string | null) => void;
  onCreate: (hour: number, minute: number) => void;
  onMove: (id: string, hour: number, minute: number) => void;
  onDelete: (id: string) => void;
  canSchedule?: boolean;
}

export default function Lane({
  account,
  active,
  nowMinutes,
  schedules,
  mid,
  selectedId,
  onSwitch,
  onSelect,
  onCreate,
  onMove,
  onDelete,
  canSchedule,
}: LaneProps) {
  return (
    <div className="flex border-b border-hairsoft">
      <LaneHeader account={account} active={active} nowMinutes={nowMinutes} onSwitch={onSwitch} />
      <div className="relative w-[1160px]">
        <Track
          accountLabel={account.label}
          schedules={schedules}
          mid={mid}
          nowMinutes={nowMinutes}
          selectedId={selectedId}
          onSelect={onSelect}
          onCreate={onCreate}
          onMove={onMove}
          onDelete={onDelete}
          canSchedule={canSchedule}
        />
      </div>
    </div>
  );
}
