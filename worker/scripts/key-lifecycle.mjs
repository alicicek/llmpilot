#!/usr/bin/env node
import { createHash, generateKeyPairSync } from "node:crypto";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const generate = process.argv.includes("--generate");
if (!generate) {
  console.log(JSON.stringify({
    mode: "dry-run",
    sequence: [
      "generate Ed25519 key locally",
      "store PKCS8 key and key id as concealed vault fields",
      "ship the new public key and key id in the app before switching minting",
      "push Worker secrets",
      "retain old public keys until every old entitlement has aged out",
    ],
  }));
  process.exit(0);
}

const out = process.env.KEY_OUTPUT_DIR || join(tmpdir(), `llmpilot-entitlement-${Date.now()}`);
mkdirSync(out, { recursive: true, mode: 0o700 });
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const publicRaw = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
const fingerprint = createHash("sha256").update(publicRaw).digest("hex").slice(0, 16);
const keyId = `ed25519-${new Date().toISOString().slice(0, 10)}-${fingerprint}`;
const privatePath = join(out, "signing-key.pkcs8.b64");
const publicPath = join(out, "public-key.json");
writeFileSync(privatePath, privateKey.export({ type: "pkcs8", format: "der" }).toString("base64") + "\n", { mode: 0o600 });
chmodSync(privatePath, 0o600);
writeFileSync(publicPath, JSON.stringify({ key_id: keyId, public_key: publicRaw.toString("base64") }, null, 2) + "\n", { mode: 0o600 });
console.log(JSON.stringify({ generated: true, directory: out, privateFile: "signing-key.pkcs8.b64", publicFile: "public-key.json", next: "move the private value into the concealed vault field, then securely delete this directory" }));
