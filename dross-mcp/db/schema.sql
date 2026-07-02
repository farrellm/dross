-- Dross index schema (PostgreSQL + pgvector).
--
-- The database is a rebuildable cache; org files remain the source of
-- truth. Dropping and re-indexing loses nothing but time and Voyage calls.

CREATE EXTENSION IF NOT EXISTS vector;

-- One row per indexed org file; hash/mtime drive incremental re-indexing
-- and the check-then-refuse write policy.
CREATE TABLE IF NOT EXISTS files (
    path       text PRIMARY KEY,
    hash       bytea NOT NULL,
    mtime      timestamptz NOT NULL,
    indexed_at timestamptz NOT NULL DEFAULT now()
);

-- Addressable notes: file-level nodes and any headline with an :ID:
-- property (org-node semantics). level 0 = file-level node.
CREATE TABLE IF NOT EXISTS nodes (
    id    text PRIMARY KEY,
    file  text NOT NULL REFERENCES files (path) ON DELETE CASCADE,
    level int NOT NULL,
    title text NOT NULL,
    tags  text[] NOT NULL DEFAULT '{}',
    todo  text,
    body  text NOT NULL,
    fts   tsvector GENERATED ALWAYS AS (
              setweight(to_tsvector('english', title), 'A')
              || setweight(to_tsvector('english', body), 'B')
          ) STORED
);
CREATE INDEX IF NOT EXISTS nodes_fts_idx ON nodes USING gin (fts);
CREATE INDEX IF NOT EXISTS nodes_tags_idx ON nodes USING gin (tags);

-- id-links between nodes; dst may reference an ID that doesn't resolve
-- (yet), so it's deliberately not a foreign key.
CREATE TABLE IF NOT EXISTS links (
    src   text NOT NULL REFERENCES nodes (id) ON DELETE CASCADE,
    dst   text NOT NULL,
    descr text,
    PRIMARY KEY (src, dst)
);
CREATE INDEX IF NOT EXISTS links_dst_idx ON links (dst);

-- Headline-level chunks for embedding; content_sha256 keys the
-- embed-on-change cache.
CREATE TABLE IF NOT EXISTS chunks (
    id             bigserial PRIMARY KEY,
    node_id        text NOT NULL REFERENCES nodes (id) ON DELETE CASCADE,
    seq            int NOT NULL,
    content        text NOT NULL,
    content_sha256 bytea NOT NULL,
    UNIQUE (node_id, seq)
);
CREATE INDEX IF NOT EXISTS chunks_sha_idx ON chunks (content_sha256);

-- Extracted text of archived documents: chunks of the .extract.txt sidecar
-- in each attach dir, attributed to the literature note whose ID the attach
-- path encodes. Keyed by the sidecar's files row (hash-driven re-indexing,
-- same as org files); note_id is deliberately not a foreign key — nodes are
-- deleted and re-inserted when their file re-indexes, and doc chunks must
-- survive that.
CREATE TABLE IF NOT EXISTS doc_chunks (
    id             bigserial PRIMARY KEY,
    path           text NOT NULL REFERENCES files (path) ON DELETE CASCADE,
    note_id        text NOT NULL,
    seq            int NOT NULL,
    content        text NOT NULL,
    content_sha256 bytea NOT NULL,
    fts            tsvector GENERATED ALWAYS AS (
                       to_tsvector('english', content)
                   ) STORED,
    UNIQUE (path, seq)
);
CREATE INDEX IF NOT EXISTS doc_chunks_fts_idx ON doc_chunks USING gin (fts);
CREATE INDEX IF NOT EXISTS doc_chunks_note_idx ON doc_chunks (note_id);
CREATE INDEX IF NOT EXISTS doc_chunks_sha_idx ON doc_chunks (content_sha256);

-- Embeddings are keyed by chunk content hash + model, NOT chunk id, so they
-- survive re-indexing (indexFile deletes and re-inserts nodes and chunks).
-- Orphans left by edits are harmless at personal scale; prune manually with
--   DELETE FROM embeddings e WHERE NOT EXISTS
--     (SELECT 1 FROM chunks c WHERE c.content_sha256 = e.content_sha256);
-- voyage-3.5 default output dimension is 1024.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'embeddings'
                 AND column_name = 'chunk_id') THEN
        DROP TABLE embeddings;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS embeddings (
    content_sha256 bytea NOT NULL,
    model          text  NOT NULL,
    embedding      vector(1024) NOT NULL,
    PRIMARY KEY (content_sha256, model)
);

-- pgvector's exact scan is fine at personal scale. If it ever isn't:
-- CREATE INDEX embeddings_hnsw_idx ON embeddings
--     USING hnsw (embedding vector_cosine_ops);
