// Ed25519 entitlement tokens. The signed JSON has exactly the public contract
// consumed by the app; license identifiers and timestamps stay outside it.

export type EntitlementKind = "TRIAL" | "LIFETIME";

export interface EntitlementPayload {
  tier: "pro";
  features: string[];
  seats: number;
  kind: EntitlementKind;
  // install binds the token to one machine's random install id; the app
  // verifier refuses a mismatch, so a copied Keychain item is inert.
  install: string;
  // issued_at is the signed freshness anchor for the app's offline-grace
  // window; validate re-signs with a fresh one on every call.
  issued_at: string;
  expires_at: string | null;
  key_id: string;
}

export const PRO_FEATURES = ["autopilot", "scheduling", "wake"];
export const TRIAL_GRACE_MS = 72 * 60 * 60 * 1000;

const te = new TextEncoder();

export function b64urlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function importSigningKey(pkcs8b64: string): Promise<CryptoKey> {
  const der = b64urlDecode(pkcs8b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
  return crypto.subtle.importKey("pkcs8", der.buffer as ArrayBuffer, "Ed25519", false, ["sign"]);
}

export async function importVerifyKey(rawB64: string): Promise<CryptoKey> {
  const raw = b64urlDecode(rawB64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
  return crypto.subtle.importKey("raw", raw.buffer as ArrayBuffer, "Ed25519", false, ["verify"]);
}

export async function signEntitlement(key: CryptoKey, payload: EntitlementPayload): Promise<string> {
  const body = b64urlEncode(te.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("Ed25519", key, te.encode(body));
  return `LLMP2.${body}.${b64urlEncode(new Uint8Array(sig))}`;
}

export async function verifyEntitlement(
  keys: ReadonlyMap<string, CryptoKey>,
  token: string,
): Promise<EntitlementPayload | null> {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== "LLMP2") return null;
  let payload: EntitlementPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1]))) as EntitlementPayload;
  } catch {
    return null;
  }
  const exact = ["expires_at", "features", "install", "issued_at", "key_id", "kind", "seats", "tier"];
  if (Object.keys(payload).sort().join(",") !== exact.join(",")) return null;
  const key = keys.get(payload.key_id);
  if (!key) return null;
  const ok = await crypto.subtle.verify(
    "Ed25519",
    key,
    b64urlDecode(parts[2]).buffer as ArrayBuffer,
    te.encode(parts[1]),
  );
  return ok ? payload : null;
}

export function lifetimePayload(keyId: string, install: string, issuedAt: Date): EntitlementPayload {
  return {
    tier: "pro",
    features: [...PRO_FEATURES],
    seats: 1,
    kind: "LIFETIME",
    install,
    issued_at: issuedAt.toISOString(),
    expires_at: null,
    key_id: keyId,
  };
}

export function trialPayload(keyId: string, trialEnd: Date, install: string, issuedAt: Date): EntitlementPayload {
  return {
    ...lifetimePayload(keyId, install, issuedAt),
    kind: "TRIAL",
    expires_at: new Date(trialEnd.getTime() + TRIAL_GRACE_MS).toISOString(),
  };
}
