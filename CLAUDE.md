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

All from `dross-mcp/`:

```sh
cabal build --enable-tests   # build server + tests
cabal test                   # parser test suite (single exitcode-stdio suite in test/Spec.hs)
cabal run dross-mcp -- ~/notes   # run against a notes directory (or set DROSS_NOTES_DIR)

make db-create    # first time: pgvector/pgvector container + volume + migration
make db-start     # after reboot/db-stop
make db-migrate   # re-apply db/schema.sql (idempotent; this is the only migration mechanism)
make db-psql      # inspect the index
make db-destroy   # drop container + volume (only costs a re-index)
```

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
  `read-note`, `backlinks`, `create-note`). Tool results are JSON encoded
  into a single MCP text content block; tool failures return
  `isError: true` rather than JSON-RPC errors.
- `db/schema.sql` — canonical schema, applied via `make db-migrate`; every
  statement must stay idempotent (`IF NOT EXISTS` / `ON CONFLICT`). The
  `embeddings` table is `vector(1024)` for voyage-3.5.

## Conventions

- GHC2024 + `OverloadedStrings` project-wide (set in the cabal file); any
  other extension goes in a per-file `LANGUAGE` pragma. Keep `-Wall` clean.
- Where-bound helpers that build aeson `Value`s need explicit type
  signatures, or string literals become ambiguous.
- Duplicate node IDs across files are resolved with `ON CONFLICT DO
  NOTHING` (first file wins) — deliberate, not an oversight.
