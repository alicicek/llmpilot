import type { State } from "../api.ts";
import type { Schedule } from "../schedule.ts";

// THE FLEET BOARD CONTRACT — every board implementation exports
//   export default function Board(props: BoardProps): ReactNode
// from web/src/board/Board.tsx and renders ONLY from these props (no
// fetching inside; the shell owns transport). Selection/inspector state is
// board-internal. All times are minutes-since-local-midnight on a shared
// 24h clock; the inspector is CONTEXTUAL (hidden until a reset is
// selected; Esc or click-away closes it).
export interface BoardProps {
  state: State;
  schedules: Schedule[];
  /** minutes since local midnight, ticking (the now-line + past wash). */
  nowMinutes: number;
  onSwitch: (accountId: string) => Promise<void>;
  onCreate: (input: { account_id: string; hour: number; minute: number }) => Promise<void>;
  onMove: (id: string, hour: number, minute: number) => Promise<void>;
  onDelete: (id: string) => Promise<void>;
}
