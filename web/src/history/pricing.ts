// Pinned API price table — per MTok USD, as-of 2026-06-24 (Anthropic model
// catalog via the claude-api skill cache; re-verify before release).
// Cache pricing rule: write = 1.25× input, read = 0.1× input (5-min TTL).
// Matching is by model-id prefix, longest first; unknown models are counted
// as UNPRICED and surfaced honestly, never silently priced.
export const PRICES_AS_OF = "2026-06-24";

interface Price {
  input: number;
  output: number;
}

const TABLE: [prefix: string, price: Price][] = [
  ["claude-fable-5", { input: 10, output: 50 }],
  ["claude-mythos-5", { input: 10, output: 50 }],
  ["claude-opus", { input: 5, output: 25 }],
  ["claude-sonnet", { input: 3, output: 15 }],
  ["claude-haiku", { input: 1, output: 5 }],
  ["claude-3-5-haiku", { input: 1, output: 5 }],
];

export function priceFor(modelID: string): Price | null {
  for (const [prefix, price] of TABLE) {
    if (modelID.startsWith(prefix)) return price;
  }
  return null;
}

export interface TokenCounts {
  input: number;
  output: number;
  cache_creation: number;
  cache_read: number;
}

// API-equivalent dollars for one cell; null when the model is unpriced.
export function valueOf(modelID: string, t: TokenCounts): number | null {
  const p = priceFor(modelID);
  if (!p) return null;
  const M = 1_000_000;
  return (
    (t.input / M) * p.input +
    (t.output / M) * p.output +
    (t.cache_creation / M) * p.input * 1.25 +
    (t.cache_read / M) * p.input * 0.1
  );
}
