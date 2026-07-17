// Shared 24h axis on top of every lane — hour ticks, labels every 2h, right
// cap "24h · local".
import { HEADER_PX, toPx } from "./geometry.ts";

export default function Axis() {
  // 0..22 only: the right cap IS the 24h marker — a "24" label at the
  // board's clipped right edge collided with it ("24h · local 2").
  const hours = Array.from({ length: 12 }, (_, i) => i * 2);
  const ticks = Array.from({ length: 25 }, (_, i) => i);
  return (
    <div className="relative h-[30px] border-b border-hair">
      {ticks.map((h) => (
        <div
          key={h}
          className="absolute bottom-0 h-[5px] w-px bg-hair"
          style={{ left: HEADER_PX + toPx(h * 60) }}
        />
      ))}
      {hours.map((h) => (
        <div
          key={h}
          className="absolute top-[9px] -translate-x-1/2 text-[9.5px] text-ter"
          style={{ left: HEADER_PX + toPx(h * 60) }}
        >
          {String(h).padStart(2, "0")}
        </div>
      ))}
      <div className="absolute right-2 top-[9px] text-[9.5px] text-ter">24h · local</div>
    </div>
  );
}
