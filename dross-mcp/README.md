# dross-mcp

Haskell MCP server for the Dross note archive (see `../CONCEPT.md`).

## Status: MVP scaffold

Working:

- **Org parser** (megaparsec) for the Dross subset: headlines, property
  drawers, tags, `#+keywords`/`#+filetags`, and `[[id:...]]` links.
- **MCP stdio server**: JSON-RPC 2.0, `initialize` / `tools/list` /
  `tools/call`.
- **Tools**: `search` (naive in-memory scan — every call re-reads the notes
  dir), `read-note`, `create-note`.

Not yet wired:

- The Postgres index (`db/schema.sql` is ready; the Haskell side needs
  libpq headers installed before adding `hasql`/`postgresql-simple`).
- Voyage embeddings, `semantic-search`, `backlinks`, git auto-commit,
  inotify watching.

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

## Postgres setup (for the upcoming index)

Requires PostgreSQL with the [pgvector](https://github.com/pgvector/pgvector)
extension:

```sh
createdb dross
psql dross < db/schema.sql
```
