# CLAUDE.md — dross-web

The React reader. See the repo-root `CLAUDE.md` for the project overview
and the build/run commands.

- `dross-web/` — React + Vite reader, phone-first, **read-only** (Telegram
  captures, Claude Code edits). `src/org/` parses the same org subset the
  server does and renders it; it consumes `raw`, never `content`. The
  design ties one thing together: the steel-tempering colour ramp
  (`src/temper.ts`) always means *distance from here* — hops in the graph,
  score in search, proximity in the drawer — so don't reach for it to
  colour anything that isn't a distance. Note *kind* therefore rides a
  second, independent channel: shape (`src/kind.ts`), where a square is a
  literature note and a circle is everything else. Keep the two apart — a
  kind never takes a colour, a distance never takes a shape. Graph
  rendering is canvas +
  d3-force; note that canvas silently ignores `var(--x)` assigned to
  `fillStyle`/`font`, so colours must be resolved through
  `getComputedStyle` first.

The built output (`dross-web/dist`) is served by the *bot* process, not a
standalone server — `DROSS_WEB_DIST` points at it and the API lives in
`dross-bot/server.go`. `make web-dev` proxies `/api` to a running
`web-serve`, so the backend must be up separately.
