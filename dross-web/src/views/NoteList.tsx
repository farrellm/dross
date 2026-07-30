import { useState } from 'react'
import { Link } from 'react-router-dom'
import { api } from '../api'
import { useAsync } from '../useAsync'
import { Empty, Failed, Loading, when } from '../components/bits'

type Order = 'recent' | 'alpha'

export function NoteList() {
  const [order, setOrder] = useState<Order>('recent')
  const notes = useAsync((signal) => api.notes(signal), [])

  return (
    <>
      <header className="head">
        <p className="eyebrow">The collection</p>
        <div className="head-row">
          <h1 className="head-title">Notes</h1>
          <div className="segmented" role="group" aria-label="Sort order">
            <button
              type="button"
              aria-pressed={order === 'recent'}
              onClick={() => setOrder('recent')}
            >
              Recent
            </button>
            <button
              type="button"
              aria-pressed={order === 'alpha'}
              onClick={() => setOrder('alpha')}
            >
              A–Z
            </button>
          </div>
        </div>
      </header>

      {notes.state === 'loading' && <Loading what="notes" />}
      {notes.state === 'failed' && <Failed error={notes.error} />}
      {notes.state === 'ready' &&
        (notes.value.length === 0 ? (
          <Empty>No notes here yet. Send something to the bot to start one.</Empty>
        ) : (
          <ol className="ledger">
            {sort(notes.value, order).map((n) => (
              <li key={n.id}>
                <Link to={`/note/${encodeURIComponent(n.id)}`} className="ledger-row">
                  <span className="ledger-title">{n.title}</span>
                  <span className="ledger-when">{when(n.mtime)}</span>
                </Link>
              </li>
            ))}
          </ol>
        ))}
    </>
  )
}

function sort<T extends { title: string; mtime: string }>(notes: T[], order: Order): T[] {
  if (order === 'recent') return notes
  return [...notes].sort((a, b) => a.title.localeCompare(b.title))
}
