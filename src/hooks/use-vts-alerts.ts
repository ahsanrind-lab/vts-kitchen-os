'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/use-auth'

export interface VtsAlert {
  id: string
  account_id: string
  type: 'handoff' | 'new_order'
  conversation_id: string | null
  order_ref: string | null
  phone: string | null
  title: string
  body: string | null
  status: 'pending' | 'acknowledged'
  created_at: string
}

const SOUND_PREF_KEY = 'vts-alert-sound'

/**
 * Pending `vts_alerts` (handoffs + new orders) with a ringing tone.
 *
 * - Rings (two-tone chime, ~3s loop) while ANY pending alert exists
 *   and sound is enabled. Stops the moment the last one is acked —
 *   including when a teammate acks it on another device (realtime
 *   UPDATE clears it here too).
 * - Browsers block audio until a user gesture, so sound is an explicit
 *   opt-in toggle persisted in localStorage. The toggle itself is the
 *   gesture that unlocks the AudioContext.
 * - Acknowledge writes acked_by/acked_at (RLS: agent+).
 */
export function useVtsAlerts() {
  const { user } = useAuth()
  const [alerts, setAlerts] = useState<VtsAlert[]>([])
  const [soundEnabled, setSoundEnabledState] = useState(false)
  const mapRef = useRef<Map<string, VtsAlert>>(new Map())
  const audioCtxRef = useRef<AudioContext | null>(null)
  const ringTimerRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const flush = useCallback(() => {
    setAlerts(
      [...mapRef.current.values()]
        .filter((a) => a.status === 'pending')
        .sort((a, b) => b.created_at.localeCompare(a.created_at)),
    )
  }, [])

  // Load persisted sound preference (client-only).
  useEffect(() => {
    try {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setSoundEnabledState(localStorage.getItem(SOUND_PREF_KEY) === 'on')
    } catch {
      /* storage unavailable — leave sound off */
    }
  }, [])

  useEffect(() => {
    const supabase = createClient()
    let cancelled = false

    ;(async () => {
      const { data, error } = await supabase
        .from('vts_alerts')
        .select('*')
        .eq('status', 'pending')
        .order('created_at', { ascending: false })
        .limit(100)
      if (cancelled || error || !data) return
      mapRef.current = new Map((data as VtsAlert[]).map((a) => [a.id, a]))
      flush()
    })()

    // Unique channel name per mount — this hook is used by more than
    // one surface (Orders board, Notifications); identical names on
    // the same client would collide.
    const channel = supabase
      .channel(`vts-alerts-${Math.random().toString(36).slice(2)}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'vts_alerts' },
        (payload) => {
          if (payload.eventType === 'DELETE') {
            const oldRow = payload.old as Partial<VtsAlert>
            if (oldRow.id) mapRef.current.delete(oldRow.id)
          } else {
            const row = payload.new as VtsAlert
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

  // ---- ringing ------------------------------------------------------

  const chime = useCallback(() => {
    const ctx = audioCtxRef.current
    if (!ctx || ctx.state !== 'running') return
    // Two-tone "order up" chime: E5 then A5, short and non-abrasive,
    // loud enough for a kitchen.
    const t0 = ctx.currentTime
    for (const [freq, start] of [
      [659.25, 0],
      [880.0, 0.18],
    ] as const) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.type = 'square'
      osc.frequency.value = freq
      gain.gain.setValueAtTime(0.0001, t0 + start)
      gain.gain.exponentialRampToValueAtTime(0.28, t0 + start + 0.02)
      gain.gain.exponentialRampToValueAtTime(0.0001, t0 + start + 0.35)
      osc.connect(gain).connect(ctx.destination)
      osc.start(t0 + start)
      osc.stop(t0 + start + 0.4)
    }
  }, [])

  useEffect(() => {
    const shouldRing = soundEnabled && alerts.length > 0
    if (shouldRing && !ringTimerRef.current) {
      chime()
      ringTimerRef.current = setInterval(chime, 3000)
    }
    if (!shouldRing && ringTimerRef.current) {
      clearInterval(ringTimerRef.current)
      ringTimerRef.current = null
    }
    return () => {
      if (ringTimerRef.current) {
        clearInterval(ringTimerRef.current)
        ringTimerRef.current = null
      }
    }
  }, [soundEnabled, alerts.length, chime])

  const setSoundEnabled = useCallback((on: boolean) => {
    setSoundEnabledState(on)
    try {
      localStorage.setItem(SOUND_PREF_KEY, on ? 'on' : 'off')
    } catch {
      /* non-fatal */
    }
    if (on) {
      // This runs inside the toggle's click handler — a user gesture —
      // which is what lets the AudioContext start.
      if (!audioCtxRef.current) {
        const Ctx =
          window.AudioContext ??
          (window as unknown as { webkitAudioContext?: typeof AudioContext })
            .webkitAudioContext
        if (Ctx) audioCtxRef.current = new Ctx()
      }
      void audioCtxRef.current?.resume()
    }
  }, [])

  /** Acknowledge (stop ringing for) one alert. Error message or null. */
  const acknowledge = useCallback(
    async (alertId: string): Promise<string | null> => {
      const supabase = createClient()
      const { data, error } = await supabase
        .from('vts_alerts')
        .update({
          status: 'acknowledged',
          acked_by: user?.id ?? null,
          acked_at: new Date().toISOString(),
        })
        .eq('id', alertId)
        .select()
        .maybeSingle()
      if (error) return error.message
      if (!data) return 'Not permitted (viewer role) or alert not found'
      mapRef.current.set((data as VtsAlert).id, data as VtsAlert)
      flush()
      return null
    },
    [user?.id, flush],
  )

  return { alerts, acknowledge, soundEnabled, setSoundEnabled }
}
