// Seat accounting over the activations table. A seat is one (license,
// install) pair; the cap bounds how many distinct Macs hold a usable token.

import type { WorkerEnv } from "../env.ts";

export const DEFAULT_SEAT_LIMIT = 4;

// The daemon mints install ids as UUIDv4; anything else is refused at the
// boundary so the table only ever holds well-formed identifiers.
const INSTALL_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export function validInstallID(v: unknown): v is string {
  return typeof v === "string" && INSTALL_SHAPE.test(v);
}

export function seatLimit(env: WorkerEnv): number {
  const n = Number(env.SEAT_LIMIT);
  return Number.isInteger(n) && n > 0 ? n : DEFAULT_SEAT_LIMIT;
}

export async function seatExists(db: D1Database, licenseId: string, installId: string): Promise<boolean> {
  const row = await db
    .prepare("SELECT 1 AS one FROM activations WHERE license_id = ? AND install_id = ?")
    .bind(licenseId, installId)
    .first();
  return row !== null;
}

/** Occupy or refresh one seat; the upsert makes fulfillment replays free. */
export async function recordSeat(db: D1Database, licenseId: string, installId: string, now: Date): Promise<void> {
  const iso = now.toISOString();
  await db
    .prepare(
      `INSERT INTO activations (license_id, install_id, created_at, last_seen) VALUES (?, ?, ?, ?)
       ON CONFLICT (license_id, install_id) DO UPDATE SET last_seen = excluded.last_seen`,
    )
    .bind(licenseId, installId, iso, iso)
    .run();
}

/** Seat this install iff it already holds a seat OR the license is under the
 *  cap — as ONE statement, so concurrent activations can't each read a stale
 *  sub-cap count and overshoot (D1 gives no cross-statement transaction; a
 *  single INSERT…SELECT takes the write lock, serializing the count check).
 *  Returns true when the seat is present afterward, false when the cap
 *  refused a new install. */
export async function seatUnderCap(
  db: D1Database,
  licenseId: string,
  installId: string,
  limit: number,
  now: Date,
): Promise<boolean> {
  const iso = now.toISOString();
  const res = await db
    .prepare(
      `INSERT INTO activations (license_id, install_id, created_at, last_seen)
       SELECT ?1, ?2, ?3, ?3
       WHERE (SELECT COUNT(*) FROM activations WHERE license_id = ?1) < ?4
          OR EXISTS (SELECT 1 FROM activations WHERE license_id = ?1 AND install_id = ?2)
       ON CONFLICT (license_id, install_id) DO UPDATE SET last_seen = excluded.last_seen`,
    )
    .bind(licenseId, installId, iso, limit)
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

/** Trim a license's activations to the newest `limit` seats by last_seen,
 *  deleting the oldest beyond the cap. Run AFTER seating the recovery claimer
 *  (which holds the freshest last_seen, so it always survives the trim), it is
 *  the atomic replacement for check-count-then-evict: concurrent recovery
 *  claims can no longer over-evict or land at cap+1, because each claim just
 *  converges the table to "the newest `limit` installs" in one statement — no
 *  cross-statement transaction needed. Proof of email ownership is what
 *  authorizes bumping a Mac remotely; the trimmed install's validates start
 *  refusing, so its token ages out within one grace window. */
export async function trimSeatsToCap(db: D1Database, licenseId: string, limit: number): Promise<void> {
  await db
    .prepare(
      `DELETE FROM activations
       WHERE license_id = ?1
         AND install_id NOT IN (
           SELECT install_id FROM activations WHERE license_id = ?1
           ORDER BY last_seen DESC, install_id DESC LIMIT ?2
         )`,
    )
    .bind(licenseId, limit)
    .run();
}
