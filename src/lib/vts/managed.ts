/**
 * VTS Kitchen OS — deployment invariants.
 *
 * RULE 0: n8n owns the Meta webhook. The bot (workflow gppIrpdPfxmGqeAB
 * on n8n.vintagetechsolutions.tech) receives every WhatsApp event and
 * mirrors them into this CRM via Taps A–D. This CRM must NEVER
 * register/verify the phone number with Meta — a successful /register
 * or webhook re-subscription from here would redirect inbound events
 * away from the bot and take live ordering DOWN.
 *
 * This is a hardcoded constant (not an env var) on purpose: an env
 * misconfiguration must not be able to re-arm the buttons.
 */
export const VTS_MANAGED_WEBHOOK = true

export const VTS_MANAGED_WEBHOOK_NOTE =
  'Managed by n8n — do not re-verify. WhatsApp events are received by the ' +
  'n8n ordering bot and mirrored into this CRM. Registering or verifying ' +
  'this number from here would disconnect the bot and stop live orders.'
