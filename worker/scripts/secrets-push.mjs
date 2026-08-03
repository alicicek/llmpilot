#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Stripe credentials are vaulted per key-mode (test-* now, live-* at go-live),
// matching worker/.dev.vars.template and the ENVIRONMENT split in wrangler.jsonc.
// Default to the TEST keys; pass --live to push the production keys.
const mode = process.argv.includes("--live") ? "live" : "test";

const refs = {
  STRIPE_SECRET_KEY: `op://llmpilot/stripe/${mode}-secret-key`,
  STRIPE_WEBHOOK_SECRET: `op://llmpilot/stripe/${mode}-webhook-secret`,
  STRIPE_PUBLISHABLE_KEY: `op://llmpilot/stripe/${mode}-publishable-key`,
  ENT_SIGNING_KEY: "op://llmpilot/entitlement/signing-key",
  ENT_SIGNING_KEY_ID: "op://llmpilot/entitlement/signing-key-id",
  PRICE_FULL: `op://llmpilot/stripe/${mode}-price-full`,
  PRICE_DISCOUNT: `op://llmpilot/stripe/${mode}-price-discount`,
  RESEND_API_KEY: "op://llmpilot/resend/api-key",
};

const apply = process.argv.includes("--apply");
if (!apply) {
  console.log(JSON.stringify({ dryRun: true, keyMode: mode, secretNames: Object.keys(refs) }));
  process.exit(0);
}

function readVaultField(ref) {
  const read = spawnSync("op", ["read", ref], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
  if (read.status !== 0) process.exit(read.status ?? 1);
  const value = read.stdout.trim();
  if (!value || /[\r\n"']/.test(value)) throw new Error("vault field failed structural validation");
  return value;
}

const payload = {};
for (const [name, ref] of Object.entries(refs)) {
  payload[name] = readVaultField(ref);
}
const dir = mkdtempSync(join(tmpdir(), "llmpilot-secrets-"));
const file = join(dir, "secrets.json");
try {
  writeFileSync(file, JSON.stringify(payload), { mode: 0o600 });
  chmodSync(file, 0o600);
  // Uses the active wrangler auth (OAuth login or a CLOUDFLARE_API_TOKEN in the
  // environment); the worker name + account come from wrangler.jsonc. The temp
  // file is 0600 and removed in the finally below; secret VALUES are never logged.
  const push = spawnSync("npx", ["wrangler", "secret", "bulk", file], { stdio: "inherit" });
  process.exitCode = push.status ?? 1;
} finally {
  rmSync(dir, { recursive: true, force: true });
}
