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

-- voyage-3.5 default output dimension is 1024.
CREATE TABLE IF NOT EXISTS embeddings (
    chunk_id  bigint PRIMARY KEY REFERENCES chunks (id) ON DELETE CASCADE,
    model     text NOT NULL,
    embedding vector(1024) NOT NULL
);

-- pgvector's exact scan is fine at personal scale. If it ever isn't:
-- CREATE INDEX embeddings_hnsw_idx ON embeddings
--     USING hnsw (embedding vector_cosine_ops);
