/**
 * VTS Kitchen OS — caller for the n8n "VTS Control" webhook.
 *
 * The control workflow (separate from the bot; Rule 0 untouched) owns
 * every CRM→bot side effect: human-mode takeover/resume, the promo
 * announcement key, and customer order-status notifications. Auth is a
 * shared secret header, same convention as Taps A–D but in reverse.
 *
 * Env (server-only):
 *   VTS_N8N_CONTROL_URL  e.g. https://n8n.vintagetechsolutions.tech/webhook/vts-control
 *   VTS_N8N_SECRET       same value the n8n container holds
 */

export interface ControlPayload {
  action:
    | 'takeover'
    | 'resume'
    | 'promo_set'
    | 'promo_clear'
    | 'promo_get'
    | 'order_status'
  phone?: string
  agent?: string
  text?: string
  order_ref?: string
  status?: string
}

export async function callControl(
  payload: ControlPayload,
): Promise<{ ok: boolean; status: number; body: unknown }> {
  const url = process.env.VTS_N8N_CONTROL_URL
  const secret = process.env.VTS_N8N_SECRET
  if (!url || !secret) {
    return {
      ok: false,
      status: 500,
      body: { error: 'VTS_N8N_CONTROL_URL / VTS_N8N_SECRET not configured' },
    }
  }
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-VTS-Secret': secret },
      body: JSON.stringify(payload),
      // The control workflow answers in well under a second; a hung n8n
      // must not hold a CRM request open indefinitely.
      signal: AbortSignal.timeout(8000),
    })
    const body = await res.json().catch(() => null)
    return { ok: res.ok, status: res.status, body }
  } catch (err) {
    return {
      ok: false,
      status: 502,
      body: { error: err instanceof Error ? err.message : String(err) },
    }
  }
}
