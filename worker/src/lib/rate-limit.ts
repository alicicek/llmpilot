export async function sha256(value: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function takeRateLimit(
  db: D1Database,
  namespace: string,
  key: string,
  now: Date,
  limit: number,
  windowMs: number,
): Promise<boolean> {
  const keyHash = await sha256(`${namespace}:${key}`);
  const windowStart = new Date(Math.floor(now.getTime() / windowMs) * windowMs).toISOString();
  const row = await db.prepare(
    `INSERT INTO request_rate_limits (key_hash, window_start, attempts) VALUES (?, ?, 1)
     ON CONFLICT(key_hash, window_start) DO UPDATE SET attempts = attempts + 1
     RETURNING attempts`,
  ).bind(keyHash, windowStart).first<{ attempts: number }>();
  return (row?.attempts ?? limit + 1) <= limit;
}
