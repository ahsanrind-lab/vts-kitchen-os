'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/use-auth'
import {
  ACTIVE_STATUSES,
  type VtsOrder,
  type VtsOrderStatus,
} from '@/lib/vts/orders'

/**
 * Live order state for the kitchen board.
 *
 * Loads every still-active order (any age — an unfinished order must
 * never fall off the board) plus everything from the last 24 hours
 * (so Delivered/Cancelled from today stay visible), then keeps the
 * set current via realtime (publication added in migration 031).
 *
 * Status updates are confirmed-only — same philosophy as VtsBotToggle:
 * a wrong "Preparing" tile misroutes a real pizza, so the card shows
 * the server-confirmed state and a busy spinner, never an optimistic
 * guess.
 */
export function useVtsOrders() {
  const { user } = useAuth()
  const [orders, setOrders] = useState<VtsOrder[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const mapRef = useRef<Map<string, VtsOrder>>(new Map())

  const flush = useCallback(() => {
    setOrders(
      [...mapRef.current.values()].sort((a, b) =>
        b.created_at.localeCompare(a.created_at),
      ),
    )
  }, [])

  useEffect(() => {
    const supabase = createClient()
    let cancelled = false

    ;(async () => {
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString()
      const { data, error } = await supabase
        .from('vts_orders')
        .select('*')
        .or(
          `status.in.(${ACTIVE_STATUSES.join(',')}),created_at.gte.${since}`,
        )
        .order('created_at', { ascending: false })
        .limit(500)
      if (cancelled) return
      if (error) {
        setError(error.message)
        setOrders([])
        return
      }
      mapRef.current = new Map(
        (data as VtsOrder[]).map((o) => [o.id, o]),
      )
      flush()
    })()

    // Unique channel name per mount (see use-vts-alerts).
    const channel = supabase
      .channel(`vts-orders-${Math.random().toString(36).slice(2)}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'vts_orders' },
        (payload) => {
          if (payload.eventType === 'DELETE') {
            const oldRow = payload.old as Partial<VtsOrder>
            if (oldRow.id) mapRef.current.delete(oldRow.id)
          } else {
            const row = payload.new as VtsOrder
            mapRef.current.set(row.id, row)
          }
          flush()
        },
      )
      .subscribe()

    return () => {
      cancelled = true
      supabase.removeChannel(channel)
    }
  }, [flush])

  /**
   * Set an order's status. Returns an error message or null.
   * RLS enforces agent+ server-side; callers gate the button too.
   */
  const setStatus = useCallback(
    async (orderId: string, status: VtsOrderStatus): Promise<string | null> => {
      const supabase = createClient()
      const { data, error } = await supabase
        .from('vts_orders')
        .update({ status })
        .eq('id', orderId)
        .select()
        .maybeSingle()
      if (error) return error.message
      // RLS silently matching 0 rows (e.g. viewer role) returns no
      // error and no row — surface that instead of pretending success.
      if (!data) return 'Not permitted (viewer role) or order not found'
      mapRef.current.set((data as VtsOrder).id, data as VtsOrder)
      flush()
      // One action, not two: advancing (or cancelling) an order IS the
      // acknowledgement of its new-order ring (there is no manual ack for
      // new_order alerts). Fire-and-forget — an ack failure must never
      // read as a status-change failure; the realtime UPDATE on
      // vts_alerts silences every device when it lands.
      const advanced = data as VtsOrder
      void supabase
        .from('vts_alerts')
        .update({
          status: 'acknowledged',
          acked_by: user?.id ?? null,
          acked_at: new Date().toISOString(),
        })
        .eq('order_ref', advanced.order_ref)
        .eq('type', 'new_order')
        .eq('status', 'pending')
        .then(({ error: ackErr }) => {
          if (ackErr)
            console.error('[vts] alert auto-ack failed:', ackErr.message)
        })
      // Customer WhatsApp notification — fire-and-forget through the
      // n8n control workflow (same wording as the staff UPDATE command,
      // mirrored into the inbox). A notify failure must never read as
      // a status-change failure: the board update above already stuck.
      const NOTIFY = new Set(['preparing', 'dispatched', 'delivered', 'cancelled'])
      if (NOTIFY.has(status)) {
        const o = data as VtsOrder
        void fetch('/api/vts/notify-status', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ order_ref: o.order_ref, phone: o.phone, status }),
        })
          .then(async (r) => {
            if (!r.ok) console.error('[vts] status notify failed:', await r.text())
          })
          .catch((e) => console.error('[vts] status notify failed:', e))
      }
      return null
    },
    [flush, user?.id],
  )

  return { orders, error, setStatus }
}
