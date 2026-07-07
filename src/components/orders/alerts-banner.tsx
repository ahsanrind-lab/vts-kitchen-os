'use client'

import { useState } from 'react'
import Link from 'next/link'
import { formatDistanceToNow } from 'date-fns'
import { Bell, BellOff, Check } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { VtsAlert } from '@/hooks/use-vts-alerts'

/**
 * Pending-alert strip (handoffs + new orders) with the sound toggle.
 * Renders nothing but the toggle when all clear. Pulses while alerts
 * are pending so the board is glanceable from across a kitchen.
 */
export function AlertsBanner({
  alerts,
  acknowledge,
  soundEnabled,
  setSoundEnabled,
  canAck,
}: {
  alerts: VtsAlert[]
  acknowledge: (id: string) => Promise<string | null>
  soundEnabled: boolean
  setSoundEnabled: (on: boolean) => void
  canAck: boolean
}) {
  const [busyId, setBusyId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function ack(id: string) {
    setBusyId(id)
    setError(null)
    const err = await acknowledge(id)
    if (err) setError(err)
    setBusyId(null)
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <div aria-live="polite" className="text-sm text-muted-foreground">
          {alerts.length > 0 ? (
            <span className="font-medium text-red-400">
              {alerts.length} alert{alerts.length === 1 ? '' : 's'} ringing
            </span>
          ) : (
            <span>No pending alerts</span>
          )}
        </div>
        <button
          type="button"
          onClick={() => setSoundEnabled(!soundEnabled)}
          className={cn(
            'flex min-h-9 items-center gap-2 rounded-lg border px-3 text-xs font-medium transition-colors',
            soundEnabled
              ? 'border-primary/40 bg-primary/10 text-primary'
              : 'border-border text-muted-foreground hover:bg-muted',
          )}
        >
          {soundEnabled ? (
            <Bell className="h-3.5 w-3.5" aria-hidden />
          ) : (
            <BellOff className="h-3.5 w-3.5" aria-hidden />
          )}
          {soundEnabled ? 'Sound on' : 'Sound off'}
        </button>
      </div>

      {error && <p className="text-xs text-red-400">{error}</p>}

      {alerts.map((alert) => (
        <div
          key={alert.id}
          className={cn(
            'flex flex-wrap items-center gap-2 rounded-xl border p-3',
            alert.type === 'handoff'
              ? 'animate-pulse border-red-500/50 bg-red-500/10'
              : 'animate-pulse border-primary/50 bg-primary/10',
          )}
        >
          <div className="min-w-0 flex-1">
            <p className="text-sm font-semibold text-foreground">{alert.title}</p>
            {alert.body && (
              <p className="truncate text-xs text-muted-foreground">{alert.body}</p>
            )}
            <time
              dateTime={alert.created_at}
              title={new Date(alert.created_at).toLocaleString('en-PK', {
                timeZone: 'Asia/Karachi',
                dateStyle: 'medium',
                timeStyle: 'short',
              })}
              className="text-xs text-muted-foreground"
            >
              {formatDistanceToNow(new Date(alert.created_at), { addSuffix: true })}
            </time>
          </div>
          {alert.conversation_id && (
            <Link
              href={`/inbox?c=${alert.conversation_id}`}
              className="min-h-11 rounded-lg border border-border px-3 py-2 text-sm font-medium text-foreground transition-colors hover:bg-muted"
            >
              Open chat
            </Link>
          )}
          {canAck && (
            <button
              type="button"
              onClick={() => ack(alert.id)}
              disabled={busyId === alert.id}
              className="flex min-h-11 items-center gap-1.5 rounded-lg bg-primary px-3 py-2 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
            >
              <Check className="h-4 w-4" aria-hidden />
              {busyId === alert.id ? '…' : 'Acknowledge'}
            </button>
          )}
        </div>
      ))}
    </div>
  )
}
