import { timingSafeEqual } from 'node:crypto';

/**
 * VTS Kitchen OS — shared-secret auth for the n8n ingest routes.
 * n8n sends header  X-VTS-Secret: <VTS_N8N_SECRET> .
 * Fail-closed: if the env var is unset, every request is rejected.
 */
export function verifyN8nSecret(req: Request): boolean {
  const expected = process.env.VTS_N8N_SECRET ?? '';
  const got = req.headers.get('x-vts-secret') ?? '';
  if (!expected || !got) return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(got);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Owner identity under which machine-written rows are stored. */
export function vtsIdentity() {
  const userId = process.env.VTS_OWNER_USER_ID;
  const accountId = process.env.VTS_ACCOUNT_ID;
  if (!userId || !accountId) throw new Error('VTS_OWNER_USER_ID / VTS_ACCOUNT_ID not configured');
  return { userId, accountId };
}
