#!/usr/bin/env bash
# Run one proactive Dross job: headless Claude composes over the dross MCP
# server, the result is delivered to Telegram by dross-bot. Cron-friendly —
# see README.md for scheduling and the environment each job needs.
set -euo pipefail

job=${1:?usage: run-job.sh <digest|gardening|synthesis>}
here=$(cd "$(dirname "$0")" && pwd)
prompt_file=$here/prompts/$job.md
[[ -f $prompt_file ]] || { echo "run-job.sh: unknown job: $job" >&2; exit 1; }

: "${DROSS_NOTES_DIR:?DROSS_NOTES_DIR is not set}"
: "${TELEGRAM_TOKEN:?TELEGRAM_TOKEN is not set}"
: "${DROSS_TELEGRAM_CHAT_ID:?DROSS_TELEGRAM_CHAT_ID is not set}"

DROSS_MCP_BIN=${DROSS_MCP_BIN:-dross-mcp}
DROSS_BOT_BIN=${DROSS_BOT_BIN:-dross-bot}
CLAUDE_BIN=${CLAUDE_BIN:-claude}

mcp_config=$(printf '{"mcpServers":{"dross":{"command":"%s","args":["%s"]}}}' \
  "$DROSS_MCP_BIN" "$DROSS_NOTES_DIR")

# The allowlist is the job sandbox: dross tools for the archive, git +
# dross-bot for staging and announcing proposals, file tools for writing
# proposal content inside the temp worktree. Nothing else.
"$CLAUDE_BIN" -p "$(cat "$prompt_file")" \
  --mcp-config "$mcp_config" \
  --allowedTools "mcp__dross,Bash(git:*),Bash(${DROSS_BOT_BIN##*/}:*),Bash(mktemp:*),Bash(uuidgen:*),Read,Write,Edit,Grep,Glob" \
  | "$DROSS_BOT_BIN" send
