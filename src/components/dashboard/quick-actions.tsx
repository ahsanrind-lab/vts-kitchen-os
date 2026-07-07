"use client"

import Link from 'next/link'
import { ClipboardList, LayoutTemplate, Radio, Users } from 'lucide-react'
import type { ComponentType } from 'react'

// Quick-action shortcuts, restaurant edition. An owner or manager's
// daily verbs are "check the orders", "message customers", "fix a
// template", "look someone up" — not "create a deal". Each navigates
// to the page that owns the flow; no modal auto-opening.
interface Action {
  label: string
  href: string
  icon: ComponentType<{ className?: string }>
  tint: string
}

const ACTIONS: Action[] = [
  { label: "Today's Orders", href: '/orders', icon: ClipboardList, tint: 'text-primary' },
  { label: 'New Broadcast', href: '/broadcasts/new', icon: Radio, tint: 'text-amber-400' },
  { label: 'Templates', href: '/settings?tab=templates', icon: LayoutTemplate, tint: 'text-blue-400' },
  { label: 'Contacts', href: '/contacts', icon: Users, tint: 'text-primary' },
]

export function QuickActions() {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      {ACTIONS.map((a) => {
        const Icon = a.icon
        return (
          <Link
            key={a.href}
            href={a.href}
            className="group flex items-center gap-3 rounded-xl border border-border bg-card px-4 py-3 transition-colors hover:border-border hover:bg-muted/60"
          >
            <div className={`flex h-9 w-9 items-center justify-center rounded-lg bg-muted ${a.tint}`}>
              <Icon className="h-4 w-4" />
            </div>
            <span className="text-sm font-medium text-foreground">{a.label}</span>
          </Link>
        )
      })}
    </div>
  )
}
