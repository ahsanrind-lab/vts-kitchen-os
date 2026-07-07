'use client'

import Link from 'next/link'
import { ClipboardList } from 'lucide-react'
import { cn } from '@/lib/utils'
import { formatRs } from '@/lib/vts/orders'
import type { OrderStatusSlice } from '@/lib/dashboard/types'
import { EmptyState } from './empty-state'
import { Skeleton } from './skeleton'

const STATUS_TINT: Record<string, string> = {
  awaiting_payment: 'bg-amber-400',
  pending: 'bg-blue-400',
  preparing: 'bg-orange-400',
  dispatched: 'bg-violet-400',
  delivered: 'bg-primary',
  cancelled: 'bg-red-400',
}

/**
 * "Today's orders by status" — the restaurant replacement for the
 * sales-pipeline donut. Simple proportional bars: glanceable from a
 * phone, no chart library, no USD.
 */
export function OrdersStatusCard({
  slices,
  loading,
}: {
  slices: OrderStatusSlice[] | null
  loading: boolean
}) {
  const total = (slices ?? []).reduce((s, x) => s + x.count, 0)
  const max = Math.max(1, ...(slices ?? []).map((s) => s.count))

  return (
    <section className="flex h-full flex-col rounded-xl border border-border bg-card">
      <header className="flex items-center justify-between border-b border-border px-5 py-4">
        <h2 className="text-sm font-semibold text-foreground">
          Today&apos;s orders by status
        </h2>
        <Link
          href="/orders"
          className="text-xs font-medium text-primary hover:text-primary/80"
        >
          Open board →
        </Link>
      </header>

      <div className="flex-1 p-5">
        {loading || slices === null ? (
          <div className="space-y-3">
            {Array.from({ length: 4 }).map((_, i) => (
              <Skeleton key={i} className="h-8 w-full" />
            ))}
          </div>
        ) : total === 0 ? (
          <EmptyState
            icon={ClipboardList}
            title="No orders yet today"
            hint="Confirmed WhatsApp orders appear here as they come in."
          />
        ) : (
          <ul className="space-y-3">
            {slices.map((s) => (
              <li key={s.status}>
                <div className="mb-1 flex items-baseline justify-between gap-2 text-sm">
                  <span className="font-medium text-foreground">{s.label}</span>
                  <span className="shrink-0 text-xs tabular-nums text-muted-foreground">
                    {s.count} · {formatRs(s.totalRs)}
                  </span>
                </div>
                <div className="h-2 w-full overflow-hidden rounded-full bg-muted">
                  <div
                    className={cn(
                      'h-full rounded-full',
                      STATUS_TINT[s.status] ?? 'bg-muted-foreground',
                    )}
                    style={{ width: `${Math.max(4, (s.count / max) * 100)}%` }}
                  />
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}
