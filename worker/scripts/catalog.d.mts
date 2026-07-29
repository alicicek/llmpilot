import type { ExecResult } from "./stripe-identity.d.mts";

export interface CatalogProduct {
  /** Ladder rung (catalog vocabulary — session rungs differ: discount_trial/nocard_trial). */
  rung: "full" | "discount" | "launch";
  /** Buyer-visible Product name (checkout line item + receipt under MP). */
  name: string;
  /** GBP base amount, minor units. */
  gbp: number;
  /** USD pinned currency option, minor units. */
  usd: number;
}

/** Stripe CLI argv creating one rung's Price; `--live` selects the key mode.
 *  Both currencies are created tax-inclusive; currency_options is expanded
 *  so the response can prove it. */
export declare function priceArgs(
  product: CatalogProduct,
  live?: boolean,
): string[];

/** Compare a returned Price against the rung's terms; empty array = proven. */
export declare function verifyPriceTerms(
  price: unknown,
  product: CatalogProduct,
): string[];

export interface CatalogPlan {
  live: boolean;
  apply: boolean;
  products: CatalogProduct[];
}

/** Parse CLI argv into a validated plan. Throws on the `--only <rung>` space
 *  form, an unknown rung, or any unknown argument. */
export declare function planFromArgv(argv: string[]): CatalogPlan;

/** The CLI body; returns the process exit code. May throw (invalid argv,
 *  identity refusal). Deps are injectable for tests only. */
export declare function runCatalog(
  argv: string[],
  deps?: {
    spawn?: (args: string[]) => ExecResult;
    assertIdentity?: (options: { live: boolean }) => { account: string; livemode: boolean };
    log?: (line: string) => void;
    warn?: (line: string) => void;
  },
): number;
