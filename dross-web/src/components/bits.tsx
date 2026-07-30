import type { ReactNode } from 'react'
import type { ApiError } from '../api'
import { bandColor, type Band } from '../temper'

/** The 4px rule that puts a result on the tempering ramp. */
export function TemperBar({ band }: { band: Band }) {
  return <span className="temper" style={{ background: bandColor(band) }} />
}

export function Pip({ band }: { band: Band }) {
  return <span className="pip" style={{ background: bandColor(band) }} />
}

export function Loading({ what }: { what: string }) {
  return <p className="status">Loading {what}…</p>
}

export function Failed({ error }: { error: ApiError }) {
  return (
    <div className="status status-bad" role="alert">
      <p>{error.message}</p>
      {error.status === 0 && <p className="status-hint">Check that dross-bot is running.</p>}
    </div>
  )
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="status">{children}</p>
}

/** Dates are for orientation, not precision — say how long ago. */
export function when(iso: string): string {
  const then = new Date(iso)
  if (Number.isNaN(then.getTime())) return ''
  const days = Math.floor((Date.now() - then.getTime()) / 86_400_000)
  if (days <= 0) return 'today'
  if (days === 1) return 'yesterday'
  if (days < 30) return `${days}d`
  if (days < 365) return `${Math.floor(days / 30)}mo`
  return `${Math.floor(days / 365)}y`
}
