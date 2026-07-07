import { NextResponse } from 'next/server';
// ADJUST IMPORT to your fork's server-client factory (src/lib/supabase/server.ts).
import { createClient } from '@/lib/supabase/server';
import { supabaseAdmin } from '@/lib/vts/supabase-admin';

/**
 * VTS Kitchen OS — agent-facing bot toggle ("Take over" / "Give back to bot").
 *
 * ORDER OF OPERATIONS IS THE WHOLE POINT:
 *   1. Tell n8n (the source of truth: Redis human:<phone> flag).
 *   2. ONLY on n8n 200 -> update conversations.vts_bot_enabled.
 * If n8n is unreachable we return 502 and change NOTHING, so the UI
 * can never show "bot silenced" while the bot is actually still talking.
 *
 * POST { conversationId: string, phone: string, enable: boolean }
 */
export async function POST(req: Request) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let p: any;
  try { p = await req.json(); } catch { return NextResponse.json({ error: 'bad json' }, { status: 400 }); }
  const phone = String(p.phone ?? '').replace(/\D/g, '');
  const conversationId = String(p.conversationId ?? '');
  const enable = Boolean(p.enable);
  if (!phone || !conversationId) return NextResponse.json({ error: 'phone and conversationId required' }, { status: 400 });

  // RLS check: can this agent see this conversation? (user-scoped client)
  const { data: convo } = await supabase.from('conversations').select('id').eq('id', conversationId).maybeSingle();
  if (!convo) return NextResponse.json({ error: 'conversation not found' }, { status: 404 });

  // 1) n8n control webhook — the ONLY writer of the Redis human-mode flag.
  const ctrl = await fetch(process.env.VTS_N8N_CONTROL_URL!, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-VTS-Secret': process.env.VTS_N8N_SECRET! },
    body: JSON.stringify({ action: enable ? 'resume' : 'takeover', phone, agent: user.email ?? user.id }),
    signal: AbortSignal.timeout(8000),
  }).catch(() => null);
  if (!ctrl || !ctrl.ok) {
    return NextResponse.json({ error: 'Bot engine unreachable — state NOT changed. Try again.' }, { status: 502 });
  }

  // 2) Mirror into wacrm (service-role: column is machine-owned state).
  const db = supabaseAdmin();
  await db.from('conversations').update({
    vts_bot_enabled: enable,
    vts_handoff_at: enable ? null : new Date().toISOString(),
  }).eq('id', conversationId);

  // Auto-acknowledge any pending handoff alert when an agent takes over.
  if (!enable) {
    await db.from('vts_alerts')
      .update({ status: 'acknowledged', acked_by: user.id, acked_at: new Date().toISOString() })
      .eq('conversation_id', conversationId).eq('type', 'handoff').eq('status', 'pending');
  }
  return NextResponse.json({ ok: true, vts_bot_enabled: enable });
}
