# CLAUDE.md — dross-mcp

The Haskell MCP server. See the repo-root `CLAUDE.md` for the project
overview, the build/run commands, and the smoke-test procedure.

## Architecture

- `src/Dross/Org/Types.hs`, `Org/Parser.hs` — parser for a deliberate
  *subset* of org: headlines, property drawers, tags, `#+keywords`,
  `[[id:...]]` links. Line-oriented (input normalized to trailing-newline
  LF; every line parser consumes its newline — preserve this or `many`
  loops can hang). Malformed drawers degrade to body text rather than
  failing the file. Richer org semantics are intentionally out of scope
  (that's Emacs's job) — don't grow the parser without checking CONCEPT.md.
  The `import Prelude hiding (many)` is load-bearing: megaparsec's `many`
  comes from parser-combinators and is a *different* entity from the
  `Alternative` one relude re-exports, so both in scope is ambiguous.
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
- `src/Dross/Tools.hs` — tool schemas + implementations.
  `read-note`'s `content` is the *indexed* body — `collectNodes` flattens it
  for search, dropping headline stars, TODO keywords, and drawers — so
  anything rendering an outline must pass `raw: true` and use that instead.
  `graph` is the whole collection at once; `neighborhood` is the one to
  reach for around a single note (its recursive CTE revisits cycles, so a
  large `depth` is both expensive and not a substitute).
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
  and `similar-notes` all union them in. Because the sweep is by directory
  and not per-note bookkeeping, a document archived without text — or with
  a title-only one — can be repaired in place: `dross-bot reextract` sweeps
  the tree and rewrites thin sidecars, or write one by hand
  (`pdftotext file.pdf > .extract.txt` in its attach dir). Either way the
  next tool call picks it up. Never re-run `archive-document` to fix this:
  that mints a duplicate note.
- `src/Dross/Git.hs` — auto-commit (decided policy: every mutation is a
  commit). Commits only the touched paths on the current branch; all git
  output captured (stdout is the MCP stream); failures logged, never
  fatal. `Env`'s `envGit` is detected once at startup.
- `db/schema.sql` — canonical schema, applied via `make db-migrate`; every
  statement must stay idempotent (`IF NOT EXISTS` / `ON CONFLICT`). The
  `embeddings` table is `vector(1024)` for voyage-3.5, keyed by content
  hash + model.
- `docs/notes-CLAUDE.md` (at the repo root) — template CLAUDE.md for the
  *notes* repository: Zettelkasten discipline plus the agent-side workflows
  (inbox processing, link suggestion via `similar-notes`, Q&A with
  citations, literature-note drafting). Server tools change → check whether
  this template needs the same update.

## Conventions

- **relude is the prelude**, wired up by `mixins:` in the `common shared`
  stanza of `dross-mcp.cabal` (not `NoImplicitPrelude` + `import Relude`) —
  so don't add `import Relude` to modules. When a name clashes, hide
  relude's with `import Prelude hiding (...)`, as `Org/Parser.hs` does for
  megaparsec's `many`.
- **Never import `Relude.Unsafe`** — it re-introduces the partial functions
  (`head`, `fromJust`, `read`, `!!`) relude removed, and this codebase has
  none. The `mixins` stanza doesn't expose it, so importing it is a compile
  error; if you're tempted to widen the stanza, reach for the total version
  instead (`viaNonEmpty head`, `fromMaybe`, `readMaybe`, `!!?`).
  `Relude.Extra` *is* exposed and is fair game.
- No `T.pack`. relude's `show` is `(Show a, IsString b) => a -> b`, so it
  produces `Text` directly — write `show e`, not `T.pack (show e)`. For a
  plain `String` (or `FilePath`), use `toText`. `T.unpack` still has its
  uses; its relude counterpart is `toString`.
- relude re-exports less than its docs suggest. It gives you `stdout`,
  `stderr`, `hFlush`, `hSetBuffering`, `BufferMode`, `die`, `exitFailure`,
  `getArgs`, `lookupEnv`, and the `IORef` API — but **not** `hPutStrLn`,
  `isEOF`, `ExitCode`, or `try`, so those keep their explicit `System.IO` /
  `System.Exit` / `Control.Exception` imports. Check the actual export list
  before assuming.
- GHC2024, set once in `common shared`, is the only language setting in the
  cabal file. *Every* extension, `OverloadedStrings` included, goes in a
  per-file `LANGUAGE` pragma. All library modules and the test suite carry
  `OverloadedStrings`; `app/Main.hs` needs no extensions.
- **Always fix compiler warnings.** `-Wall` is on for every stanza and the
  tree is warning-clean; keep it that way. Under relude a redundant import
  warning means the name now comes from the prelude — delete the import
  rather than silence the warning.
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
  directly. `remove-entry` is the exception: it deletes an ID-bearing
  *headline* (level != 0), the opposite of `mutateNote`'s file-level-only
  guard, so it open-codes the same check-then-refuse harness. Tools writing
  *fresh* content (`create-note`,
  `archive-document`, append-only `capture`) skip the hash but still use
  `atomicWrite` (see CONCEPT.md Decisions).
