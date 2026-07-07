'use client'

import { useState } from 'react'
import Link from 'next/link'
import { formatDistanceToNow } from 'date-fns'
import { MessageSquare, StickyNote, XCircle } from 'lucide-react'
import { cn } from '@/lib/utils'
import {
  NEXT_ACTION_LABEL,
  NEXT_STATUS,
  formatRs,
  itemAmount,
  itemName,
  itemQty,
  type VtsOrder,
  type VtsOrderStatus,
} from '@/lib/vts/orders'

/**
 * One live order. Built phone-first: the advance button is a full-width
 * ≥44px target, money is engine-computed and only rendered, and the
 * timestamp shows relative text with the absolute time on hover
 * (dispute-friendly).
 */
export function OrderCard({
  order,
  canEdit,
  onSetStatus,
}: {
  order: VtsOrder
  canEdit: boolean
  onSetStatus: (id: string, status: VtsOrderStatus) => Promise<string | null>
  }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [confirmCancel, setConfirmCancel] = useState(false)

  const next = NEXT_STATUS[order.status]
  const nextLabel = NEXT_ACTION_LABEL[order.status]
  const created = new Date(order.created_at)
  const awaitingPayment = order.status === 'awaiting_payment'

  async function move(status: VtsOrderStatus) {
    setBusy(true)
    setError(null)
    const err = await onSetStatus(order.id, status)
    if (err) setError(err)
    setBusy(false)
    setConfirmCancel(false)
  }

  return (
    <div
      className={cn(
        'rounded-xl border bg-card p-3 text-sm',
        awaitingPayment ? 'border-amber-500/50' : 'border-border',
      )}
    >
      {/* Ref + time */}
      <div className="flex items-baseline justify-between gap-2">
        <span className="font-semibold text-foreground">{order.order_ref}</span>
        <time
          dateTime={order.created_at}
          title={created.toLocaleString('en-PK', {
            timeZone: 'Asia/Karachi',
            dateStyle: 'medium',
            timeStyle: 'short',
          })}
          className="shrink-0 text-xs text-muted-foreground"
        >
          {formatDistanceToNow(created, { addSuffix: true })}
        </time>
      </div>

      {/* Customer + destination */}
      <p className="mt-1 truncate text-foreground">
        {order.customer_name || order.phone}
        {order.customer_name ? (
          <span className="text-muted-foreground"> · {order.phone}</span>
        ) : null}
      </p>
      {(order.area || order.branch_name) && (
        <p className="truncate text-xs text-muted-foreground">
          {[order.area, order.branch_name].filter(Boolean).join(' — ')}
        </p>
      )}
      {order.address && (
        <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground">
          {order.address}
        </p>
      )}

      {/* Items — engine-computed lines, rendered verbatim */}
      {order.deal_label && (
        <p className="mt-2 text-xs font-medium text-primary">{order.deal_label}</p>
      )}
      {Array.isArray(order.items) && order.items.length > 0 && (
        <ul className="mt-1 space-y-0.5">
          {order.items.map((it, i) => {
            const amt = itemAmount(it)
            return (
              <li key={i} className="flex justify-between gap-2 text-xs">
                <span className="min-w-0 truncate text-foreground">
                  {itemQty(it)} × {itemName(it)}
                </span>
                {amt != null && (
                  <span className="shrink-0 tabular-nums text-muted-foreground">
                    {formatRs(amt)}
                  </span>
                )}
              </li>
            )
          })}
        </ul>
      )}

      {/* Money — from the deterministic engine; never recomputed here */}
      <div className="mt-2 space-y-0.5 border-t border-border pt-2 text-xs">
        <div className="flex justify-between text-muted-foreground">
          <span>Subtotal</span>
          <span className="tabular-nums">{formatRs(order.subtotal)}</span>
        </div>
        <div className="flex justify-between text-muted-foreground">
          <span>Delivery</span>
          <span className="tabular-nums">{formatRs(order.delivery_fee)}</span>
        </div>
        <div className="flex justify-between text-sm font-semibold text-foreground">
          <span>Total</span>
          <span className="tabular-nums">{formatRs(order.total)}</span>
        </div>
      </div>

      {/* Payment + notes */}
      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        {order.payment_method && (
          <span className="rounded-full border border-border bg-muted px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-foreground">
            {order.payment_method}
          </span>
        )}
        {awaitingPayment && (
          <span className="rounded-full border border-amber-500/40 bg-amber-500/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-400">
            Awaiting payment
          </span>
        )}
        {order.payment_status && !awaitingPayment && (
          <span className="rounded-full border border-border bg-muted px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
            {order.payment_status}
          </span>
        )}
      </div>
      {order.notes && (
        <p className="mt-2 flex items-start gap-1 rounded-md bg-muted/60 p-2 text-xs text-foreground">
          <StickyNote className="mt-0.5 h-3 w-3 shrink-0 text-muted-foreground" aria-hidden />
          <span className="min-w-0">{order.notes}</span>
        </p>
      )}

      {error && <p className="mt-2 text-xs text-red-400">{error}</p>}

      {/* Actions */}
      <div className="mt-3 flex items-center gap-2">
        {canEdit && next && nextLabel && (
          <button
            type="button"
            onClick={() => move(next)}
            disabled={busy}
            className="min-h-11 flex-1 rounded-lg bg-primary px-3 py-2 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
          >
            {busy ? '…' : nextLabel}
          </button>
        )}
        {order.conversation_id && (
          <Link
            href={`/inbox?c=${order.conversation_id}`}
            aria-label={`Open chat for order ${order.order_ref}`}
            className="flex min-h-11 min-w-11 items-center justify-center rounded-lg border border-border text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            <MessageSquare className="h-4 w-4" aria-hidden />
          </Link>
        )}
        {canEdit && order.status !== 'delivered' && order.status !== 'cancelled' && (
          confirmCancel ? (
            <button
              type="button"
              onClick={() => move('cancelled')}
              disabled={busy}
              className="min-h-11 rounded-lg bg-red-500/15 px-3 text-xs font-semibold text-red-400 transition-colors hover:bg-red-500/25 disabled:opacity-50"
            >
              Confirm cancel
            </button>
          ) : (
            <button
              type="button"
              onClick={() => setConfirmCancel(true)}
              aria-label={`Cancel order ${order.order_ref}`}
              className="flex min-h-11 min-w-11 items-center justify-center rounded-lg border border-border text-muted-foreground transition-colors hover:bg-red-500/10 hover:text-red-400"
            >
              <XCircle className="h-4 w-4" aria-hidden />
            </button>
          )
        )}
      </div>
    </div>
  )
}
