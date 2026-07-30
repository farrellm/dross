import { describe, expect, it } from 'vitest'
import { parseInline, parseOrg, type Block, type Inline } from './parse'

/** Flatten to text so assertions read like the source. */
function text(nodes: Inline[]): string {
  return nodes
    .map((n) => {
      switch (n.kind) {
        case 'text':
          return n.text
        case 'code':
          return n.text
        case 'emphasis':
          return text(n.children)
        case 'link':
          return n.description ?? n.target
      }
    })
    .join('')
}

function links(nodes: Inline[]): Inline[] {
  return nodes.flatMap((n) =>
    n.kind === 'link' ? [n] : n.kind === 'emphasis' ? links(n.children) : [],
  )
}

describe('document structure', () => {
  it('lifts the title and filetags out and drops the property drawer', () => {
    const doc = parseOrg(
      [
        ':PROPERTIES:',
        ':ID: bcaaec5f-ab33-4a75-906f-b741293a1153',
        ':END:',
        '#+title: Information gain is the JS divergence',
        '#+filetags: :permanent:',
        '',
        'A decision tree scores a candidate split.',
      ].join('\n'),
    )
    expect(doc.title).toBe('Information gain is the JS divergence')
    expect(doc.filetags).toEqual(['permanent'])
    expect(doc.blocks).toHaveLength(1)
    expect(doc.blocks[0]?.kind).toBe('paragraph')
  })

  it('renders an unclosed drawer as text rather than swallowing the note', () => {
    const doc = parseOrg([':PROPERTIES:', ':ID: x', 'the actual note'].join('\n'))
    const rendered = doc.blocks.map((b) => (b.kind === 'paragraph' ? text(b.children) : ''))
    expect(rendered.join('\n')).toContain('the actual note')
  })

  it('reads headline level, TODO keyword, and tags', () => {
    const doc = parseOrg('** TODO Follow this up :reading:urgent:')
    const h = doc.blocks[0] as Extract<Block, { kind: 'heading' }>
    expect(h.kind).toBe('heading')
    expect(h.level).toBe(2)
    expect(h.todo).toBe('TODO')
    expect(text(h.title)).toBe('Follow this up')
    expect(h.tags).toEqual(['reading', 'urgent'])
  })

  it('keeps a headline that merely starts with a capitalised word', () => {
    const h = parseOrg('* Key claims (my words)').blocks[0] as Extract<
      Block,
      { kind: 'heading' }
    >
    expect(h.todo).toBeNull()
    expect(text(h.title)).toBe('Key claims (my words)')
  })

  it('groups paragraphs, lists, and blocks', () => {
    const doc = parseOrg(
      [
        'Opening prose.',
        '',
        '1. Expected surprise -- surprisal is -ln p(x).',
        '2. Hypothesis testing -- expected bits of evidence.',
        '',
        '- a bullet',
        '- [X] a done box',
        '',
        '#+begin_src haskell',
        'nodeText = T.intercalate "\\n"',
        '#+end_src',
      ].join('\n'),
    )
    expect(doc.blocks.map((b) => b.kind)).toEqual([
      'paragraph',
      'list',
      'list',
      'pre',
    ])
    const ordered = doc.blocks[1] as Extract<Block, { kind: 'list' }>
    expect(ordered.ordered).toBe(true)
    expect(ordered.items).toHaveLength(2)
    expect(text(ordered.items[0]!.children)).toContain('Expected surprise')

    const bullets = doc.blocks[2] as Extract<Block, { kind: 'list' }>
    expect(bullets.ordered).toBe(false)
    expect(bullets.items[0]?.checkbox).toBeNull()
    expect(bullets.items[1]?.checkbox).toBe(true)

    const src = doc.blocks[3] as Extract<Block, { kind: 'pre' }>
    expect(src.variant).toBe('src')
    expect(src.language).toBe('haskell')
    expect(src.text).toContain('T.intercalate')
  })

  it('closes an unterminated block at end of file', () => {
    const doc = parseOrg('#+begin_quote\nno end marker')
    const pre = doc.blocks[0] as Extract<Block, { kind: 'pre' }>
    expect(pre.variant).toBe('quote')
    expect(pre.text).toBe('no end marker')
  })

  it('reads a table and drops its rules', () => {
    const doc = parseOrg(['| a | b |', '|---+---|', '| 1 | 2 |'].join('\n'))
    const table = doc.blocks[0] as Extract<Block, { kind: 'table' }>
    expect(table.rows).toEqual([
      ['a', 'b'],
      ['1', '2'],
    ])
  })

  it('terminates on every input', () => {
    for (const weird of ['', '\n\n\n', '*', '* ', '[[', ']]', '/', '**bold**', ':PROPERTIES:']) {
      expect(() => parseOrg(weird)).not.toThrow()
    }
  })
})

describe('inline markup', () => {
  it('reads an id link with a description', () => {
    const nodes = parseInline(
      'as stated in [[id:1f36f920-6199-4ca7-a18f-ababfcad9296][Jensen–Shannon divergence]].',
    )
    const [link] = links(nodes)
    expect(link).toEqual({
      kind: 'link',
      target: 'id:1f36f920-6199-4ca7-a18f-ababfcad9296',
      description: 'Jensen–Shannon divergence',
    })
    expect(text(nodes)).toBe('as stated in Jensen–Shannon divergence.')
  })

  it('reads a link with no description', () => {
    const [link] = links(parseInline('see [[id:abc]] for more'))
    expect(link).toMatchObject({ target: 'id:abc', description: null })
  })

  it('reads a file link', () => {
    const [link] = links(
      parseInline('Local archive: [[file:data/7f/457c03/page.html][page.html]]'),
    )
    expect(link).toMatchObject({ target: 'file:data/7f/457c03/page.html' })
  })

  it('linkifies a bare URL', () => {
    const nodes = parseInline(
      'https://www.lesswrong.com/posts/no5jDTut5Byjqb4j5/six-and-a-half',
    )
    expect(links(nodes)).toHaveLength(1)
  })

  it('does not italicise the slashes in a URL', () => {
    // The failure this guards against: /posts/…/ read as an italic run,
    // which would eat half the paragraph.
    const nodes = parseInline('see https://example.com/a/b/c now')
    expect(nodes.some((n) => n.kind === 'emphasis')).toBe(false)
    expect(text(nodes)).toBe('see https://example.com/a/b/c now')
  })

  it('does not emphasise inside identifiers', () => {
    for (const src of ['content_sha256 and node_id', 'a/b/c', '2*3*4']) {
      const nodes = parseInline(src)
      expect(text(nodes), src).toBe(src)
      expect(nodes.every((n) => n.kind === 'text'), src).toBe(true)
    }
  })

  it('reads bold, italic, underline, and code', () => {
    const cases: [string, string, string][] = [
      ['distribution *is* the mixture', 'bold', 'is'],
      ['the /Jensen gap/ of entropy', 'italic', 'Jensen gap'],
      ['an _underlined_ word', 'underline', 'underlined'],
    ]
    for (const [src, style, inner] of cases) {
      const node = parseInline(src).find((n) => n.kind === 'emphasis')
      expect(node, src).toMatchObject({ style })
      expect(text([node!])).toBe(inner)
    }
    const code = parseInline('the =content_sha256= column').find((n) => n.kind === 'code')
    expect(code).toEqual({ kind: 'code', text: 'content_sha256' })
  })

  it('reads emphasis inside a link description and vice versa', () => {
    const nodes = parseInline('[[id:x][a *bold* title]]')
    const [link] = links(nodes)
    expect(link).toMatchObject({ description: 'a *bold* title' })
  })

  it('leaves an unclosed marker alone', () => {
    expect(text(parseInline('a *dangling marker'))).toBe('a *dangling marker')
    expect(text(parseInline('an [[unclosed link'))).toBe('an [[unclosed link')
  })
})
