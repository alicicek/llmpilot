// Stable per-account avatar color from an id hash. The pack reserves every
// named color for a meaning (blue=booked, green=guaranteed, amber=conditional,
// red=illegal, gray=assumption) — none are free for decorative identity — so
// identity color is a hue-rotate of the one legitimately decorative token
// (--accent) rather than a new hex swatch. Zero raw hex, five stable buckets.
import type { CSSProperties } from "react";

export function avatarStyle(id: string): CSSProperties {
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) >>> 0;
  const hue = (hash % 5) * 72;
  const sat = 85 + (hash % 3) * 15;
  return {
    background: "var(--accent)",
    filter: `hue-rotate(${hue}deg) saturate(${sat}%)`,
  };
}
