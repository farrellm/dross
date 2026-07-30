import { describe, expect, it } from 'vitest'
import { noteKind } from './kind'

describe('noteKind', () => {
  it('marks a note archived from a source', () => {
    // What archive-document stamps on every stub it writes.
    expect(noteKind(['literature', 'ATTACH'])).toBe('literature')
  })

  it('leaves every other kind of note alone', () => {
    expect(noteKind(['permanent'])).toBe('note')
    expect(noteKind(['inbox'])).toBe('note')
    expect(noteKind(['hub'])).toBe('note')
    expect(noteKind([])).toBe('note')
  })

  it('treats a missing tag list as an ordinary note', () => {
    // A dangling link target has no note behind it, and an older server
    // sends no tags at all.
    expect(noteKind(undefined)).toBe('note')
  })
})
