# dross-mcp

Haskell MCP server for the Dross note archive (see `../CONCEPT.md`).

## Status: MVP

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
  `read-note`, `backlinks`, `create-note`.

Not yet wired: Voyage embeddings, `semantic-search`, git auto-commit,
the check-then-refuse write policy for note edits.

## Database (Docker)

Requires Docker and, for building the Haskell client, libpq on the host
(`sudo pacman -S postgresql-libs` on Arch/Manjaro).

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

```sh
cabal build
cabal test
```

## Run

```sh
DROSS_NOTES_DIR=~/notes cabal run dross-mcp
# or: cabal run dross-mcp -- ~/notes
```

Register with Claude Code (using the built binary so startup is instant):

```sh
cabal install --installdir=bin --overwrite-policy=always
claude mcp add dross -- $(pwd)/bin/dross-mcp ~/notes
```
