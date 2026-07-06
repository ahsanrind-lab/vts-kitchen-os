import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { findExistingContact, isUniqueViolation } from '@/lib/contacts/dedupe';

/** Service-role client for machine writes (n8n ingest). Server-only. */
let _admin: SupabaseClient | null = null;
export function supabaseAdmin(): SupabaseClient {
  if (_admin) return _admin;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY!;
  _admin = createClient(url, key, { auth: { persistSession: false } });
  return _admin;
}

/**
 * Find-or-create the contact + conversation for a phone number,
 * mirroring wacrm's own webhook (findOrCreateContact /
 * findOrCreateConversation in api/whatsapp/webhook): account_id is the
 * tenancy column (RLS: is_account_member), user_id is the NOT NULL
 * audit column. Phone matching goes through the shared dedupe helper
 * so this path and the webhook agree on what "same number" means, and
 * a lost insert race re-resolves via the 022 unique index instead of
 * dropping the event.
 */
export async function ensureConversation(
  db: SupabaseClient, accountId: string, userId: string, phone: string, name?: string,
): Promise<{ contactId: string; conversationId: string }> {
  let contact = await findExistingContact(db, accountId, phone);
  if (!contact) {
    const { data, error } = await db.from('contacts')
      .insert({ account_id: accountId, user_id: userId, phone, name: name || phone })
      .select().single();
    if (error) {
      if (isUniqueViolation(error)) contact = await findExistingContact(db, accountId, phone);
      if (!contact) throw error;
    } else {
      contact = data;
    }
  } else if (name && name !== contact.name) {
    await db.from('contacts')
      .update({ name, updated_at: new Date().toISOString() })
      .eq('id', contact.id);
  }
  if (!contact) throw new Error('contact resolution failed');
  let { data: convo } = await db.from('conversations')
    .select('id').eq('account_id', accountId).eq('contact_id', contact.id)
    .order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!convo) {
    const { data, error } = await db.from('conversations')
      .insert({ account_id: accountId, user_id: userId, contact_id: contact.id, status: 'open' })
      .select('id').single();
    if (error) throw error;
    convo = data;
  }
  return { contactId: contact.id, conversationId: convo.id };
}
