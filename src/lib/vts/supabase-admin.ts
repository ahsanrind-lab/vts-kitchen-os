import { createClient, SupabaseClient } from '@supabase/supabase-js';

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
 * Find-or-create the contact + open conversation for a phone number,
 * mirroring the shapes wacrm's own webhook creates (001_initial_schema).
 */
export async function ensureConversation(
  db: SupabaseClient, userId: string, phone: string, name?: string,
): Promise<{ contactId: string; conversationId: string }> {
  let { data: contact } = await db.from('contacts')
    .select('id').eq('user_id', userId).eq('phone', phone).maybeSingle();
  if (!contact) {
    const { data, error } = await db.from('contacts')
      .insert({ user_id: userId, phone, name: name ?? null })
      .select('id').single();
    if (error) throw error;
    contact = data;
  }
  let { data: convo } = await db.from('conversations')
    .select('id').eq('user_id', userId).eq('contact_id', contact.id)
    .neq('status', 'closed').order('created_at', { ascending: false })
    .limit(1).maybeSingle();
  if (!convo) {
    const { data, error } = await db.from('conversations')
      .insert({ user_id: userId, contact_id: contact.id, status: 'open' })
      .select('id').single();
    if (error) throw error;
    convo = data;
  }
  return { contactId: contact.id, conversationId: convo.id };
}
