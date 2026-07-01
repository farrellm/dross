# Dross

Integrated note taking and document archive built on org-node. An LLM-augmented
Zettelkasten: raw captures are the dross; the agent helps refine them into
permanent notes.

## Principles

- **Plain org files are the source of truth.** Everything remains fully usable
  from Emacs with org-node alone; Dross degrades gracefully to "just my notes".
- **The agent proposes, the human curates.** Agents may capture and suggest
  freely, but restructuring or deleting permanent notes requires approval.
- **Git is the safety net.** Every agent-initiated change is a commit with a
  meaningful message — auditable, revertable, and doubles as sync.
- **Local-first.** The only network dependencies are the LLM API, the Voyage
  embedding API, and Telegram. Everything else — files, index, search over
  existing embeddings — works offline.

## Data model

- Notes are org files following org-node conventions: `:ID:` properties,
  links by ID, tags, `#+filetags`.
- Zettelkasten note types, distinguished by tag or directory:
  - **inbox** — raw captures, unprocessed
  - **literature** — notes on a source (paper, book, article, conversation)
  - **permanent** — atomic ideas in my own words, densely linked
  - **hub/MOC** — maps of content that structure a topic
- Document archive via `org-attach`: each archived document (PDF, web clip,
  email) gets a literature note; the file itself lives in the attach dir.
  Extracted text is indexed so documents are searchable and citable.

## Backend (Haskell)

Lives in the `dross-mcp/` directory.

- MCP server exposing the archive as tools:
  - `search` — full-text + tag + date-range queries
  - `semantic-search` — embedding similarity over notes and extracted document text
  - `read-note` / `create-note` / `append-note` / `update-note`
  - `backlinks` / `forward-links` / `neighborhood` (n-hop link graph around a note)
  - `capture` — append to inbox with timestamp and source metadata
  - `archive-document` — store a file/URL, create its literature note
- Maintains its own index (PostgreSQL: full-text via `tsvector`, vectors via
  `pgvector`) built by parsing org files directly; watches the notes
  directory (inotify) so edits made in Emacs are picked up immediately. The
  database is a rebuildable cache — org files remain the source of truth.
- Write safety (decided policy): atomic writes; refuse to modify a file that
  changed since read (compare mtime/hash) and report the conflict back to the
  agent to re-read and retry; every mutation batched into a git commit.

### Org parsing strategy

**Decided: native Haskell parser built on megaparsec.** No runtime Emacs
dependency. Purpose-built for the subset Dross needs — headlines, property
drawers, links, tags, timestamps, `#+filetags` — not full org semantics.
Anything gnarlier (agenda semantics, complex refiling) stays out of scope for
the server; that's what Emacs is for.

### Embeddings

**Decided: Voyage AI + PostgreSQL/pgvector.** Vectors come from the Voyage
API (`voyage-3.5`; drop to `-lite` if cost ever matters — it won't at
personal scale) and live in a `vector` column via the pgvector extension, in
the same database as the full-text index. At personal scale (~10³–10⁵
chunks) pgvector's default exact scan is plenty; add an HNSW index later if
it ever isn't. Cosine distance in SQL means search is one query joining
text rank and vector similarity.

Implementation notes:

- Abstract an `Embedder` interface (it's just "POST text, get vector" over
  HTTP) so swapping providers, or moving to a local model later, is config.
- Record model name + version alongside each vector — re-embedding on a model
  change becomes a queryable migration, not a flag day.
- Chunk long notes at the headline level rather than embedding whole files.
- Embed extracted document text with the same pipeline so `semantic-search`
  covers the archive, not just notes.
- Batch and cache: embed on index update (content-hash keyed), never on
  query except for the query string itself.

## Frontends

- **Claude Code** — primary interactive interface. A specialized CLAUDE.md
  encodes Zettelkasten discipline: atomic notes, titles as claims not topics,
  when to split a note, when to link vs. tag, literature → permanent workflow.
- **Emacs** — direct editing as always; additionally, the agent can be driven
  from inside Emacs via the Agent Client Protocol (ACP) so note work doesn't
  require leaving the editor.
- **Telegram bot (Go)** — mobile capture and the agent's channel for
  *initiating* contact. Go is a deliberate choice: mature bot libraries and a
  single static binary for deployment.
  - inbound: quick capture (text, links, photos, forwards) → inbox
  - outbound: daily/weekly digests, resurfaced stale notes, "this new capture
    connects to [[X]]" nudges, review queue prompts
  - **approval UX**: agent proposals (restructures, deletions, retags, drafted
    hub notes) arrive as messages with inline buttons — approve / reject /
    open in Claude Code for discussion. Each proposal is staged on its own
    git branch; approve merges it, reject deletes it.
- **React webapp** — deferred. Candidate uses if it ever earns its keep:
  link-graph visualization, mobile *reading* (Telegram covers writing), and a
  review-queue UI for approving agent proposals. Revisit after the Telegram
  loop proves out.

## LLM augmentation

Roughly ordered by value:

1. **Inbox processing** — turn raw captures into properly titled, tagged,
   linked notes; propose splits into atomic permanent notes for approval.
2. **Link suggestion** — on note creation/edit, propose connections
   (embedding candidates filtered by LLM judgment), including links *from*
   existing notes back to the new one.
3. **Q&A with citations** — answer questions over the archive, citing note
   IDs; answers can themselves be captured as notes.
4. **Literature note extraction** — given an archived document, draft the
   literature note: summary, key claims, quotes with locators.
5. **Synthesis** — periodically detect clusters of related notes lacking a
   hub note and draft one; surface emergent themes in a weekly digest.
6. **Gardening** — resurface old notes for review (spaced-repetition-ish);
   flag near-duplicates and contradictions between notes.
7. **Ontology maintenance** — keep the tag set coherent: suggest merges,
   detect drift, retag on approval.

## Architecture sketch

```
                      ┌─────────────┐
   Emacs (org-node) ──┤             │
                      │  org files  │◄── git (history, audit, sync)
        ┌────────────►│  + attach/  │
        │             └──────▲──────┘
        │                    │ inotify / atomic writes
        │             ┌──────┴──────┐
        │             │ Haskell MCP │── Postgres (tsvector + pgvector)
        │             └──────▲──────┘
        │                    │ MCP
        │             ┌──────┴──────┐
        └── ACP ──────┤ Claude agent│
                      └──▲───────▲──┘
                         │       │
                  Claude Code   Telegram bot (Go)
                  (interactive) (capture + proactive)
```

## Roadmap

1. **MVP** — Haskell MCP server: parse, index, search, read/create notes.
   Use through Claude Code with the Zettelkasten CLAUDE.md. Git auto-commit.
2. **Capture** — Telegram bot inbound → inbox; inbox-processing workflow.
3. **Augment** — link suggestion, Q&A with citations, literature extraction.
4. **Proactive** — scheduled digests, gardening, synthesis via Telegram.
5. **Maybe** — webapp (graph view, review queue), multi-device beyond git.

## Decisions

- Org parsing: native Haskell parser on **megaparsec**; no Emacs delegation.
- Concurrent edits: hash/mtime check-then-refuse; conflicts bounce back to the
  agent to re-read and retry.
- Approval UX: **Telegram inline buttons** on proposal messages.
- Telegram bot in **Go** (bot-library maturity, static-binary deployment).
- **Single user.** No auth model beyond a Telegram chat-ID allowlist and a
  local-only MCP server; no per-user namespacing anywhere.
- Index database: **PostgreSQL** — `tsvector` for full-text, **pgvector**
  for embeddings; a rebuildable cache, never the source of truth. Runs in
  **Docker** (`pgvector/pgvector` image), managed via `dross-mcp/Makefile`.
- Embeddings: **Voyage AI** (`voyage-3.5`) for vectors, searched via
  pgvector cosine distance (see Embeddings).
- Proposal staging: **git branch per proposal** (`proposal/<id>`). Approve =
  merge to main (fast-forward when possible); reject = delete branch. Diffs,
  conflict detection, and audit come free from git; the Telegram approval
  message shows the branch's diff summary.

