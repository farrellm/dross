# Postgres-in-Docker for the Dross index.
#
# The dross-mcp server connects using DROSS_DB (libpq connection string);
# the default baked into the binary matches this container:
#   host=127.0.0.1 port=5433 dbname=dross user=dross password=dross

CONTAINER := dross-db
VOLUME    := dross-pgdata
IMAGE     := pgvector/pgvector:pg17
PGPORT    := 5433
PGUSER    := dross
PGDB      := dross

.PHONY: db-create db-start db-stop db-migrate db-psql db-destroy db-wait

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
	docker exec -i $(CONTAINER) psql -U $(PGUSER) -d $(PGDB) -v ON_ERROR_STOP=1 < db/schema.sql

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
