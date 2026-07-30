import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api, type NoteLink, type NotePage } from '../api'
import { useAsync } from '../useAsync'
import { Org } from '../org/Org'
import { Empty, Failed, Loading, Pip, when } from '../components/bits'
import { hopBand, scoreBand } from '../temper'

export function NoteView() {
  const { id = '' } = useParams()
  const page = useAsync((signal) => api.note(id, signal), [id])
  const [open, setOpen] = useState(false)

  // A new note is a new set of connections; never carry the drawer over.
  useEffect(() => setOpen(false), [id])

  if (page.state === 'loading') return <Loading what="the note" />
  if (page.state === 'failed') return <Failed error={page.error} />
  return <Note page={page.value} open={open} setOpen={setOpen} />
}

function Note({
  page,
  open,
  setOpen,
}: {
  page: NotePage
  open: boolean
  setOpen: (open: boolean) => void
}) {
  const { note, backlinks, forwardLinks } = page
  const title = note.title
  const navigate = useNavigate()

  // Forward links already carry their targets' titles, so a bare
  // [[id:...]] in the body can name where it goes.
  const titles = new Map(forwardLinks.map((l) => [l.id, l.title]))

  return (
    <>
      <article className="note">
        <header className="note-head">
          <button type="button" className="back" onClick={() => navigate(-1)}>
            <span aria-hidden="true">‹</span> Back
          </button>
          <h1 className="note-title">{note.title}</h1>
          <p className="note-meta">
            <span>{when(note.mtime)}</span>
            {note.tags.map((tag) => (
              <span key={tag} className="note-tag">
                {tag}
              </span>
            ))}
          </p>
        </header>
        <Org source={note.raw} titles={titles} />
      </article>

      <button
        type="button"
        className="foreedge"
        aria-expanded={open}
        aria-controls="connections"
        onClick={() => setOpen(!open)}
      >
        <span className="foreedge-label">
          Backlinks<span className="foreedge-count">{backlinks.length}</span>
        </span>
      </button>

      <Connections
        id={note.id}
        title={title}
        backlinks={backlinks}
        forwardLinks={forwardLinks}
        open={open}
        close={() => setOpen(false)}
      />
    </>
  )
}

function Connections({
  id,
  title,
  backlinks,
  forwardLinks,
  open,
  close,
}: {
  id: string
  title: string
  backlinks: NoteLink[]
  forwardLinks: NoteLink[]
  open: boolean
  close: () => void
}) {
  const closeRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (!open) return
    closeRef.current?.focus()
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close()
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open, close])

  return (
    <>
      <div
        className="scrim"
        data-open={open}
        onClick={close}
        aria-hidden="true"
      />
      <aside
        id="connections"
        className="drawer"
        data-open={open}
        aria-label="Connections"
        aria-hidden={!open}
        inert={!open}
      >
        <div className="drawer-head">
          <p className="eyebrow">Connections</p>
          <button type="button" ref={closeRef} className="drawer-close" onClick={close}>
            Close
          </button>
        </div>

        <section className="drawer-section">
          <p className="eyebrow">
            Links in<span className="count">{backlinks.length}</span>
          </p>
          {backlinks.length === 0 ? (
            <Empty>Nothing points here yet.</Empty>
          ) : (
            <ul className="links">
              {backlinks.map((l) => (
                <LinkRow key={l.id} link={l} echo={title} onNavigate={close} />
              ))}
            </ul>
          )}
        </section>

        <section className="drawer-section">
          <p className="eyebrow">
            Links out<span className="count">{forwardLinks.length}</span>
          </p>
          {forwardLinks.length === 0 ? (
            <Empty>This note doesn’t link anywhere yet.</Empty>
          ) : (
            <ul className="links">
              {forwardLinks.map((l) => (
                <LinkRow key={l.id} link={l} echo={title} onNavigate={close} />
              ))}
            </ul>
          )}
        </section>

        {open && <Suggested id={id} onNavigate={close} />}

        <Link className="drawer-map" to={`/graph?focus=${encodeURIComponent(id)}`}>
          See this in the graph
        </Link>
      </aside>
    </>
  )
}

function LinkRow({
  link,
  echo,
  onNavigate,
}: {
  link: NoteLink
  /** This note's title. A link description that just repeats it — the
   *  usual case, since that is how one note names another — says nothing
   *  worth a second line. */
  echo: string
  onNavigate: () => void
}) {
  if (link.title === null) {
    return (
      <li className="link-row link-dangling">
        <span className="link-title">This link points at an ID with no note behind it.</span>
        <span className="link-desc">{link.id}</span>
      </li>
    )
  }
  const description =
    link.description && link.description !== link.title && link.description !== echo
      ? link.description
      : null

  return (
    <li className="link-row">
      <Pip band={hopBand(1)} />
      <Link
        to={`/note/${encodeURIComponent(link.id)}`}
        className="link-title"
        onClick={onNavigate}
      >
        {link.title}
      </Link>
      {description && <span className="link-desc">{description}</span>}
    </li>
  )
}

/** Unlinked notes the index thinks belong together — the same nudge the
 *  bot sends after a capture. Loaded only once the drawer is open, so a
 *  note view never pays for it. */
function Suggested({ id, onNavigate }: { id: string; onNavigate: () => void }) {
  const similar = useAsync((signal) => api.similar(id, signal), [id])
  if (similar.state !== 'ready') return null

  const unlinked = similar.value.filter((s) => !s.linked && s.score >= 0.45)
  if (unlinked.length === 0) return null

  return (
    <section className="drawer-section">
      <p className="eyebrow">
        Unlinked, but close<span className="count">{unlinked.length}</span>
      </p>
      <ul className="links">
        {unlinked.map((s) => (
          <li key={s.id} className="link-row">
            <Pip band={scoreBand(s.score)} />
            <Link
              to={`/note/${encodeURIComponent(s.id)}`}
              className="link-title"
              onClick={onNavigate}
            >
              {s.title}
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
