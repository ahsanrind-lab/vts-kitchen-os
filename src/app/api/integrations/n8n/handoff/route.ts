import { NextResponse } from 'next/server';
import { verifyN8nSecret, vtsIdentity } from '@/lib/vts/n8n-auth';
import { supabaseAdmin, ensureConversation } from '@/lib/vts/supabase-admin';

/**
 * VTS Kitchen OS — handoff ingest.
 * n8n calls this when the bot escalates to a human (it has ALREADY set
 * its Redis human-mode flag; this mirrors state + raises the ringing alert).
 *
 * POST { phone: string, reason?: string, name?: string }
 */
export async function POST(req: Request) {
  if (!verifyN8nSecret(req)) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  let p: any;
  try { p = await req.json(); } catch { return NextResponse.json({ error: 'bad json' }, { status: 400 }); }
  const phone = String(p.phone ?? '').replace(/\D/g, '');
  if (!phone) return NextResponse.json({ error: 'phone required' }, { status: 400 });

  const db = supabaseAdmin();
  const { userId, accountId } = vtsIdentity();
  const { conversationId } = await ensureConversation(db, userId, phone, p.name);

  await db.from('conversations').update({
    vts_bot_enabled: false,
    vts_handoff_at: new Date().toISOString(),
    status: 'open',
  }).eq('id', conversationId);

  // Ring only once per open handoff: skip if a pending alert already exists.
  const { data: existing } = await db.from('vts_alerts')
    .select('id').eq('conversation_id', conversationId)
    .eq('type', 'handoff').eq('status', 'pending').maybeSingle();
  if (!existing) {
    const { error } = await db.from('vts_alerts').insert({
      account_id: accountId,
      type: 'handoff',
      conversation_id: conversationId,
      phone,
      title: `🙋 Customer needs a human — ${phone}`,
      body: String(p.reason ?? 'Bot escalated the conversation').slice(0, 500),
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, conversationId });
}
