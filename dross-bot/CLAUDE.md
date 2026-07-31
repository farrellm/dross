# CLAUDE.md — dross-bot

The Go Telegram bot. See the repo-root `CLAUDE.md` for the project
overview and the build/run commands.

Run `go vet ./...` alongside `go test ./...` before considering a change done.

- `dross-bot/` — Go Telegram bot (`main.go` telegram wiring + capture,
  `mcp.go` minimal MCP stdio client, `web.go` URL snapshotting,
  `outbound.go` one-shot `send`, `proposal.go` proposal
  announce/approve/reject, `reextract.go` one-shot sidecar repair,
  `server.go` the reader's HTTP backend).
  It is an MCP *client*:
  it spawns `dross-mcp` and routes text/forwards to `capture` (reply
  includes similar-notes nudges, best-effort) and photos/files to
  `archive-document`, so the write policy stays server-side. Every
  archive is followed by a best-effort `capture` of an inbox entry
  linking `[[id:...]]` to the stub note — that entry, not a tag, is the
  triage marker. Messages
  starting with a URL are snapshotted client-side (obelisk self-contained
  HTML + readability-extracted text) and archived via `archive-document`,
  falling back to `capture` if the fetch fails. When readability comes back
  implausibly thin next to a raw text strip of the snapshot (`preferFallback`
  in `web.go` — the failure mode is a title-only extract on markup it can't
  read), the strip is indexed instead and the reply says so; that pollutes
  the index with nav and comments, which is the accepted price of the page
  being findable at all.
  Arxiv links (any of `/abs/`, `/pdf/`, `/html/`) are normalized: the abs
  page is snapshotted and the PDF attached via `extra_paths`, with
  pdftotext full text as the indexed `text` — PDF download and extraction
  are both best-effort. Single shared
  subprocess guarded by a mutex; restarted once on transport failure.
  Proposal callbacks run git in the notes repo; branch names are validated
  (`proposal/` prefix, slug charset, ≤56 chars) because callback data
  crosses the network.
- `dross-bot/server.go` — the reader's read-only HTTP API, in the bot
  process but on its **own** `dross-mcp` subprocess (`mcp.go` serializes
  behind one mutex, so a shared client would let a page load stall a
  capture). No listener unless `DROSS_WEB_ADDR` is set; `DROSS_WEB_DIST`
  points at the built frontend (served from disk, SPA fallback). Routes are
  thin proxies that pass the tool's JSON string straight through;
  `/api/note/{id}` is the exception, bundling note + backlinks +
  forward-links so one navigation costs one `refreshIndex` sweep instead of
  three. `/api/attach` is the only path where a request touches the
  filesystem — it resolves symlinks on both ends and checks containment.
