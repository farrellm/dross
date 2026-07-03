# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Dross is an LLM-augmented Zettelkasten built on emacs org-node: plain org
files hold the notes, a Haskell MCP server (`dross-mcp/`) exposes them as
tools, and (later phases) a Go Telegram bot handles capture and proactive
notifications. `CONCEPT.md` is the design document — its **Decisions**
section records settled choices (megaparsec parsing, Postgres/pgvector via
Docker, Voyage embeddings, git-branch proposal staging, single user).
Consult it before making architectural changes, and record new decisions
there.

## Commands

A single root `Makefile` drives the whole repo (`db-*` = Postgres/Docker
index, `bot-*` = the Go bot); run these from the repo root:

```sh
make              # or `make help`: list every target

make db-create    # first time: pgvector/pgvector container + volume + migration
make db-start     # after reboot/db-stop
make db-migrate   # re-apply db/schema.sql (idempotent; this is the only migration mechanism)
make db-psql      # inspect the index
make db-destroy   # drop container + volume (only costs a re-index)

make mcp-build    # cabal build --enable-tests (server + tests)
make mcp-test     # cabal test (single exitcode-stdio suite in test/Spec.hs)
make mcp-run      # cabal run dross-mcp against DROSS_NOTES_DIR (env/.envrc)
make mcp-install  # cabal install into dross-mcp/bin (for `claude mcp add`)
make mcp-watch    # ghcid typecheck/reload loop

make bot-build    # go build -o dross-bot
make bot-run      # build + run (token/notes-dir from env/.envrc; DROSS_MCP_BIN auto-set to the cabal binary)
make bot-watch    # live-reload dev loop via wgo
```

MCP server, from `dross-mcp/` (the `mcp-*` targets above wrap these):

```sh
cabal run dross-mcp -- ~/notes   # run against a notes directory (or set DROSS_NOTES_DIR)
cabal list-bin dross-mcp   # path to the built binary
```

Telegram bot, from `dross-bot/`:

```sh
go vet ./...
go test ./...             # git-proposal + splitter tests always run; the MCP smoke test needs DROSS_MCP_BIN + running DB, skips otherwise
TELEGRAM_TOKEN=... DROSS_NOTES_DIR=~/notes DROSS_TELEGRAM_CHAT_ID=<id> ./dross-bot
./dross-bot send < msg.txt          # one-shot: deliver stdin to the chat
./dross-bot propose proposal/<slug> # one-shot: announce a proposal branch with Approve/Reject buttons
```

The bot spawns `dross-mcp` (found on PATH, or `DROSS_MCP_BIN`) and calls
its tools over stdio — it never writes org files itself (exception: the
proposal buttons run `git merge` / `git branch -D` in the notes repo). With
`DROSS_TELEGRAM_CHAT_ID` unset it refuses captures and replies with the
sender's chat ID (first-time setup).

Proactive jobs: `proactive/run-job.sh <digest|gardening|synthesis>` — cron
+ headless `claude -p` over the dross MCP tools, delivered via the bot's
one-shot modes. The prompt files in `proactive/prompts/` are the job
definitions.

Smoke test: pipe newline-delimited JSON-RPC into the binary (`initialize`,
`tools/list`, `tools/call`), then inspect the index with `make db-psql` or
`docker exec dross-db psql -U dross -d dross -c ...`.
No `jq` on this machine — extract fields from responses with `python3 -c`.
Smoke-testing against a scratch notes dir repoints the shared index to it;
that's safe (rebuildable cache) — the next run against real notes re-indexes.

Host prerequisites: Docker (for the DB) and libpq + pg_config
(`postgresql-libs` on Arch/Manjaro) to build `postgresql-simple`.

The DB listens on `127.0.0.1:5433` (not 5432, to avoid clashing with any
host Postgres). The server reads `DROSS_DB` (libpq connection string); its
built-in default matches the Makefile's container.

## Architecture

**Org files are the source of truth; Postgres is a rebuildable cache.**
Nothing in the database is ever authoritative — `make db-destroy` +
re-index must always be safe. Any new feature that stores state must keep
this invariant or put the state in org files / git instead.

Data flow: org files on disk → megaparsec parser → incremental indexer →
Postgres (tsvector FTS + pgvector) → MCP tools over stdio.

- `src/Dross/Org/Types.hs`, `Org/Parser.hs` — parser for a deliberate
  *subset* of org: headlines, property drawers, tags, `#+keywords`,
  `[[id:...]]` links. Line-oriented (input normalized to trailing-newline
  LF; every line parser consumes its newline — preserve this or `many`
  loops can hang). Malformed drawers degrade to body text rather than
  failing the file. Richer org semantics are intentionally out of scope
  (that's Emacs's job) — don't grow the parser without checking CONCEPT.md.
- `src/Dross/Index.hs` — everything Postgres. A "node" follows org-node
  semantics: the file-level entry (top property drawer `:ID:`) plus any
  headline with its own `:ID:`. Links are attributed to the *nearest
  enclosing node with an ID* (`nodeLinks`), which is what makes `backlinks`
  precise. `refreshIndex` is content-hash driven (SHA-256) and runs at the
  top of **every** tool call — that is the freshness mechanism; there is no
  inotify. Keep it cheap.
- `src/Dross/Mcp/Protocol.hs`, `Mcp/Server.hs` — newline-delimited JSON-RPC
  2.0 over stdio. stdout carries protocol messages only; all diagnostics go
  to stderr (printing to stdout corrupts the MCP stream). Notifications
  (requests without `id`) must never be answered.
- `src/Dross/Tools.hs` — tool schemas + implementations (`search`,
  `semantic-search`, `similar-notes`, `read-note`, `backlinks`,
  `forward-links`, `neighborhood`, `stale-notes`, `recent-notes`,
  `create-note`, `update-note`, `append-note`, `capture`,
  `archive-document`).
  Tool results are JSON encoded into a single MCP text content block; tool
  failures return `isError: true` rather than JSON-RPC errors. Mutations
  follow the decided write policy: atomic temp-file+rename writes and hash
  check-then-refuse — `read-note` returns the file's SHA-256 (hex);
  `update-note`/`append-note` require it and refuse if the file changed
  (the agent re-reads and retries). File-level notes only; `update-note`
  also refuses edits that would drop node IDs still present in the file.
  The raw-text surgery is pure (`src/Dross/Org/Edit.hs`) and covered by
  the test suite.
- `src/Dross/Chunk.hs`, `Dross/Embed.hs` — the embedding pipeline.
  `indexFile` writes headline-level chunks (pure packing in `Chunk`, tested);
  `Embed` is the Voyage HTTP client (`VOYAGE_API_KEY`; `DROSS_EMBED_MODEL`
  overrides `voyage-3.5`, `DROSS_EMBED_URL` the endpoint — useful for a
  local mock when smoke-testing). Vectors are fetched lazily inside
  `semantic-search` and `similar-notes` only (`embedPending`) — no other
  tool touches the network, and a missing key just disables those two
  tools. Embeddings are keyed by `(content_sha256, model)`, not chunk id,
  so they survive re-indexing; only changed content is re-embedded.
  Archived-document extracted text (`archive-document`'s `text` parameter)
  lives in a `.extract.txt` sidecar in the attach dir and is swept —
  hash-driven, like org files — into `doc_chunks` rows attributed to the
  literature note; deliberately *not* FK'd to `nodes` so they survive the
  note file's delete-and-reinsert re-index. `search`, `semantic-search`,
  and `similar-notes` all union them in.
- `src/Dross/Git.hs` — auto-commit (decided policy: every mutation is a
  commit). Commits only the touched paths on the current branch; all git
  output captured (stdout is the MCP stream); failures logged, never
  fatal. `Env`'s `envGit` is detected once at startup.
- `dross-bot/` — Go Telegram bot (`main.go` telegram wiring + capture,
  `mcp.go` minimal MCP stdio client, `outbound.go` one-shot `send`,
  `proposal.go` proposal announce/approve/reject). It is an MCP *client*:
  it spawns `dross-mcp` and routes text/forwards to `capture` (reply
  includes similar-notes nudges, best-effort) and photos/files to
  `archive-document`, so the write policy stays server-side. Single shared
  subprocess guarded by a mutex; restarted once on transport failure.
  Proposal callbacks run git in the notes repo; branch names are validated
  (`proposal/` prefix, slug charset, ≤56 chars) because callback data
  crosses the network.
- `proactive/` — stage-4 scheduled jobs: `run-job.sh` +
  `prompts/{digest,gardening,synthesis}.md`. Prompts are the job
  definitions; synthesis stages proposal branches via a temp git worktree
  (the live checkout never switches branches).
- `docs/notes-CLAUDE.md` — template CLAUDE.md for the *notes* repository:
  Zettelkasten discipline plus the agent-side workflows (inbox processing,
  link suggestion via `similar-notes`, Q&A with citations, literature-note
  drafting). Server tools change → check whether this template needs the
  same update.
- `db/schema.sql` — canonical schema, applied via `make db-migrate`; every
  statement must stay idempotent (`IF NOT EXISTS` / `ON CONFLICT`). The
  `embeddings` table is `vector(1024)` for voyage-3.5, keyed by content
  hash + model.

## Conventions

- GHC2024 + `OverloadedStrings` project-wide (set in the cabal file); any
  other extension goes in a per-file `LANGUAGE` pragma. Keep `-Wall` clean.
- Where-bound helpers that build aeson `Value`s need explicit type
  signatures, or string literals become ambiguous.
- postgresql-simple `query_` results usually need a result-type annotation
  (e.g. `:: IO [(FilePath, Binary ByteString)]`).
- SHA-256 comes from `cryptohash-sha256` deliberately: crypton >=1.1
  dropped `memory`'s ByteArrayAccess, so `BA.convert` on digests no longer
  compiles. Don't "upgrade" back to crypton.
- Duplicate node IDs across files are resolved with `ON CONFLICT DO
  NOTHING` (first file wins) — deliberate, not an oversight.
- Tools that modify an existing note go through `mutateNote` in `Tools.hs`
  (hash check-then-refuse, atomic write, re-index) — don't write files
  directly. Tools writing *fresh* content (`create-note`,
  `archive-document`, append-only `capture`) skip the hash but still use
  `atomicWrite` (see CONCEPT.md Decisions).
- This machine has no passwordless sudo: for system packages, ask the user
  to run the install themselves (e.g. `! sudo pacman -S ...`).
