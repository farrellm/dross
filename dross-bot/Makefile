# Dross Telegram bot — build & run helpers.
#
# TELEGRAM_TOKEN and DROSS_NOTES_DIR must be in the environment (the repo
# .envrc / direnv provides them); DROSS_TELEGRAM_CHAT_ID is optional (first-run
# setup reports the chat ID). The bot spawns dross-mcp: DROSS_MCP_BIN below
# points it at the cabal-built server so it need not be on PATH.

BIN           := dross-bot
DROSS_MCP_BIN ?= $(shell cd ../dross-mcp && cabal list-bin dross-mcp 2>/dev/null)
export DROSS_MCP_BIN

.PHONY: build run watch

## compile the static binary
build:
	go build -o $(BIN) .

## build and run against the configured notes dir + Telegram token
run: build
	./$(BIN)

## live-reload dev loop via wgo (rebuild + restart on source change)
watch:
	wgo run .
