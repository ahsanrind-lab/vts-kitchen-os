import { NextResponse } from 'next/server';
import { verifyN8nSecret, vtsIdentity } from '@/lib/vts/n8n-auth';
import { supabaseAdmin, ensureConversation } from '@/lib/vts/supabase-admin';

/**
 * VTS Kitchen OS — outbound-message mirror.
 * n8n calls this right after the bot sends a WhatsApp reply so the
 * Shared Inbox shows the bot's side of the conversation in real time.
 *
 * POST { phone: string, text: string, wamid?: string,
 *        sender_type?: 'bot' | 'agent', name?: string }
 */
export async function POST(req: Request) {
  if (!verifyN8nSecret(req)) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  let p: any;
  try { p = await req.json(); } catch { return NextResponse.json({ error: 'bad json' }, { status: 400 }); }
  const phone = String(p.phone ?? '').replace(/\D/g, '');
  const text = String(p.text ?? '').slice(0, 4096);
  if (!phone || !text) return NextResponse.json({ error: 'phone and text required' }, { status: 400 });

  const db = supabaseAdmin();
  const { userId } = vtsIdentity();

  // Idempotency: same wamid mirrored twice -> no duplicate row.
  if (p.wamid) {
    const { data: dup } = await db.from('messages')
      .select('id').eq('message_id', String(p.wamid)).maybeSingle();
    if (dup) return NextResponse.json({ ok: true, deduped: true });
  }

  const { conversationId } = await ensureConversation(db, userId, phone, p.name);
  const { error } = await db.from('messages').insert({
    conversation_id: conversationId,
    sender_type: p.sender_type === 'agent' ? 'agent' : 'bot',   // schema already supports 'bot'
    content_type: 'text',
    content_text: text,
    message_id: p.wamid ? String(p.wamid) : null,
    status: 'sent',
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  await db.from('conversations').update({
    last_message_text: text.slice(0, 200),
    last_message_at: new Date().toISOString(),
  }).eq('id', conversationId);

  return NextResponse.json({ ok: true, conversationId });
}
