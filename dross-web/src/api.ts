// Typed wrappers over the bot's read-only API (dross-bot/server.go). Every
// shape here mirrors what a dross-mcp tool actually returns — including the
// nulls: forward-links and neighborhood leave title and file null when a
// link points at an ID with no note behind it.

export type Hit = { id: string; title: string; file: string }
export type ScoredHit = Hit & { score: number }
export type SimilarHit = ScoredHit & { linked: boolean }
export type DatedHit = Hit & { mtime: string }

export type NoteLink = {
  id: string
  title: string | null
  file: string | null
  description: string | null
}

export type Note = {
  id: string
  title: string
  file: string
  tags: string[]
  todo: string | null
  /** Indexed body: flattened for search, so not renderable as an outline. */
  content: string
  /** The file verbatim. What the reader renders. */
  raw: string
  mtime: string
  hash: string
}

export type NotePage = {
  note: Note
  backlinks: NoteLink[]
  forwardLinks: NoteLink[]
}

export type GraphNode = {
  id: string
  title: string | null
  file: string | null
  /** Hops from the root — present only for a neighborhood. */
  distance?: number
  /** Outline level — present only for the whole-collection graph. */
  level?: number
}

export type GraphEdge = { from: string; to: string; description?: string | null }
export type Graph = { nodes: GraphNode[]; edges: GraphEdge[] }

/** A failed tool call. The message is the server's own words. */
export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message)
  }
}

async function get<T>(path: string, signal?: AbortSignal): Promise<T> {
  let res: Response
  try {
    res = await fetch(path, { signal })
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') throw e
    throw new ApiError('Cannot reach the notes server.', 0)
  }
  if (!res.ok) {
    const body = await res.json().catch(() => null)
    const message =
      body && typeof body.error === 'string'
        ? body.error
        : `The server answered ${res.status}.`
    throw new ApiError(message, res.status)
  }
  return res.json() as Promise<T>
}

const q = encodeURIComponent

export const api = {
  /** Every note, newest first — the browse list. */
  notes: (signal?: AbortSignal) => get<DatedHit[]>('/api/notes', signal),
  note: (id: string, signal?: AbortSignal) =>
    get<NotePage>(`/api/note/${q(id)}`, signal),
  search: (query: string, signal?: AbortSignal) =>
    get<Hit[]>(`/api/search?q=${q(query)}`, signal),
  semanticSearch: (query: string, signal?: AbortSignal) =>
    get<ScoredHit[]>(`/api/semantic-search?q=${q(query)}`, signal),
  similar: (id: string, signal?: AbortSignal) =>
    get<SimilarHit[]>(`/api/similar/${q(id)}`, signal),
  neighborhood: (id: string, depth: number, signal?: AbortSignal) =>
    get<Graph>(`/api/neighborhood/${q(id)}?depth=${depth}`, signal),
  graph: (signal?: AbortSignal) => get<Graph>('/api/graph', signal),
}

/** Path of an archived attachment, as `[[file:...]]` links spell it. */
export function attachUrl(relative: string): string {
  return '/api/attach/' + relative.split('/').map(q).join('/')
}
