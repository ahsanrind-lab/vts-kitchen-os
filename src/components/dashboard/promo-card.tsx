'use client'

import { useEffect, useState } from 'react'
import { Megaphone, Loader2 } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { useAuth } from '@/hooks/use-auth'

/**
 * Promo message manager — writes the bot's `cache:announce` key via
 * the n8n VTS Control webhook (see /api/vts/promo). When ON, the bot
 * appends this text to its greeting reply for every customer.
 * Admin+ only; renders nothing for agents/viewers.
 */
export function PromoCard() {
  const { canEditSettings } = useAuth()
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [enabled, setEnabled] = useState(false)
  const [text, setText] = useState('')
  const [savedState, setSavedState] = useState<{ enabled: boolean; text: string } | null>(null)

  useEffect(() => {
    if (!canEditSettings) return
    let cancelled = false
    ;(async () => {
      try {
        const r = await fetch('/api/vts/promo')
        const j = await r.json()
        if (cancelled) return
        if (r.ok) {
          setEnabled(!!j.enabled)
          setText(j.text || '')
          setSavedState({ enabled: !!j.enabled, text: j.text || '' })
        } else {
          toast.error('Could not load promo state')
        }
      } catch {
        if (!cancelled) toast.error('Could not load promo state')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [canEditSettings])

  if (!canEditSettings) return null

  const dirty =
    !savedState || savedState.enabled !== enabled || (enabled && savedState.text !== text.trim())

  async function save() {
    if (enabled && !text.trim()) {
      toast.error('Write the promo text first')
      return
    }
    setSaving(true)
    try {
      const r = await fetch('/api/vts/promo', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled, text: text.trim() }),
      })
      if (!r.ok) throw new Error((await r.json()).error || 'save failed')
      setSavedState({ enabled, text: text.trim() })
      toast.success(
        enabled
          ? 'Promo is ON — the bot will include it in greetings.'
          : 'Promo turned OFF.',
      )
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Save failed')
    } finally {
      setSaving(false)
    }
  }

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="flex items-center justify-between border-b border-border px-5 py-4">
        <div className="flex items-center gap-2">
          <Megaphone className="h-4 w-4 text-primary" aria-hidden />
          <h2 className="text-sm font-semibold text-foreground">WhatsApp promo message</h2>
        </div>
        {/* ON/OFF switch */}
        <button
          type="button"
          role="switch"
          aria-checked={enabled}
          disabled={loading || saving}
          onClick={() => setEnabled((v) => !v)}
          className={cn(
            'relative h-6 w-11 rounded-full transition-colors disabled:opacity-50',
            enabled ? 'bg-primary' : 'bg-muted',
          )}
        >
          <span
            className={cn(
              'absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform',
              enabled ? 'translate-x-[22px]' : 'translate-x-0.5',
            )}
          />
          <span className="sr-only">{enabled ? 'Promo on' : 'Promo off'}</span>
        </button>
      </header>

      <div className="space-y-3 p-5">
        {loading ? (
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" /> Loading…
          </div>
        ) : (
          <>
            <textarea
              value={text}
              onChange={(e) => setText(e.target.value)}
              rows={3}
              maxLength={400}
              placeholder="e.g. 🎉 Aaj ki offer: Deal 5 par free 1L drink! Code DEAL5 likhein."
              className="w-full rounded-lg border border-border bg-muted p-3 text-sm text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none"
            />
            <div className="flex items-center justify-between gap-3">
              <p className="text-xs text-muted-foreground">
                When ON, the bot adds this to its greeting for every customer.
                {enabled ? '' : ' Currently OFF — customers see the normal greeting.'}
              </p>
              <button
                type="button"
                onClick={save}
                disabled={saving || !dirty}
                className="min-h-9 shrink-0 rounded-lg bg-primary px-4 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
              >
                {saving ? 'Saving…' : 'Save'}
              </button>
            </div>
          </>
        )}
      </div>
    </section>
  )
}
