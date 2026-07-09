'use client';

import { useState } from 'react';

/**
 * VTS Kitchen OS — "Take over / Give back to bot" button.
 * Mount in the conversation thread header (src/components/inbox/…),
 * passing the current conversation's id, contact phone, and vts_bot_enabled.
 *
 * Design notes:
 *  - NO optimistic update: the button reflects confirmed state only,
 *    because a wrong "bot off" indication = agent silence + bot silence.
 *  - Realtime UPDATE on conversations will refresh the prop from the parent.
 */
export function VtsBotToggle({ conversationId, phone, botEnabled, onChanged }: {
  conversationId: string;
  phone: string;
  botEnabled: boolean;
  onChanged?: (enabled: boolean) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function toggle() {
    setBusy(true); setError(null);
    try {
      const res = await fetch('/api/vts/bot-toggle', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ conversationId, phone, enable: !botEnabled }),
      });
      const j = await res.json();
      if (!res.ok) throw new Error(j.error ?? 'failed');
      onChanged?.(j.vts_bot_enabled);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex items-center gap-2">
      <button
        onClick={toggle}
        disabled={busy}
        title={botEnabled ? 'Silence the AI and take over this chat' : 'Return this chat to the AI'}
        className={`rounded-md px-3 py-1.5 text-sm font-medium transition-colors disabled:opacity-50 ${
          botEnabled
            ? 'bg-amber-500/15 text-amber-500 hover:bg-amber-500/25'
            : 'bg-emerald-500/15 text-emerald-500 hover:bg-emerald-500/25'
        }`}
      >
        {busy ? '…' : botEnabled ? '🙋 Take over' : '🤖 Give back to bot'}
      </button>
      <span className={`hidden text-xs xl:inline ${botEnabled ? 'text-emerald-500' : 'text-amber-500'}`}>
        {botEnabled ? 'Bot is replying' : 'Human mode — bot silenced'}
      </span>
      {error && <span className="text-xs text-red-500">{error}</span>}
    </div>
  );
}
