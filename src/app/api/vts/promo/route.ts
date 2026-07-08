import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { callControl } from '@/lib/vts/control';

/**
 * VTS Kitchen OS — promo message (bot announcement).
 *
 * The n8n bot appends the announcement in `cache:announce` (Redis) to
 * its greeting reply. This route lets the owner manage it from the CRM.
 * Writes are PERSISTENT (no TTL), which makes the CRM authoritative:
 * the bot's Google-Sheet announcement refresh only runs on a Redis
 * cache miss, and a persistent key never misses. '-' is the bot's
 * "no announcement" sentinel.
 *
 * GET  → { ok, enabled, text }
 * POST { enabled: boolean, text?: string } → { ok }
 */

async function requireUser() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return user;
}

export async function GET() {
  const user = await requireUser();
  if (!user) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  const r = await callControl({ action: 'promo_get' });
  if (!r.ok) return NextResponse.json({ error: 'control unreachable', detail: r.body }, { status: 502 });
  return NextResponse.json(r.body);
}

export async function POST(req: Request) {
  const user = await requireUser();
  if (!user) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  let p: { enabled?: boolean; text?: string };
  try {
    p = await req.json();
  } catch {
    return NextResponse.json({ error: 'bad json' }, { status: 400 });
  }

  const enabled = !!p.enabled;
  const text = String(p.text ?? '').trim().slice(0, 400);
  if (enabled && !text) {
    return NextResponse.json({ error: 'text required when enabling' }, { status: 400 });
  }

  const r = await callControl(
    enabled ? { action: 'promo_set', text } : { action: 'promo_clear' },
  );
  if (!r.ok) return NextResponse.json({ error: 'control unreachable', detail: r.body }, { status: 502 });
  return NextResponse.json({ ok: true, enabled, text: enabled ? text : '' });
}
