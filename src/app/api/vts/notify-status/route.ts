import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { callControl } from '@/lib/vts/control';

/**
 * VTS Kitchen OS — order-status WhatsApp notification.
 *
 * Fired by the Orders board after a status change. Routes through the
 * n8n VTS Control workflow, which sends the SAME customer message the
 * staff-command path (`UPDATE <ref> <status>`) uses, keeps the Google
 * Sheet order row in sync, and mirrors the outbound message into the
 * CRM inbox. The CRM never talks to Meta directly for this — one
 * sender (n8n) means one delivery pipeline, one wording, one history.
 *
 * POST { order_ref, phone, status } → { ok }
 */

const NOTIFIABLE = new Set(['preparing', 'dispatched', 'delivered', 'cancelled']);

export async function POST(req: Request) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });

  let p: { order_ref?: string; phone?: string; status?: string };
  try {
    p = await req.json();
  } catch {
    return NextResponse.json({ error: 'bad json' }, { status: 400 });
  }

  const order_ref = String(p.order_ref ?? '').trim();
  const phone = String(p.phone ?? '').replace(/\D/g, '');
  const status = String(p.status ?? '').toLowerCase();

  if (!order_ref || phone.length < 10 || !NOTIFIABLE.has(status)) {
    return NextResponse.json({ error: 'order_ref, phone, and a notifiable status required' }, { status: 400 });
  }

  // Verify the order actually exists and belongs to this account (RLS
  // scopes the read) — the notify endpoint must not be usable as a
  // free-form WhatsApp sender.
  const { data: order } = await supabase
    .from('vts_orders')
    .select('id, phone, order_ref')
    .eq('order_ref', order_ref)
    .maybeSingle();
  if (!order || String(order.phone).replace(/\D/g, '') !== phone) {
    return NextResponse.json({ error: 'order not found' }, { status: 404 });
  }

  const r = await callControl({ action: 'order_status', order_ref, phone, status });
  if (!r.ok) return NextResponse.json({ error: 'notify failed', detail: r.body }, { status: 502 });
  return NextResponse.json({ ok: true });
}
