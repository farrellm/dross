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
  - `similar-notes` — embedding-similar notes to a given note (link-suggestion candidates)
  - `read-note` / `create-note` / `append-note` / `update-note`
  - `remove-entry` — delete an ID-bearing headline (e.g. a processed inbox entry)
  - `backlinks` / `forward-links` / `neighborhood` (n-hop link graph around a note)
  - `stale-notes` / `recent-notes` — least/most recently modified notes
    (gardening pool, digest raw material)
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
  **Docker** (`pgvector/pgvector` image), managed via the root `Makefile`.
- Embeddings: **Voyage AI** (`voyage-3.5`) for vectors, searched via
  pgvector cosine distance (see Embeddings).
- Embedding storage: keyed by **`(content_sha256, model)`**, not chunk id —
  re-indexing a file deletes and re-inserts its nodes and chunks, and
  hash-keyed embeddings survive that, so only genuinely new content hits
  the API. Orphaned vectors from edited-away content are tolerated
  (harmless at personal scale; prunable with one SQL statement).
- Embedding runs **only inside the embedding-backed tools**
  (`semantic-search` and `similar-notes`, as a catch-up before the query):
  every other tool — including capture — never touches the network, and a
  Voyage outage degrades search to existing embeddings instead of slowing
  anything else down. Configured via `VOYAGE_API_KEY` (unset = those two
  tools disabled, everything else unaffected) and optional
  `DROSS_EMBED_MODEL`.
- Embedding scope: org notes **and archived-document extracted text**
  (phase one was notes-only; the extract ingestion path landed with the
  Augment stage — see the extracted-text decision below).
- Link suggestion split: the server provides **embedding candidates** via
  `similar-notes` (each with a `linked` flag for links already present in
  either direction); filtering candidates by judgment and proposing actual
  edits stays with the agent. Suggested links are ordinary note edits and
  go through the normal write policy.
- Extracted document text: `archive-document` takes an optional **`text`**
  parameter (extraction itself — pdftotext, OCR, readability — remains the
  client agent's job) and stores it as a **`.extract.txt` sidecar in the
  attach dir**, so disk stays the source of truth and the index stays a
  rebuildable cache. The indexer sweeps sidecars like org files
  (hash-driven) into `doc_chunks` rows attributed to the literature note
  whose ID the attach path encodes; `search`, `semantic-search`, and
  `similar-notes` all cover them, attributing hits to the literature note.
  A dotfile name keeps org-attach listings clean; a sidecar can also be
  dropped into an attach dir by hand and is picked up on the next sweep.
- Git auto-commit: every mutating tool commits **only the files it
  touched** (concurrent Emacs edits are never swept in) on the current
  branch, message `dross: <tool>: <title>`, gpg signing forced off so a
  prompt can never hang the server. Failures are logged and swallowed —
  the note is already on disk. Notes dir not a git repo = auto-commit
  disabled with a stderr notice, everything else unaffected.
- Proposal staging: **git branch per proposal** (`proposal/<id>`). Approve =
  merge to main (fast-forward when possible); reject = delete branch. Diffs,
  conflict detection, and audit come free from git; the Telegram approval
  message shows the branch's diff summary.
- Proposal mechanics: jobs stage proposals in a **temporary `git worktree`**
  of the notes repo, so the live checkout never leaves the user's branch
  and a crashed job leaves only an inert branch. `dross-bot propose
  <branch>` announces it (diff summary + inline Approve/Reject); the
  serving bot handles the button callbacks — approve merges into the
  current checkout and deletes the branch (failed merges abort cleanly and
  keep the branch), reject deletes it. Callback data is validated hard:
  `proposal/` prefix, conservative slug charset, ≤56 chars (Telegram's
  64-byte callback limit).
- Proactive jobs (digest / gardening / synthesis) are **cron + headless
  Claude** (`proactive/run-job.sh` + per-job prompt files, which *are* the
  job definitions): `claude -p` composes over the dross MCP tools with an
  explicit tool allowlist, and delivery goes through the bot's one-shot
  `dross-bot send` / `dross-bot propose` modes — the bot stays the only
  component that talks to Telegram. Digest and gardening are read-only;
  only synthesis stages proposals.
- Capture nudges: the bot's capture confirmation appends "connects to"
  lines from `similar-notes` (score ≥ 0.5, not already linked, top 3),
  best-effort — nudge failures never block the capture.
- Inbox: a **single `inbox.org`** in the notes root (`#+filetags: :inbox:`,
  bootstrapped on first capture); each capture is a top-level headline with
  its own `:ID:`, a `:CREATED:` timestamp, and optional `:SOURCE:`.
- `capture` is append-only and **exempt from the hash check** — it inserts
  fresh content without a prior read, so there is nothing to go stale. All
  other mutations keep check-then-refuse.
- Entry removal is a **dedicated `remove-entry` tool**, not an `update-note`
  flag: `update-note`'s ID-preservation guard (never silently orphan a note's
  ID) stays strict, and deleting an ID-bearing headline — the inbox-clearing
  case, where the entry *is* the ID-bearing headline — is an explicit, targeted
  operation instead. It keeps the same check-then-refuse write policy (the
  entry's own `:ID:` + the parent file's hash), so inbox processing never has
  to fall back to a raw `inbox.org` edit.
- Telegram bot wiring: the bot (`dross-bot/`) is an **MCP client of
  dross-mcp** — it spawns the server as a subprocess and speaks
  newline-delimited JSON-RPC over stdio, so every write goes through the
  decided write policy (atomic writes, IDs, indexing) instead of
  reimplementing it in Go. Text/forwards → `capture` (forwards
  credit the origin in `:SOURCE:`); photos and files are downloaded and
  fed to `archive-document`, caption first line as title. Every archive
  (photo, file, or URL) is followed by a best-effort `capture` of an inbox
  entry whose body links `[[id:...]]` to the fresh stub note — that entry
  is the triage marker; processing it means fleshing out the linked note,
  then deleting the entry. Config is
  env-only: `TELEGRAM_TOKEN`, `DROSS_NOTES_DIR`, `DROSS_TELEGRAM_CHAT_ID`
  (the allowlist; unset = refuse and reply with the sender's chat ID for
  first-time setup), optional `DROSS_MCP_BIN`.
- Document archive: **org-attach uuid-folder layout** —
  `data/<2 chars>/<rest of id>/` under the notes root, matching Emacs
  org-attach defaults so `org-attach-open` works. The literature note links
  to the copy with a relative `file:` link, carries `:SOURCE:` in its
  drawer, and is tagged `:literature:ATTACH:`. `archive-document` takes a
  **local file path** (plus optional **`extra_paths`** for further files —
  all land in the same attach dir, each linked from the note body) — URL
  fetching and text extraction are the client agent's job; extracted text
  is passed via the `text` parameter and indexed (see the extracted-text
  decision above).
- URL capture: a message whose **first whitespace token is an http(s)
  URL** is archived, not inboxed — the bot snapshots the page with
  **obelisk** (one self-contained HTML file, resources inlined as data
  URIs, JS stripped) and extracts title/plain text with **go-readability**
  (deprecated upstream; migration target is
  `codeberg.org/readeck/go-readability/v2`), then calls `archive-document`
  with the snapshot, the URL as `:SOURCE:`, any trailing message text as
  the body, and extracted text for indexing. The stub note is plain
  `:literature:ATTACH:` — triage sees it via the inbox entry the bot
  appends afterwards (see the bot-wiring decision above), not via an extra
  tag. Fetch/archive failure (or a snapshot over 50 MB) falls back to
  plain `capture`, so the URL is never lost; JS-rendered pages archive as
  shells (the bot's reply says so). URL fetching stays the client's job —
  the server only gained the generic `extra_paths` parameter.
- Arxiv capture: any arxiv paper link (`/abs/`, `/pdf/`, or `/html/`, any
  arxiv host) is **normalized** — the bot snapshots the `/abs/` page for
  title + abstract and downloads the PDF alongside via `extra_paths`, so
  one literature note holds both. Full text is extracted with
  **pdftotext** (poppler, found on PATH) and replaces the abstract as the
  indexed `text`; both the PDF download and extraction are best-effort —
  failure keeps the snapshot-only archive and the reply says what's
  missing. The original URL, not the normalized one, is the `:SOURCE:`.

