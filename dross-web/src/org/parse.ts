// A parser for the same deliberate subset of org the server indexes
// (dross-mcp/src/Dross/Org/Parser.hs): headlines, property drawers, tags,
// #+keywords, and [[...]] links, plus the block-level shapes real notes
// actually use — paragraphs, lists, begin/end blocks, tables. Richer org
// semantics are Emacs's job on both sides.
//
// Malformed input degrades to plain text rather than throwing, matching the
// server parser's treatment of broken drawers.

export type Inline =
  | { kind: 'text'; text: string }
  | { kind: 'emphasis'; style: 'bold' | 'italic' | 'underline'; children: Inline[] }
  | { kind: 'code'; text: string }
  | { kind: 'link'; target: string; description: string | null }

export type ListItem = { checkbox: boolean | null; children: Inline[] }

export type Block =
  | { kind: 'heading'; level: number; todo: string | null; title: Inline[]; tags: string[] }
  | { kind: 'paragraph'; children: Inline[] }
  | { kind: 'list'; ordered: boolean; items: ListItem[] }
  | { kind: 'pre'; variant: 'src' | 'quote' | 'example'; language: string | null; text: string }
  | { kind: 'table'; rows: string[][] }

export type ParsedNote = {
  /** #+title, when the file carries one. */
  title: string | null
  /** #+filetags, colon-delimited in the file. */
  filetags: string[]
  blocks: Block[]
}

const TODO_WORDS = new Set(['TODO', 'NEXT', 'DONE', 'WAITING', 'CANCELLED', 'CANCELED'])

/** Chars org allows immediately before an emphasis marker. Without this
 *  rule a URL's slashes italicise half a paragraph. */
const PRE_MARKER = new Set([' ', '\t', '-', '(', '{', "'", '"', '‘', '“'])
const POST_MARKER = new Set([
  ' ', '\t', '-', '.', ',', ';', ':', '!', '?', ')', '}', '[', ']', "'", '"',
  '’', '”',
])

const MARKERS = {
  '*': 'bold',
  '/': 'italic',
  _: 'underline',
} as const

export function parseOrg(source: string): ParsedNote {
  const lines = source.replace(/\r\n?/g, '\n').split('\n')
  const blocks: Block[] = []
  let title: string | null = null
  let filetags: string[] = []

  let i = 0
  while (i < lines.length) {
    const line = lines[i] ?? ''
    const trimmed = line.trim()

    if (trimmed === '') {
      i++
      continue
    }

    // Property drawers belong to the machine, not the reader. An unclosed
    // drawer is malformed, so fall through and render it as text.
    if (/^:[A-Za-z_][A-Za-z0-9_-]*:$/.test(trimmed) && trimmed.toUpperCase() === ':PROPERTIES:') {
      const end = findLine(lines, i + 1, (l) => l.trim().toUpperCase() === ':END:')
      if (end !== -1) {
        i = end + 1
        continue
      }
    }

    const keyword = /^#\+([A-Za-z_]+):\s*(.*)$/.exec(trimmed)
    if (keyword && !/^begin_/i.test(keyword[1] ?? '')) {
      const key = (keyword[1] ?? '').toLowerCase()
      const value = (keyword[2] ?? '').trim()
      if (key === 'title') title = value
      if (key === 'filetags') filetags = splitTags(value)
      i++
      continue
    }

    const heading = /^(\*+)\s+(.*)$/.exec(line)
    if (heading) {
      blocks.push(parseHeading((heading[1] ?? '').length, heading[2] ?? ''))
      i++
      continue
    }

    const begin = /^#\+begin_([a-z]+)\s*(.*)$/i.exec(trimmed)
    if (begin) {
      const name = (begin[1] ?? '').toLowerCase()
      const end = findLine(
        lines,
        i + 1,
        (l) => l.trim().toLowerCase() === `#+end_${name}`,
      )
      const body = lines.slice(i + 1, end === -1 ? lines.length : end)
      blocks.push({
        kind: 'pre',
        variant: name === 'src' ? 'src' : name === 'quote' ? 'quote' : 'example',
        language: name === 'src' ? (begin[2] ?? '').split(/\s+/)[0] || null : null,
        text: body.join('\n'),
      })
      i = end === -1 ? lines.length : end + 1
      continue
    }

    if (trimmed.startsWith('|')) {
      const rows: string[][] = []
      while (i < lines.length && (lines[i] ?? '').trim().startsWith('|')) {
        const row = (lines[i] ?? '').trim()
        // |---+---| separators carry no content.
        if (!/^\|[-+|]*\|?$/.test(row)) {
          rows.push(
            row
              .replace(/^\|/, '')
              .replace(/\|$/, '')
              .split('|')
              .map((c) => c.trim()),
          )
        }
        i++
      }
      if (rows.length > 0) blocks.push({ kind: 'table', rows })
      continue
    }

    if (bulletOf(line) !== null) {
      const { block, next } = parseList(lines, i)
      blocks.push(block)
      i = next
      continue
    }

    // Everything else is a paragraph, running to the next blank line or
    // structural line.
    const start = i
    while (
      i < lines.length &&
      (lines[i] ?? '').trim() !== '' &&
      bulletOf(lines[i] ?? '') === null &&
      !/^\*+\s/.test(lines[i] ?? '') &&
      !(lines[i] ?? '').trim().startsWith('|') &&
      !/^#\+/.test((lines[i] ?? '').trim())
    ) {
      i++
    }
    if (i === start) i++ // never stall
    blocks.push({
      kind: 'paragraph',
      children: parseInline(lines.slice(start, i).join('\n')),
    })
  }

  return { title, filetags, blocks }
}

function findLine(lines: string[], from: number, pred: (l: string) => boolean): number {
  for (let i = from; i < lines.length; i++) if (pred(lines[i] ?? '')) return i
  return -1
}

function splitTags(value: string): string[] {
  return value.split(':').filter((t) => t !== '')
}

function parseHeading(level: number, rest: string): Block {
  let text = rest
  let tags: string[] = []
  const tagMatch = /\s+(:(?:[^\s:]+:)+)\s*$/.exec(text)
  if (tagMatch) {
    tags = splitTags(tagMatch[1] ?? '')
    text = text.slice(0, tagMatch.index)
  }
  let todo: string | null = null
  const first = text.split(/\s+/)[0]
  if (first && TODO_WORDS.has(first)) {
    todo = first
    text = text.slice(first.length).trimStart()
  }
  return { kind: 'heading', level, todo, title: parseInline(text), tags }
}

/** The bullet marker a line opens with, or null. */
function bulletOf(line: string): { ordered: boolean; indent: number; rest: string } | null {
  const m = /^(\s*)(?:([-+])|(\d+)[.)])\s+(.*)$/.exec(line)
  if (!m) return null
  return {
    ordered: m[2] === undefined,
    indent: (m[1] ?? '').length,
    rest: m[4] ?? '',
  }
}

function parseList(lines: string[], start: number): { block: Block; next: number } {
  const first = bulletOf(lines[start] ?? '')
  const ordered = first?.ordered ?? false
  const indent = first?.indent ?? 0
  const items: ListItem[] = []
  let i = start
  let current: string[] = []

  const flush = () => {
    if (current.length === 0) return
    let text = current.join('\n')
    let checkbox: boolean | null = null
    const box = /^\[([ xX-])\]\s*/.exec(text)
    if (box) {
      checkbox = (box[1] ?? '').toLowerCase() === 'x'
      text = text.slice(box[0].length)
    }
    items.push({ checkbox, children: parseInline(text) })
    current = []
  }

  while (i < lines.length) {
    const line = lines[i] ?? ''
    const bullet = bulletOf(line)
    if (bullet && bullet.indent <= indent) {
      flush()
      current.push(bullet.rest)
      i++
      continue
    }
    // A continuation line: indented, non-blank, not a new list at this level.
    if (line.trim() !== '' && (bullet !== null || /^\s+\S/.test(line)) && items.length + current.length > 0) {
      current.push(line.trim())
      i++
      continue
    }
    break
  }
  flush()
  return { block: { kind: 'list', ordered, items }, next: i }
}

const LINK = /\[\[([^\]]+?)\](?:\[([^\]]*?)\])?\]/
const BARE_URL = /\bhttps?:\/\/[^\s<>()[\]]+[^\s<>()[\].,;:!?'"]/

export function parseInline(text: string): Inline[] {
  if (text === '') return []
  const out: Inline[] = []

  const link = LINK.exec(text)
  const url = BARE_URL.exec(text)
  // Whichever comes first; an explicit link wins a tie since it contains
  // the URL rather than the other way round.
  const first =
    link && (!url || link.index <= url.index)
      ? { index: link.index, length: link[0].length, node: linkNode(link) }
      : url
        ? { index: url.index, length: url[0].length, node: linkNode(null, url[0]) }
        : null

  if (first) {
    push(out, parseInline(text.slice(0, first.index)))
    out.push(first.node)
    push(out, parseInline(text.slice(first.index + first.length)))
    return out
  }

  const emph = findEmphasis(text)
  if (emph) {
    push(out, parseInline(text.slice(0, emph.start)))
    out.push(emph.node)
    push(out, parseInline(text.slice(emph.end)))
    return out
  }

  out.push({ kind: 'text', text })
  return out
}

function push(out: Inline[], nodes: Inline[]) {
  for (const n of nodes) out.push(n)
}

function linkNode(match: RegExpExecArray | null, bare?: string): Inline {
  if (bare !== undefined) return { kind: 'link', target: bare, description: null }
  return {
    kind: 'link',
    target: (match?.[1] ?? '').trim(),
    description: match?.[2] === undefined ? null : match[2],
  }
}

/** The leftmost well-formed emphasis run, or null. */
function findEmphasis(
  text: string,
): { start: number; end: number; node: Inline } | null {
  for (let i = 0; i < text.length; i++) {
    const ch = text[i] as string
    const style = ch === '=' || ch === '~' ? 'code' : MARKERS[ch as keyof typeof MARKERS]
    if (!style) continue
    const before = i === 0 ? ' ' : (text[i - 1] as string)
    if (!PRE_MARKER.has(before)) continue
    const after = text[i + 1]
    if (after === undefined || after === ' ' || after === '\t' || after === ch) continue

    for (let j = i + 1; j < text.length; j++) {
      if (text[j] !== ch) continue
      const inner = text.slice(i + 1, j)
      const last = inner[inner.length - 1] as string
      if (last === ' ' || last === '\t') continue
      const next = text[j + 1]
      if (next !== undefined && !POST_MARKER.has(next)) continue
      const node: Inline =
        style === 'code'
          ? { kind: 'code', text: inner }
          : { kind: 'emphasis', style, children: parseInline(inner) }
      return { start: i, end: j + 1, node }
    }
  }
  return null
}
