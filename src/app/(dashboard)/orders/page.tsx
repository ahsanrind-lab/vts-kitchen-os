'use client'

import { useMemo } from 'react'
import { ClipboardList } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useAuth } from '@/hooks/use-auth'
import { useVtsOrders } from '@/hooks/use-vts-orders'
import { useVtsAlerts } from '@/hooks/use-vts-alerts'
import { OrderCard } from '@/components/orders/order-card'
import { AlertsBanner } from '@/components/orders/alerts-banner'
import {
  BOARD_COLUMNS,
  boardColumnFor,
  businessDateOf,
  currentBusinessDate,
  formatRs,
  type VtsOrder,
} from '@/lib/vts/orders'

/**
 * VTS Kitchen OS — the Orders board.
 *
 * Live cards from `vts_orders` (written only by the n8n bot via Tap C),
 * a four-column status workflow (Received → Preparing → Out for
 * delivery → Delivered), and ringing alerts from `vts_alerts`.
 * Money comes from the bot's deterministic engine and is rendered
 * verbatim — this page never computes a price.
 */
export default function OrdersPage() {
  const { canSendMessages } = useAuth()
  const { orders, error, setStatus } = useVtsOrders()
  const alertState = useVtsAlerts()

  const byColumn = useMemo(() => {
    const map = new Map<string, VtsOrder[]>(
      BOARD_COLUMNS.map((c) => [c.key, []]),
    )
    for (const o of orders ?? []) {
      const col = boardColumnFor(o.status)
      if (col) map.get(col)?.push(o)
    }
    return map
  }, [orders])

  const today = useMemo(() => {
    const bd = currentBusinessDate()
    const todays = (orders ?? []).filter(
      (o) => businessDateOf(o.created_at) === bd && o.status !== 'cancelled',
    )
    return {
      count: todays.length,
      revenue: todays.reduce((s, o) => s + (o.total || 0), 0),
    }
  }, [orders])

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Orders</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Live from WhatsApp — every order the bot confirms lands here.
          </p>
        </div>
        <div className="flex items-center gap-4 rounded-xl border border-border bg-card px-4 py-2 text-sm">
          <span className="text-muted-foreground">
            Today:{' '}
            <span className="font-semibold tabular-nums text-foreground">
              {today.count} order{today.count === 1 ? '' : 's'}
            </span>
          </span>
          <span className="text-muted-foreground">
            Sales:{' '}
            <span className="font-semibold tabular-nums text-foreground">
              {formatRs(today.revenue)}
            </span>
          </span>
        </div>
      </div>

      {/* Ringing alerts */}
      <AlertsBanner
        alerts={alertState.alerts}
        acknowledge={alertState.acknowledge}
        soundEnabled={alertState.soundEnabled}
        setSoundEnabled={alertState.setSoundEnabled}
        canAck={canSendMessages}
      />

      {error && (
        <p className="rounded-xl border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-400">
          Could not load orders: {error}
        </p>
      )}

      {/* Status board */}
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4">
        {BOARD_COLUMNS.map((col) => {
          const colOrders = byColumn.get(col.key) ?? []
          return (
            <section key={col.key} aria-label={col.label} className="min-w-0">
              <header className="mb-2 flex items-center justify-between px-1">
                <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
                  {col.label}
                </h2>
                <span
                  className={cn(
                    'flex h-6 min-w-6 items-center justify-center rounded-full px-1.5 text-xs font-semibold tabular-nums',
                    colOrders.length > 0 && col.key === 'pending'
                      ? 'bg-primary text-primary-foreground'
                      : 'bg-muted text-muted-foreground',
                  )}
                >
                  {colOrders.length}
                </span>
              </header>
              <div className="space-y-3">
                {orders === null ? (
                  <OrderCardSkeleton />
                ) : colOrders.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-border p-4 text-center text-xs text-muted-foreground">
                    {col.key === 'pending' ? 'No new orders' : 'Empty'}
                  </div>
                ) : (
                  colOrders.map((o) => (
                    <OrderCard
                      key={o.id}
                      order={o}
                      canEdit={canSendMessages}
                      onSetStatus={setStatus}
                    />
                  ))
                )}
              </div>
            </section>
          )
        })}
      </div>

      {orders !== null && orders.length === 0 && !error && (
        <div className="rounded-xl border border-border bg-card p-8 text-center">
          <ClipboardList className="mx-auto h-8 w-8 text-muted-foreground" aria-hidden />
          <p className="mt-3 text-sm font-medium text-foreground">No orders yet</p>
          <p className="mt-1 text-sm text-muted-foreground">
            When a customer confirms an order with the WhatsApp bot, its card
            appears here instantly.
          </p>
        </div>
      )}
    </div>
  )
}

function OrderCardSkeleton() {
  return (
    <div className="animate-pulse rounded-xl border border-border bg-card p-3">
      <div className="h-4 w-24 rounded bg-muted" />
      <div className="mt-2 h-3 w-32 rounded bg-muted" />
      <div className="mt-3 h-3 w-full rounded bg-muted" />
      <div className="mt-1 h-3 w-2/3 rounded bg-muted" />
      <div className="mt-3 h-10 w-full rounded-lg bg-muted" />
    </div>
  )
}
