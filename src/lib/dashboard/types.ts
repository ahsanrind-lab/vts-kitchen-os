// Shared result shapes the dashboard components consume. Centralised
// here so each component stays thin and the page-level loader wires
// them up without type gymnastics.

export interface MetricDelta {
  current: number
  previous: number
}

/** One order-status bucket for the "orders today" breakdown card. */
export interface OrderStatusSlice {
  /** vts_orders.status value. */
  status: string
  /** Human label ("Received", "Preparing", …). */
  label: string
  count: number
  /** Sum of engine-computed totals in whole rupees. */
  totalRs: number
}

export interface MetricsBundle {
  activeConversations: MetricDelta
  newContactsToday: MetricDelta
  /** Orders on today's business date (5am Asia/Karachi roll), excl. cancelled. */
  todayOrders: MetricDelta
  /** Revenue in whole rupees on today's business date, excl. cancelled. */
  todayRevenueRs: MetricDelta
  /**
   * Average minutes from order creation to the `delivered` status flip,
   * over today's delivered orders. Null when nothing was delivered yet.
   * Approximation: `updated_at` is the LAST status change, which for a
   * delivered order is the delivery flip itself.
   */
  avgFulfillmentMins: number | null
  /** Sample size behind avgFulfillmentMins. */
  deliveredToday: number
  /** Today's orders bucketed by status (board order, incl. delivered). */
  ordersByStatus: OrderStatusSlice[]
  messagesSentToday: MetricDelta
}

export interface ConversationsSeriesPoint {
  day: string // YYYY-MM-DD local
  incoming: number
  outgoing: number
}

// Kept for the (nav-hidden) Pipelines surface — components/dashboard/
// pipeline-donut.tsx still type-checks against these even though the
// VTS dashboard no longer renders it.
export interface PipelineStageSlice {
  id: string
  name: string
  color: string
  dealCount: number
  totalValue: number
}

export interface PipelineDonutData {
  stages: PipelineStageSlice[]
  totalValue: number
}

export interface ResponseTimeBucket {
  /** 0 = Mon … 6 = Sun (Monday-first). */
  dow: number
  /** Average first-response time in minutes. Null means no samples. */
  avgMinutes: number | null
  samples: number
}

export interface ResponseTimeSummary {
  buckets: ResponseTimeBucket[]
  thisWeekAvg: number | null
  lastWeekAvg: number | null
}

export type ActivityKind =
  | 'message'
  | 'order'
  | 'broadcast'
  | 'contact'

export interface ActivityItem {
  id: string
  kind: ActivityKind
  /** Primary line of text rendered in the feed. Pre-formatted. */
  text: string
  /** ISO timestamp the item happened at, drives relative-time + sort. */
  at: string
  /** Optional deep-link for the whole row (not all items have a target). */
  href?: string
}
