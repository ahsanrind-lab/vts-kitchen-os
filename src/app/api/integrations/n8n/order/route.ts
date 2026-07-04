import { NextResponse } from 'next/server';
import { verifyN8nSecret, vtsIdentity } from '@/lib/vts/n8n-auth';
import { supabaseAdmin, ensureConversation } from '@/lib/vts/supabase-admin';

/**
 * VTS Kitchen OS — order ingest (idempotent upsert on order_ref).
 * n8n posts the finalized order object after Format Order / Normalize Payment.
 * Also raises a ringing 'new_order' alert on first insert.
 */
export async function POST(req: Request) {
  if (!verifyN8nSecret(req)) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  let p: any;
  try { p = await req.json(); } catch { return NextResponse.json({ error: 'bad json' }, { status: 400 }); }
  const orderRef = String(p.order_id ?? '').trim();
  const phone = String(p.phone ?? '').replace(/\D/g, '');
  if (!orderRef || !phone) return NextResponse.json({ error: 'order_id and phone required' }, { status: 400 });

  const db = supabaseAdmin();
  const { userId, accountId } = vtsIdentity();
  const { contactId, conversationId } = await ensureConversation(db, userId, phone, p.name);

  const { data: existing } = await db.from('vts_orders')
    .select('id').eq('order_ref', orderRef).maybeSingle();

  const row = {
    account_id: accountId,
    order_ref: orderRef,
    phone,
    customer_name: p.name ?? null,
    branch_id: p.branch_id ?? null,
    branch_name: p.branch ?? p.branch_name ?? null,
    area: p.area ?? null,
    address: p.address ?? null,
    items: Array.isArray(p.stripe_lines) ? p.stripe_lines : [],
    deal_label: p.deal_name ?? null,
    subtotal: Number(p.subtotal ?? 0) || Math.max(0, Number(p.total ?? 0) - Number(p.delivery_fee ?? 0)),
    delivery_fee: Number(p.delivery_fee ?? 0),
    total: Number(p.total ?? 0),
    payment_method: p.payment_method ?? null,
    payment_mode: p.payment_mode ?? null,
    payment_status: p.payment_status ?? null,
    status: p.status === 'awaiting_payment' ? 'awaiting_payment' : 'pending',
    notes: p.notes ?? null,
    contact_id: contactId,
    conversation_id: conversationId,
  };

  const { error } = await db.from('vts_orders').upsert(row, { onConflict: 'order_ref' });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  if (!existing) {
    await db.from('vts_alerts').insert({
      account_id: accountId,
      type: 'new_order',
      conversation_id: conversationId,
      order_ref: orderRef,
      phone,
      title: `🍕 NEW ORDER ${orderRef} — Rs.${row.total}`,
      body: `${row.deal_label ?? ''} | ${row.area ?? ''} | ${row.payment_method ?? ''}`.slice(0, 500),
    });
  }
  return NextResponse.json({ ok: true, order_ref: orderRef, created: !existing });
}
