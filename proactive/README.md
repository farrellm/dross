# Proactive jobs (roadmap stage 4)

Scheduled agent runs that reach you over Telegram: a weekly digest,
gardening (resurfaced stale notes, duplicate/contradiction flags), and
synthesis (drafted hub notes staged as git proposals with Approve/Reject
buttons).

Each job is `run-job.sh <name>`: it runs headless Claude (`claude -p`) with
the matching prompt from `prompts/`, wired to the dross MCP server, and
pipes the reply to `dross-bot send`. Synthesis additionally stages a
`proposal/<slug>` branch in the notes repo (via a temp `git worktree`, so
the live checkout never leaves your branch) and announces it with
`dross-bot propose`, which posts the diff summary with inline buttons. The
long-running `dross-bot` must be up to handle the button presses: approve
merges the branch (fast-forward when possible), reject deletes it.

## Requirements

- `claude` (Claude Code CLI), `dross-mcp`, and `dross-bot` on `PATH` — or
  point `CLAUDE_BIN` / `DROSS_MCP_BIN` / `DROSS_BOT_BIN` at them.
- Env: `DROSS_NOTES_DIR`, `TELEGRAM_TOKEN`, `DROSS_TELEGRAM_CHAT_ID`, and
  `VOYAGE_API_KEY` (the jobs lean on `similar-notes`).
- The database container running (`make -C ../dross-mcp db-start`).
- The notes dir should be a git repo (proposals and auto-commit need it).

## Scheduling

Put the environment in a file cron can source, e.g. `~/.config/dross/env`,
then:

```crontab
# m h dom mon dow
0 8 * * mon  . ~/.config/dross/env && ~/workspace/dross/proactive/run-job.sh digest
0 8 * * wed  . ~/.config/dross/env && ~/workspace/dross/proactive/run-job.sh synthesis
0 8 * * fri  . ~/.config/dross/env && ~/workspace/dross/proactive/run-job.sh gardening
```

Run any job by hand the same way to try it out.

## Notes

- Job replies go to Telegram verbatim; the prompts insist on short plain
  text. Adjust the prompts freely — they are the job definitions.
- `run-job.sh` passes an explicit `--allowedTools` sandbox: dross MCP tools,
  `git`, `dross-bot`, `mktemp`/`uuidgen`, and file tools for the proposal
  worktree. Widen it only deliberately.
- A proposal branch left over from a crashed job is inert; delete it with
  `git branch -D proposal/<slug>` or let a `dross-bot propose` announce it.
