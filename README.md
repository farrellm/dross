# Dross

An LLM-augmented Zettelkasten built on plain org files and
[org-node](https://github.com/meedstrom/org-node) conventions. Raw captures
are the dross; an agent helps refine them into permanent notes — and the
notes stay fully usable from Emacs alone if every clever part of this
system is turned off.

- **Plain org files are the source of truth.** The Postgres index is a
  rebuildable cache; destroying it costs a re-index, never data.
- **The agent proposes, the human curates.** Agents capture and suggest
  freely; restructuring goes through approval.
- **Git is the safety net.** Every agent-initiated change is a commit;
  bigger proposals are branches you approve or reject from Telegram.
- **Local-first.** The only network dependencies are the LLM API, the
  Voyage embedding API, and Telegram.

`CONCEPT.md` is the design document; its **Decisions** section records the
settled choices.

## Components

| Directory | What it is |
|---|---|
| `dross-mcp/` | Haskell MCP server: parses the notes, maintains a Postgres index (full-text + pgvector embeddings), and exposes the archive as tools — `search`, `semantic-search`, `similar-notes`, `read-note`, `backlinks`, `forward-links`, `neighborhood`, `stale-notes`, `recent-notes`, `create-note`, `update-note`, `append-note`, `capture`, `archive-document`. All writes are atomic, conflict-checked, and auto-committed to git. |
| `dross-bot/` | Go Telegram bot. Inbound: text/links/forwards → inbox, photos/files → the document archive, with "connects to" nudges on capture. Outbound: one-shot `send` and `propose` modes for scheduled jobs, plus inline Approve/Reject buttons for agent proposals. |
| `proactive/` | Scheduled agent jobs (cron + headless `claude -p`): weekly digest, gardening (resurfaced stale notes, duplicate flags), synthesis (drafted hub notes staged as git proposals). |
| `docs/notes-CLAUDE.md` | Template CLAUDE.md for your *notes* repository — teaches the agent Zettelkasten discipline and the workflows (inbox processing, link suggestion, Q&A with citations, literature notes). |

Everything meets in the middle: Claude Code (interactively) and the
proactive jobs (on a schedule) drive the same MCP tools, the bot is an MCP
client of the same server, and Emacs edits the same files directly — the
index catches up on the next tool call.

## How the index stays fresh

The index updates in two stages, and only one of them costs anything.
There is no file watcher; freshness is pull-based, triggered by tool calls.

- **Full-text chunks refresh on *every* tool call.** Each MCP call begins by
  re-hashing the notes directory (SHA-256) and re-indexing only the files
  whose content changed. So an edit from *anywhere* — Claude Code, the bot,
  or plain Emacs — is picked up on the next tool call; the indexer can't
  tell the sources apart, since all it sees is a file whose hash no longer
  matches. This stage is pure Postgres and never hits the network.
- **Embeddings refresh lazily, only when a semantic tool runs.** Vectors are
  fetched from Voyage inside `semantic-search` and `similar-notes` only, and
  only for chunks whose content is new — embeddings are keyed by content
  hash, so unchanged notes are never re-embedded. Writes (`create-note`,
  `update-note`, `capture`, …) update the chunks immediately but do *not*
  embed at write time; the vector is filled in on the next semantic query.

Practical upshot: the first `semantic-search` or `similar-notes` after a
batch of edits pays to embed whatever changed (and blocks on that call);
everything else — plain `search`, `backlinks`, `read-note`, and every
write — never touches the embedding API. Without `VOYAGE_API_KEY` the two
semantic tools are disabled and the rest is unaffected.

## Setup

Prerequisites: GHC 9.12 + cabal, Go, Docker (for the index database),
libpq (`postgresql-libs` on Arch), git, and the
[Claude Code](https://claude.com/claude-code) CLI. Your notes directory
should be a git repository (everything works without git, but you lose
auto-commit and proposals).

**1. Database** (pgvector container on `127.0.0.1:5433`):

```sh
make db-create        # once; afterwards: make db-start
```

**2. MCP server**, registered with Claude Code:

```sh
cd dross-mcp
cabal install --installdir=bin --overwrite-policy=always   # or, from the root: make mcp-install
claude mcp add dross --env VOYAGE_API_KEY=... -- $(pwd)/bin/dross-mcp ~/notes
```

`VOYAGE_API_KEY` is optional: without it `semantic-search` and
`similar-notes` are disabled and everything else works.

**3. Notes repo**: copy `docs/notes-CLAUDE.md` to `~/notes/CLAUDE.md` and
adjust. Now `claude` in `~/notes` is the primary interface — capture,
search, process the inbox, ask questions of the archive.

**4. Telegram bot** (optional, for mobile capture and proactive messages):
create a bot with [@BotFather](https://t.me/BotFather), then

```sh
make bot-build
TELEGRAM_TOKEN=... DROSS_NOTES_DIR=~/notes make bot-run
```

Message your bot once; it replies with your chat ID. Restart with
`DROSS_TELEGRAM_CHAT_ID=<that id>` (this is also the allowlist) and keep it
running — it also handles the Approve/Reject buttons on proposals. It
finds `dross-mcp` on `PATH`, or set `DROSS_MCP_BIN`.

**5. Proactive jobs** (optional): see `proactive/README.md` for the cron
lines. `proactive/run-job.sh digest` (or `gardening`, `synthesis`) runs one
by hand.

## Everyday use

- **Capture anywhere**: text a thought to the bot, or ask Claude Code to
  capture it. Everything lands as a timestamped entry in `inbox.org` with
  its own ID; captures reply with the existing notes they connect to.
- **Archive documents**: send the bot a PDF/photo, or point Claude Code at
  a file/URL. You get a literature note linking the stored copy; extracted
  text is indexed so search covers the document itself.
- **Process the inbox** in Claude Code: it drafts titled, tagged, linked
  notes from raw captures and proposes links in both directions — you
  approve before anything permanent changes.
- **Ask the archive**: answers come with `[[id:...]]` citations, and good
  answers can be captured as notes themselves.
- **Let it garden**: the scheduled jobs resurface stale notes, flag
  near-duplicates, and draft hub notes for clusters that lack one — those
  arrive on Telegram as proposals with Approve/Reject buttons backed by
  git branches.
- **Keep using Emacs**: the files are ordinary org-node notes; nothing
  above is required for reading or writing them.

## Development

```sh
make mcp-build && make mcp-test
make bot-build && (cd dross-bot && go vet ./... && go test ./...)
```

`make bot-watch` runs a [wgo](https://github.com/bokwoon95/wgo)
live-reload loop for the bot (rebuild + restart on source change).

`dross-mcp/README.md` has the server details (schema, environment
variables, smoke-testing); `CLAUDE.md` orients coding agents working on
this repo.
