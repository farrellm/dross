# CLAUDE.md — Zettelkasten notes

Template for the *notes* repository (copy to `~/notes/CLAUDE.md` and adjust).
It encodes the working discipline for an agent using the `dross` MCP tools;
see `CONCEPT.md` in the dross repo for the system design.

## Ground rules

- All reads and writes go through the dross MCP tools (`search`,
  `semantic-search`, `similar-notes`, `read-note`, `create-note`,
  `update-note`, `append-note`, `capture`, `archive-document`,
  `backlinks`, `forward-links`, `neighborhood`) — never edit org files
  directly. If `update-note`/`append-note` report a hash conflict, re-read
  the note and retry.
- You may capture and *propose* freely; restructuring, retagging, splitting,
  or deleting existing permanent notes needs my explicit approval first.
- Cite notes as org links: `[[id:<uuid>][<note title>]]`.

## Note discipline

- Note types by tag: `:inbox:` (raw captures), `:literature:` (notes on a
  source), `:permanent:` (atomic ideas), `:hub:` (maps of content).
- **Atomic notes**: one idea per permanent note. If a draft makes two
  claims, propose two notes.
- **Titles are claims, not topics**: "Spaced review counteracts exponential
  forgetting", not "Memory notes".
- **Link over tag**: tags mark type and broad area; relationships between
  ideas are links, ideally with a phrase in the surrounding text saying
  *why* the link holds.
- Permanent notes are in my own words; quotes stay in literature notes with
  locators.

## Workflows

### Inbox processing

For each `:inbox:` entry (find them via `search` for tag inbox / read
`inbox.org`): draft a properly titled, tagged permanent or literature note;
run link suggestion (below); show me the draft (with proposed links) for
approval before creating it and before removing anything from the inbox.

### Link suggestion

After creating or substantially editing a note:

1. `similar-notes` on it; ignore results already `linked: true`.
2. Judge each candidate — suggest a link only when you can state the
   relationship in one sentence (supports, contradicts, generalizes,
   example of, …); embedding similarity alone is not a reason.
3. Propose links in *both* directions where they belong: add to the new
   note directly; edits to existing notes are proposals needing approval.
   Weave links into the text with the relationship phrase, or under a
   `Related` heading when they don't fit the prose.

### Q&A with citations

Answer questions from the archive: `semantic-search` + `search` to gather
candidates, `read-note` the plausible ones (follow `backlinks` /
`neighborhood` one hop when context is thin), then answer **citing note IDs
as org links** for every claim taken from a note. Say so plainly when the
archive doesn't answer the question — don't pad with general knowledge
without flagging it as such. Offer to capture substantial answers via
`capture` (source: the question), so good syntheses can graduate to
permanent notes.

### Literature notes for documents

When archiving a document: extract its plain text (e.g. `pdftotext`) and
pass it as `archive-document`'s `text` parameter so the document is
searchable. Then draft the literature note body: what the source is, its
key claims in my words, notable quotes with locators (page/section), each
on its own line so they can be cited individually. Run link suggestion
against existing notes; propose permanent notes for ideas worth extracting.
