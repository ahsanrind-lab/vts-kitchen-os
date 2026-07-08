'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Bell, BellOff, PhoneCall, ClipboardList } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useVtsAlerts } from '@/hooks/use-vts-alerts'

/**
 * App-wide handoff/new-order ringer. Mounted once in the dashboard
 * shell so the chime and the floating pill work on EVERY page — before
 * this, a handoff only rang if someone happened to have the Orders or
 * Notifications page open.
 *
 * On /orders and /notifications the full AlertsBanner already renders,
 * so the pill hides there (the audio side is de-duplicated across hook
 * instances by the window-level chime throttle in use-vts-alerts).
 */
export function GlobalAlertRinger() {
  const pathname = usePathname()
  const { alerts, soundEnabled, setSoundEnabled } = useVtsAlerts()

  // Pages that render their own AlertsBanner get no floating pill.
  const onAlertPage =
    pathname.startsWith('/orders') || pathname.startsWith('/notifications')
  if (onAlertPage || alerts.length === 0) return null

  const newest = alerts[0]
  const isHandoff = newest.type === 'handoff'
  const href = newest.conversation_id
    ? `/inbox?c=${newest.conversation_id}`
    : '/orders'

  return (
    <div className="fixed bottom-4 right-4 z-50 flex max-w-sm items-center gap-2">
      {/* Sound toggle — also the user gesture that unlocks audio. */}
      <button
        type="button"
        onClick={() => setSoundEnabled(!soundEnabled)}
        aria-label={soundEnabled ? 'Mute alert sound' : 'Enable alert sound'}
        className={cn(
          'flex h-11 w-11 shrink-0 items-center justify-center rounded-full border shadow-lg transition-colors',
          soundEnabled
            ? 'border-primary/40 bg-primary/15 text-primary'
            : 'border-border bg-card text-muted-foreground hover:text-foreground',
        )}
      >
        {soundEnabled ? <Bell className="h-4 w-4" aria-hidden /> : <BellOff className="h-4 w-4" aria-hidden />}
      </button>

      <Link
        href={href}
        className={cn(
          'flex min-h-11 flex-1 animate-pulse items-center gap-2 rounded-full border px-4 py-2 shadow-xl transition-colors',
          isHandoff
            ? 'border-red-500/60 bg-red-600 text-white hover:bg-red-500'
            : 'border-primary/60 bg-primary text-primary-foreground hover:bg-primary/90',
        )}
      >
        {isHandoff ? (
          <PhoneCall className="h-4 w-4 shrink-0" aria-hidden />
        ) : (
          <ClipboardList className="h-4 w-4 shrink-0" aria-hidden />
        )}
        <span className="min-w-0 truncate text-sm font-semibold">
          {isHandoff ? 'Customer needs a human' : 'New order'}
          {alerts.length > 1 ? ` (+${alerts.length - 1} more)` : ''}
        </span>
      </Link>
    </div>
  )
}
