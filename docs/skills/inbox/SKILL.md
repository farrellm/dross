---
name: inbox
description: Process the Zettelkasten inbox — turn raw captures in inbox.org into properly titled, tagged, linked permanent or literature notes, one at a time with my approval, and clear each processed entry. Use this whenever I ask to process, triage, clear, empty, or go through the inbox or my captures, or to deal with the links and documents I sent from my phone, even if I don't say "inbox".
---

# Inbox processing

The procedure behind "Inbox processing" in CLAUDE.md. That section is the
policy (draft, link, approve, then remove); this is how to run it
efficiently. Nothing is created and nothing leaves the inbox without my
approval of that specific entry.

## Arguments

An optional maximum number of entries, e.g. `/inbox 5`. Default: work through
them all, oldest first, until I stop.

## 1. Survey

`search` for "inbox" (or find `inbox.org`'s file-level note), then
`read-note` it with `raw: true` — you need each entry's headline and its own
`:ID:` property, which the flattened content strips. Show a numbered
overview: one line per entry with its date, a gist, and your guess at its
kind:

- **idea** — my own thought → a `:permanent:` note
- **source** — the body links `[[id:...]]` to a stub literature note the bot
  created from a URL or document → flesh out that stub
- **question / task / fragment** — may fold into an existing note, or not be
  worth keeping
- **duplicate / junk** — propose clearing it without a note

Let me reorder, skip, or batch-dismiss before starting.

## 2. One entry at a time

For each entry:

1. **Gather context** — `semantic-search` and `search` on its content to find
   what the archive already says. An existing note covering the idea changes
   the plan from "new note" to "extend that note" (a proposal, since it edits
   an existing note).
2. **Draft**
   - *idea* — a permanent note: a title that is a claim, one idea per note (if
     the capture makes two claims, draft two notes), in my words, tags
     `permanent` plus any broad-area tag already in use.
   - *source* — `read-note` the stub. Check its text actually got indexed: a
     stub with no extract, or one that is little more than the page title, is
     archived but unsearchable — see "Literature notes for documents" in
     CLAUDE.md for the repair, and don't re-run `archive-document`. Then draft
     the literature body from the indexed text: what the source is, key claims
     in my words, notable quotes with locators each on its own line. Keep the
     stub's existing tags (`literature`, `ATTACH`). Note any permanent notes
     worth extracting as separate proposals.
3. **Link suggestion** — for a new note, draft it first and use `semantic-search`
   on its text for candidates (`similar-notes` needs a note ID, so run it after
   creation); for a stub, `similar-notes` works right away. Keep only links
   whose relationship you can state in a clause, and write that phrase into
   the draft.
4. **Present** — show the draft (title, tags, body with links) plus any
   proposed back-links into existing notes, and wait. I may edit, approve,
   skip (leave the entry), or say to drop it.
5. **Apply on approval**
   - `create-note` (title, tags, body), or `update-note` the stub with its
     hash from `read-note`.
   - For a new note, run `similar-notes` on it now, and propose anything the
     semantic search missed.
   - Make approved back-link edits in existing notes.
   - Clear the entry: re-`read-note` the inbox to get a **fresh hash** — every
     `remove-entry` and every new capture changes it — then `remove-entry` with
     the entry's own `:ID:` and that hash. On a conflict, re-read and retry.
     Never edit `inbox.org` directly.

**Folding into an existing note.** If the entry (especially a source stub)
belongs in an existing note rather than its own, say so and propose it. A stub
with attachments can't just be deleted: its attach dir has to move to the
surviving note's ID, or the archived text silently drops out of search — the
git steps are in CLAUDE.md's inbox-processing section. It edits an existing
note, so get explicit approval first.

## 3. Wrap up

When done (or when I stop), summarise: notes created or updated (as
`[[id:<uuid>][<title>]]`), entries cleared, entries skipped and still waiting.
