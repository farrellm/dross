# CLAUDE.md

## Project

Dross is an LLM-augmented Zettelkasten built on emacs org-node: plain org
files hold the notes, a Haskell MCP server (`dross-mcp/`) exposes them as
tools, a Go Telegram bot handles capture and proactive notifications, and
a React reader (`dross-web/`) serves them to the phone. `CONCEPT.md` is the
design document — its **Decisions**
section records settled choices (megaparsec parsing, Postgres/pgvector via
Docker, Voyage embeddings, git-branch proposal staging, single user).
Consult it before making architectural changes, and record new decisions
there.

Per-subdirectory guidance lives in its own CLAUDE.md, loaded when you work
there: `dross-mcp/` (parser, index, tools, and the Haskell/relude
conventions), `dross-bot/`, `dross-web/`, `proactive/`.

## Commands

A single root `Makefile` drives the whole repo (`db-*` = Postgres/Docker
index, `bot-*` = the Go bot, `web-*` = the React reader); run `make help`
from the repo root for the full list. Note that `make db-migrate`
(re-applying `db/schema.sql`) is the *only* migration mechanism.

`cabal run dross-mcp -- ~/notes` runs the server against a notes directory
(or set `DROSS_NOTES_DIR`); `cabal list-bin dross-mcp` gives the built
binary's path.

Telegram bot, from `dross-bot/`:

```sh
go test ./...             # git-proposal + splitter tests always run; the MCP smoke test needs DROSS_MCP_BIN + running DB, skips otherwise
TELEGRAM_TOKEN=... DROSS_NOTES_DIR=~/notes DROSS_TELEGRAM_CHAT_ID=<id> ./dross-bot
./dross-bot send < msg.txt          # one-shot: deliver stdin to the chat
./dross-bot propose proposal/<slug> # one-shot: announce a proposal branch with Approve/Reject buttons
./dross-bot reextract [--dry-run]   # one-shot: rewrite thin/missing .extract.txt sidecars in the attach tree
DROSS_WEB_ADDR=:8181 ./dross-bot web  # one-shot: serve the reader without Telegram
```

The bot spawns `dross-mcp` (found on PATH, or `DROSS_MCP_BIN`) and calls
its tools over stdio — it never writes org files itself (exceptions: the
proposal buttons run `git merge` / `git branch -D` in the notes repo, and
`reextract` rewrites extract sidecars in place). With
`DROSS_TELEGRAM_CHAT_ID` unset it refuses captures and replies with the
sender's chat ID (first-time setup).

Proactive jobs: `proactive/run-job.sh <digest|gardening|synthesis>` — cron
+ headless `claude -p` over the dross MCP tools, delivered via the bot's
one-shot modes. The prompt files in `proactive/prompts/` are the job
definitions.

Smoke test: pipe newline-delimited JSON-RPC into the binary (`initialize`,
`tools/list`, `tools/call`), then inspect the index with `make db-psql` or
`docker exec dross-db psql -U dross -d dross -c ...`.
Rebuild the binary with `make mcp-build` first: `make mcp-test` relinks only
the library + test suite, not the `dross-mcp` executable, so smoke-testing a
source change straight after `mcp-test` drives a stale binary.
The same trap one level out: the bot (and so the reader) spawns whatever
`DROSS_MCP_BIN` points at — in `.envrc` that's `dross-mcp/bin/dross-mcp`,
the `make mcp-install` symlink, *not* the cabal build output. After a server
change, `make mcp-install` or the bot keeps serving the old tools.
No `jq` on this machine — extract fields from responses with `python3 -c`.
Smoke-testing against a scratch notes dir repoints the shared index to it;
that's safe (rebuildable cache) — the next run against real notes re-indexes.

Host prerequisites: Docker (for the DB) and libpq + pg_config
(`postgresql-libs` on Arch/Manjaro) to build `postgresql-simple`;
`pdftotext` (poppler) for arxiv full-text extraction (optional — the bot
degrades to abstract-only indexing without it).

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

## Conventions

- This machine has no passwordless sudo: for system packages, ask the user
  to run the install themselves (e.g. `! sudo pacman -S ...`).
