import { useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { api, type Hit, type ScoredHit } from '../api'
import { useAsync } from '../useAsync'
import { Empty, Failed, Loading, TemperBar } from '../components/bits'
import { rankBand, scoreBand } from '../temper'

type Mode = 'text' | 'meaning'

export function SearchView() {
  const [params, setParams] = useSearchParams()
  const query = params.get('q') ?? ''
  const mode: Mode = params.get('mode') === 'meaning' ? 'meaning' : 'text'
  const [draft, setDraft] = useState(query)

  const submit = (q: string, m: Mode) => {
    const next = new URLSearchParams()
    if (q.trim() !== '') next.set('q', q.trim())
    if (m === 'meaning') next.set('mode', m)
    setParams(next, { replace: true })
  }

  const results = useAsync(
    (signal) =>
      query === ''
        ? Promise.resolve<Hit[]>([])
        : mode === 'meaning'
          ? api.semanticSearch(query, signal)
          : api.search(query, signal),
    [query, mode],
  )

  return (
    <>
      <header className="head">
        <p className="eyebrow">Find a note</p>
        <form
          className="searchbar"
          onSubmit={(e) => {
            e.preventDefault()
            submit(draft, mode)
          }}
        >
          <input
            className="searchfield"
            type="search"
            name="q"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            placeholder="Words, or a question"
            aria-label="Search"
            autoComplete="off"
            autoCapitalize="none"
            enterKeyHint="search"
          />
          <div className="segmented" role="group" aria-label="How to search">
            <button
              type="button"
              aria-pressed={mode === 'text'}
              onClick={() => submit(draft, 'text')}
            >
              Text
            </button>
            <button
              type="button"
              aria-pressed={mode === 'meaning'}
              onClick={() => submit(draft, 'meaning')}
            >
              Meaning
            </button>
          </div>
        </form>
      </header>

      {query === '' && (
        <Empty>
          {mode === 'text'
            ? 'Search the words in your notes. Quote a phrase to match it exactly.'
            : 'Describe what you’re after and the index will match on meaning, not wording.'}
        </Empty>
      )}
      {query !== '' && results.state === 'loading' && <Loading what="results" />}
      {results.state === 'failed' && <Failed error={results.error} />}
      {query !== '' && results.state === 'ready' && (
        results.value.length === 0 ? (
          <Empty>
            No notes match that.{' '}
            {mode === 'text' ? 'Try fewer words, or switch to Meaning.' : 'Try describing it differently.'}
          </Empty>
        ) : (
          <ol className="results">
            {results.value.map((hit, i) => (
              <li key={hit.id}>
                <Link to={`/note/${encodeURIComponent(hit.id)}`} className="result">
                  <TemperBar
                    band={'score' in hit ? scoreBand((hit as ScoredHit).score) : rankBand(i)}
                  />
                  <span className="result-title">{hit.title}</span>
                  {'score' in hit && (
                    <span className="result-score">
                      {(hit as ScoredHit).score.toFixed(2)}
                    </span>
                  )}
                </Link>
              </li>
            ))}
          </ol>
        )
      )}
    </>
  )
}
