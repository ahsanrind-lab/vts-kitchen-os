/**
 * VTS Kitchen OS — order domain helpers.
 *
 * `vts_orders` (migration 031) is written ONLY by n8n via
 * /api/integrations/n8n/order (service role). The UI reads it via RLS
 * (any account member) and updates `status` (agent+). This module is
 * the single source of truth for the status ladder and its labels so
 * the board, the dashboard, and any future surfaces agree.
 */

export type VtsOrderStatus =
  | 'awaiting_payment'
  | 'pending'
  | 'preparing'
  | 'dispatched'
  | 'delivered'
  | 'cancelled'

/**
 * Items arrive as the bot engine's `stripe_lines` array verbatim.
 * The engine is the source of truth for money — we render, never
 * recompute. Keys are defensive because the engine's line shape has
 * drifted before ("qty" vs "quantity").
 */
export interface VtsOrderItem {
  name?: string
  description?: string
  qty?: number
  quantity?: number
  /** Line amount in whole rupees (engine-computed). */
  amount?: number
  price?: number
  line_total?: number
}

export interface VtsOrder {
  id: string
  account_id: string
  order_ref: string
  phone: string
  customer_name: string | null
  branch_id: string | null
  branch_name: string | null
  area: string | null
  address: string | null
  items: VtsOrderItem[]
  deal_label: string | null
  subtotal: number
  delivery_fee: number
  total: number
  payment_method: string | null
  payment_mode: string | null
  payment_status: string | null
  status: VtsOrderStatus
  notes: string | null
  contact_id: string | null
  conversation_id: string | null
  created_at: string
  updated_at: string
}

/**
 * The kitchen board columns, in workflow order. `awaiting_payment`
 * rides in the "Received" column with a badge (it's a real order the
 * kitchen can see coming, but shouldn't fire until payment lands);
 * `cancelled` is hidden behind a filter.
 */
export const BOARD_COLUMNS: {
  key: Exclude<VtsOrderStatus, 'awaiting_payment' | 'cancelled'>
  label: string
}[] = [
  { key: 'pending', label: 'Received' },
  { key: 'preparing', label: 'Preparing' },
  { key: 'dispatched', label: 'Out for delivery' },
  { key: 'delivered', label: 'Delivered' },
]

/** Column an order renders in (awaiting_payment ⇒ Received). */
export function boardColumnFor(status: VtsOrderStatus): VtsOrderStatus | null {
  if (status === 'awaiting_payment') return 'pending'
  if (status === 'cancelled') return null
  return status
}

/** Forward-only advance map. Delivered and cancelled are terminal. */
export const NEXT_STATUS: Partial<Record<VtsOrderStatus, VtsOrderStatus>> = {
  awaiting_payment: 'pending',
  pending: 'preparing',
  preparing: 'dispatched',
  dispatched: 'delivered',
}

/** Big-button label for the advance action, per current status. */
export const NEXT_ACTION_LABEL: Partial<Record<VtsOrderStatus, string>> = {
  awaiting_payment: 'Payment received',
  pending: 'Start preparing',
  preparing: 'Send for delivery',
  dispatched: 'Mark delivered',
}

/** Statuses that still need kitchen attention (drive fetch + badges). */
export const ACTIVE_STATUSES: VtsOrderStatus[] = [
  'awaiting_payment',
  'pending',
  'preparing',
  'dispatched',
]

/**
 * Whole-rupee display. The engine computes money in integer rupees —
 * never divide, never add decimals. "Rs. 1,499" matches how the bot
 * quotes prices on WhatsApp, so staff see the same number in both.
 */
export function formatRs(value: number | null | undefined): string {
  return `Rs. ${Number(value ?? 0).toLocaleString('en-PK')}`
}

/** Defensive line-item accessors (see VtsOrderItem). */
export function itemQty(it: VtsOrderItem): number {
  return Number(it.qty ?? it.quantity ?? 1) || 1
}
export function itemName(it: VtsOrderItem): string {
  return String(it.name ?? it.description ?? 'Item')
}
export function itemAmount(it: VtsOrderItem): number | null {
  const v = it.amount ?? it.line_total ?? it.price
  return v == null ? null : Number(v)
}

/**
 * Business date of a timestamp in the same convention as the
 * `vts_daily_sales` view: Asia/Karachi clock, day rolls at 5am
 * (late-night orders belong to the previous business day).
 */
export function businessDateOf(iso: string | Date): string {
  const khi = new Date(
    new Date(iso).toLocaleString('en-US', { timeZone: 'Asia/Karachi' }),
  )
  khi.setHours(khi.getHours() - 5)
  const y = khi.getFullYear()
  const m = String(khi.getMonth() + 1).padStart(2, '0')
  const d = String(khi.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

/** Today's business date (see businessDateOf). */
export function currentBusinessDate(): string {
  return businessDateOf(new Date())
}
