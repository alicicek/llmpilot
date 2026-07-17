// THE ONE-PLACE FLEET BOARD — every account's schedule + status on a shared
// 24h axis, "BLOCK-MATERIAL" variant: a reset is the trailing edge of a
// rigid, visible-at-rest 5h charge block. See contract.ts for the props this
// renders from (no fetching here — the shell owns transport).
import { useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import type { BoardProps } from "./contract.ts";
import type { AccountState } from "../api.ts";
import { DAY_MIN, WINDOW_HOURS } from "../schedule.ts";
import { classify, laneSchedules, type ChipClass, type LaneSchedule, type MidWindow } from "./classify.ts";
import { minutesOfDay } from "./severity.ts";
import { useReducedMotion } from "./useReducedMotion.ts";
import Axis from "./Axis.tsx";
import NowLine from "./NowLine.tsx";
import Lane from "./Lane.tsx";
import Inspector from "./Inspector.tsx";

const WINDOW_MIN = WINDOW_HOURS * 60;

function midWindowFor(account: AccountState): MidWindow | null {
  const session = account.snapshot?.buckets.find((b) => b.kind === "session");
  if (!session?.active || !session.resets_at) return null;
  const end = minutesOfDay(session.resets_at);
  const start = (end - WINDOW_MIN + DAY_MIN) % DAY_MIN;
  return { start, end };
}

interface LaneData {
  account: AccountState;
  sched: LaneSchedule[];
  mid: MidWindow | null;
}

interface SelectedInfo {
  account: AccountState;
  ls: LaneSchedule;
  cls: ChipClass;
  mid: MidWindow | null;
  chainTarget: number | null;
}

function findSelected(lanes: LaneData[], selectedId: string | null, nowMinutes: number): SelectedInfo | null {
  if (!selectedId) return null;
  for (const { account, sched, mid } of lanes) {
    const idx = sched.findIndex((s) => s.schedule.id === selectedId);
    if (idx === -1) continue;
    const ls = sched[idx]!;
    return {
      account,
      ls,
      cls: classify(ls, nowMinutes, mid),
      mid,
      chainTarget: sched.length > 1 ? sched[(idx - 1 + sched.length) % sched.length]!.reset : null,
    };
  }
  return null;
}

export default function Board({ state, schedules, nowMinutes, onSwitch, onCreate, onMove, onDelete }: BoardProps) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const reducedMotion = useReducedMotion();

  if (state.accounts.length === 0) {
    return (
      <div className="p-8 text-[12.5px] text-ter">
        No accounts adopted yet — nothing here is scheduled.
      </div>
    );
  }

  const lanesData: LaneData[] = state.accounts.map((account) => ({
    account,
    sched: laneSchedules(schedules, account.id),
    mid: midWindowFor(account),
  }));

  const selected = findSelected(lanesData, selectedId, nowMinutes);

  return (
    <div className="relative w-[1368px] max-w-full overflow-hidden bg-win">
      <Axis />
      <div className="relative">
        {lanesData.map(({ account, sched, mid }) => (
          <Lane
            key={account.id}
            account={account}
            active={account.id === state.active_id}
            nowMinutes={nowMinutes}
            schedules={sched}
            mid={mid}
            selectedId={selectedId}
            onSwitch={() => void onSwitch(account.id)}
            onSelect={setSelectedId}
            onCreate={(hour, minute) => void onCreate({ account_id: account.id, hour, minute })}
            onMove={(id, hour, minute) => void onMove(id, hour, minute)}
            onDelete={(id) => {
              if (id === selectedId) setSelectedId(null);
              void onDelete(id);
            }}
          />
        ))}
      </div>
      <NowLine nowMinutes={nowMinutes} />

      <AnimatePresence>
        {selected && (
          <motion.div
            key="inspector"
            className="absolute inset-y-0 right-0 z-20"
            initial={{ x: "100%" }}
            animate={{ x: 0 }}
            exit={{ x: "100%" }}
            transition={{ duration: reducedMotion ? 0 : 0.2, ease: [0.4, 0, 0.2, 1] }}
          >
            <Inspector
              email={selected.account.email}
              ls={selected.ls}
              cls={selected.cls}
              mid={selected.mid}
              nowMinutes={nowMinutes}
              chainTarget={selected.chainTarget}
              onChain={() => {
                const t = selected.chainTarget;
                if (t == null) return;
                void onMove(selected.ls.schedule.id, Math.floor(t / 60), t % 60);
              }}
              onDelete={() => {
                void onDelete(selected.ls.schedule.id);
                setSelectedId(null);
              }}
              onClose={() => setSelectedId(null)}
            />
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
