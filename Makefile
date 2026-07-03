# Dross — single entry point for the whole repo (run from the root).
#
# Two groups of targets:
#   db-*   Postgres-in-Docker for the dross-mcp index
#   bot-*  build / run the Go Telegram bot
#
# The dross-mcp server connects using DROSS_DB (libpq connection string); the
# default baked into the binary matches this container:
#   host=127.0.0.1 port=5433 dbname=dross user=dross password=dross

CONTAINER := dross-db
VOLUME    := dross-pgdata
IMAGE     := pgvector/pgvector:pg17
PGPORT    := 5433
PGUSER    := dross
PGDB      := dross

# The bot spawns dross-mcp: point it at the cabal-built server so it need not
# be on PATH. ?= lets an already-set value win; exported to bot-run/bot-watch.
DROSS_MCP_BIN ?= $(shell cd dross-mcp && cabal list-bin dross-mcp 2>/dev/null)
export DROSS_MCP_BIN

.PHONY: db-create db-start db-stop db-migrate db-psql db-destroy db-wait \
        mcp-build mcp-test mcp-run mcp-install mcp-watch \
        bot-build bot-run bot-watch

## create the container + data volume and run the initial migration
db-create:
	docker run -d --name $(CONTAINER) \
	  -v $(VOLUME):/var/lib/postgresql/data \
	  -p 127.0.0.1:$(PGPORT):5432 \
	  -e POSTGRES_USER=$(PGUSER) \
	  -e POSTGRES_PASSWORD=$(PGUSER) \
	  -e POSTGRES_DB=$(PGDB) \
	  $(IMAGE)
	$(MAKE) db-migrate

## start an existing container (after reboot / db-stop)
db-start:
	docker start $(CONTAINER)
	$(MAKE) db-wait

db-wait:
	@until docker exec $(CONTAINER) pg_isready -U $(PGUSER) -d $(PGDB) >/dev/null 2>&1; do sleep 0.5; done
	@echo "$(CONTAINER) is ready on port $(PGPORT)"

## apply db/schema.sql (idempotent — safe to re-run)
db-migrate: db-wait
	docker exec -i $(CONTAINER) psql -U $(PGUSER) -d $(PGDB) -v ON_ERROR_STOP=1 < dross-mcp/db/schema.sql

## interactive psql shell
db-psql:
	docker exec -it $(CONTAINER) psql -U $(PGUSER) -d $(PGDB)

db-stop:
	docker stop $(CONTAINER)

## remove the container AND the data volume (the index is a rebuildable
## cache, so this only costs a re-index)
db-destroy:
	-docker rm -f $(CONTAINER)
	-docker volume rm $(VOLUME)

## build the server + test suite
mcp-build:
	cd dross-mcp && cabal build --enable-tests

## run the parser test suite
mcp-test:
	cd dross-mcp && cabal test

## run the server against DROSS_NOTES_DIR (from env / .envrc)
mcp-run:
	cd dross-mcp && cabal run dross-mcp

## install the binary into dross-mcp/bin (for `claude mcp add`)
mcp-install:
	cd dross-mcp && cabal install --installdir=bin --overwrite-policy=always

## ghcid typecheck/reload loop
mcp-watch:
	cd dross-mcp && ghcid

## compile the bot's static binary
bot-build:
	cd dross-bot && go build -o dross-bot .

## build and run the bot (TELEGRAM_TOKEN + DROSS_NOTES_DIR from env / .envrc)
bot-run: bot-build
	cd dross-bot && ./dross-bot

## live-reload dev loop via wgo (rebuild + restart on source change)
bot-watch:
	cd dross-bot && wgo run .
