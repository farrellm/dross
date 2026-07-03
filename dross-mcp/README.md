# dross-mcp

Haskell MCP server for the Dross note archive (see `../CONCEPT.md`).

## Status: Proactive (roadmap stage 4)

Working:

- **Org parser** (megaparsec) for the Dross subset: headlines, property
  drawers, tags, `#+keywords`/`#+filetags`, and `[[id:...]]` links.
- **MCP stdio server**: JSON-RPC 2.0, `initialize` / `tools/list` /
  `tools/call`.
- **Postgres index** (`Dross.Index`): incremental, content-hash driven;
  refreshed at the top of every tool call so Emacs edits are picked up
  without inotify. The database is a rebuildable cache — org files are the
  source of truth.
- **Tools**: `search` (Postgres FTS + title substring fallback),
  `semantic-search` (Voyage embeddings + pgvector cosine distance),
  `similar-notes` (embedding-similar notes to a given note, with a `linked`
  flag — link-suggestion candidates), `read-note`, `backlinks`,
  `forward-links`, `neighborhood`, `stale-notes` / `recent-notes`
  (least/most recently modified — gardening and digest raw material),
  `create-note`, `update-note`, `append-note`, `capture`,
  `archive-document`. Mutations follow the check-then-refuse write policy
  (hash from `read-note`).
- **Git auto-commit**: when the notes dir is a git repo, every mutation is
  committed — only the touched files, message `dross: <tool>: <title>`,
  signing disabled. Not a repo = disabled with a stderr notice.
- **Embeddings** (`Dross.Chunk` + `Dross.Embed`): notes are chunked at
  headline level during indexing; vectors are fetched from Voyage
  (`voyage-3.5`) lazily inside `semantic-search` / `similar-notes`, keyed
  by chunk content hash so unchanged notes are never re-embedded. Requires
  `VOYAGE_API_KEY` (unset = those two tools disabled, everything else
  works); `DROSS_EMBED_MODEL` overrides the model.
- **Archived-document text**: `archive-document` accepts extracted plain
  text (`text` parameter; extraction is the caller's job) and stores it as
  a `.extract.txt` sidecar in the attach dir. Sidecars are indexed like org
  files (hash-driven) into `doc_chunks` attributed to the literature note,
  so `search`, `semantic-search`, and `similar-notes` cover the archive.
- **Workflows**: `../docs/notes-CLAUDE.md` is the CLAUDE.md template for
  the notes repo — link suggestion, Q&A with citations, literature-note
  drafting. Scheduled proactive jobs (digest, gardening, synthesis with
  Telegram-approved proposals) live in `../proactive/`.

## Database (Docker)

Requires Docker and, for building the Haskell client, libpq on the host
(`sudo pacman -S postgresql-libs` on Arch/Manjaro).

The `db-*` targets live in the repo's root `Makefile` (run from the repo
root, not this directory):

```sh
make db-create    # first time: container + volume + migration
make db-start     # after a reboot or db-stop
make db-migrate   # re-apply db/schema.sql (idempotent)
make db-psql      # poke at the index
make db-destroy   # drop everything (costs a re-index, nothing more)
```

The server reads the connection string from `DROSS_DB`; the default matches
the Makefile's container
(`host=127.0.0.1 port=5433 dbname=dross user=dross password=dross`).

## Build and test

The `mcp-*` targets in the repo's root `Makefile` wrap these (run from the
repo root): `make mcp-build`, `make mcp-test`, `make mcp-watch` (a `ghcid`
typecheck loop).

```sh
cabal build
cabal test
```

## Run

`make mcp-run` from the repo root, or directly:

```sh
DROSS_NOTES_DIR=~/notes cabal run dross-mcp
# or: cabal run dross-mcp -- ~/notes
```

Set `VOYAGE_API_KEY` in the server's environment to enable
`semantic-search` (`DROSS_EMBED_MODEL` overrides `voyage-3.5`,
`DROSS_EMBED_URL` points at a different provider or a test mock);
without the key the server runs with that one tool disabled. Nothing loads
`.env` — export the variable or put it in the MCP client's server config.

Register with Claude Code (using the built binary so startup is instant):

```sh
cabal install --installdir=bin --overwrite-policy=always
claude mcp add dross --env VOYAGE_API_KEY=... -- $(pwd)/bin/dross-mcp ~/notes
```
