-- | The Postgres index: connection handling, incremental re-indexing of the
-- notes directory, and the queries behind the MCP tools.
--
-- The database is a rebuildable cache — org files stay the source of truth.
-- 'refreshIndex' re-reads and hashes every file, re-indexing only those
-- whose content changed; at personal scale that is cheap enough to run at
-- the top of every tool call, which keeps the index honest without inotify.
module Dross.Index
  ( connectDb
  , checkSchema
  , refreshIndex
  , listOrgFiles
  , extractFileName
  , searchNodes
  , getNode
  , backlinks
  , forwardLinks
  , neighborhood
  , embedPending
  , semanticSearch
  , similarNotes
  , NodeRow (..)
  ) where

import Control.Applicative ((<|>))
import Control.Exception (try)
import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Types (PGArray (..))
import System.Directory (doesDirectoryExist, doesFileExist, getModificationTime, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeBaseName, takeExtension, (</>))
import System.IO (hPutStrLn, stderr)

import Dross.Chunk (chunkNode, defaultChunkChars)
import Dross.Embed (renderVector)
import Dross.Org.Parser
import Dross.Org.Types

-- | Default matches the container from the Makefile; override with DROSS_DB.
defaultConnString :: String
defaultConnString = "host=127.0.0.1 port=5433 dbname=dross user=dross password=dross"

connectDb :: IO Connection
connectDb = do
  conn <- lookupEnv "DROSS_DB"
  connectPostgreSQL (fromString (fromMaybe defaultConnString conn))

-- | True when the schema has been applied (see @make db-migrate@).
checkSchema :: Connection -> IO Bool
checkSchema conn = do
  r <- try (query_ conn "SELECT count(*) FROM nodes") :: IO (Either SqlError [Only Int])
  pure (either (const False) (const True) r)

-- | Bring the index in line with the notes directory: drop rows for deleted
-- files, (re)index files whose content hash changed. Org files first, then
-- extracted-text sidecars, so a sidecar arriving together with its
-- literature note finds the note already indexed.
refreshIndex :: Connection -> FilePath -> IO ()
refreshIndex conn notesDir = do
  paths <- listOrgFiles notesDir
  extracts <- listExtractFiles notesDir
  let live = Set.fromList (paths <> map fst extracts)
  stored <-
    query_ conn "SELECT path, hash FROM files" :: IO [(FilePath, Binary ByteString)]
  let storedMap = Map.fromList [(p, h) | (p, Binary h) <- stored]
  forM_ (Map.keys storedMap) $ \p ->
    unless (p `Set.member` live) $ do
      _ <- execute conn "DELETE FROM files WHERE path = ?" (Only p)
      pure ()
  forM_ paths $ \p -> do
    bytes <- BS.readFile p
    let h = SHA256.hash bytes
    when (Map.lookup p storedMap /= Just h) $ do
      mtime <- getModificationTime p
      indexFile conn p bytes h mtime
  forM_ extracts $ \(p, nid) -> do
    bytes <- BS.readFile p
    let h = SHA256.hash bytes
    when (Map.lookup p storedMap /= Just h) $ do
      mtime <- getModificationTime p
      indexExtract conn p bytes h mtime nid

indexFile :: Connection -> FilePath -> ByteString -> ByteString -> UTCTime -> IO ()
indexFile conn path bytes h mtime = withTransaction conn $ do
  _ <-
    execute
      conn
      "INSERT INTO files (path, hash, mtime) VALUES (?, ?, ?) \
      \ON CONFLICT (path) DO UPDATE \
      \SET hash = excluded.hash, mtime = excluded.mtime, indexed_at = now()"
      (path, Binary h, mtime)
  _ <- execute conn "DELETE FROM nodes WHERE file = ?" (Only path)
  case parseDocument path (TE.decodeUtf8Lenient bytes) of
    Left err ->
      -- File row stays (so we don't re-hash it every sweep); it just
      -- contributes no nodes until it parses again.
      hPutStrLn stderr ("dross-mcp: parse failed for " <> path <> ":\n" <> err)
    Right doc -> do
      let nodes = collectNodes path doc
      inserted <-
        returning
          conn
          "INSERT INTO nodes (id, file, level, title, tags, todo, body) \
          \VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING \
          \RETURNING id"
          [ ( nodeId n
            , path
            , nodeLevel n
            , nodeTitle n
            , PGArray (nodeTags n)
            , nodeTodo n
            , nodeText n
            )
          | n <- nodes
          ] ::
          IO [Only Text]
      -- Chunks only for the node IDs this file won (duplicate IDs go to
      -- the first file; its chunks must not be touched). Old chunks are
      -- already gone via the nodes delete cascade.
      let won = Set.fromList [i | Only i <- inserted]
      _ <-
        executeMany
          conn
          "INSERT INTO chunks (node_id, seq, content, content_sha256) \
          \VALUES (?, ?, ?, ?)"
          [ (nodeId n, seq_, c, Binary (SHA256.hash (TE.encodeUtf8 c)))
          | n <- nodes
          , nodeId n `Set.member` won
          , (seq_, c) <-
              zip [0 :: Int ..] (chunkNode defaultChunkChars (nodeTitle n) (nodeSegments n))
          ]
      _ <-
        executeMany
          conn
          "INSERT INTO links (src, dst, descr) VALUES (?, ?, ?) \
          \ON CONFLICT (src, dst) DO NOTHING"
          [ (src, dst, descr)
          | (src, Link (IdTarget dst) descr) <- nodeLinks doc
          ]
      pure ()

-- | Index an extracted-text sidecar into 'doc_chunks', attributed to the
-- literature note whose ID the attach dir encodes. If that note is not in
-- the index (dangling sidecar), skip without recording the file hash so the
-- sidecar is retried once the note appears.
indexExtract :: Connection -> FilePath -> ByteString -> ByteString -> UTCTime -> Text -> IO ()
indexExtract conn path bytes h mtime nid =
  getNode conn nid >>= \case
    Nothing ->
      hPutStrLn stderr $
        "dross-mcp: extract " <> path <> " has no indexed note " <> T.unpack nid <> "; skipping"
    Just n -> withTransaction conn $ do
      _ <-
        execute
          conn
          "INSERT INTO files (path, hash, mtime) VALUES (?, ?, ?) \
          \ON CONFLICT (path) DO UPDATE \
          \SET hash = excluded.hash, mtime = excluded.mtime, indexed_at = now()"
          (path, Binary h, mtime)
      _ <- execute conn "DELETE FROM doc_chunks WHERE path = ?" (Only path)
      _ <-
        executeMany
          conn
          "INSERT INTO doc_chunks (path, note_id, seq, content, content_sha256) \
          \VALUES (?, ?, ?, ?, ?)"
          [ (path, nid, seq_, c, Binary (SHA256.hash (TE.encodeUtf8 c)))
          | (seq_, c) <-
              zip
                [0 :: Int ..]
                (chunkNode defaultChunkChars (nrTitle n) [TE.decodeUtf8Lenient bytes])
          ]
      pure ()

-- Queries ------------------------------------------------------------------

data NodeRow = NodeRow
  { nrId :: Text
  , nrTitle :: Text
  , nrFile :: FilePath
  , nrLevel :: Int
    -- ^ 0 for the file-level node, headline level otherwise.
  , nrTags :: [Text]
  , nrTodo :: Maybe Text
  , nrBody :: Text
  }

-- | Full-text search (websearch syntax) over notes and archived-document
-- extracts (extract hits are attributed to their literature note), with a
-- title substring fallback so partial words still hit.
searchNodes :: Connection -> Text -> Int -> IO [(Text, Text, FilePath)]
searchNodes conn q limit =
  query
    conn
    "SELECT n.id, n.title, n.file \
    \FROM nodes n \
    \JOIN (SELECT id, max(rank) AS rank \
    \      FROM (SELECT id, ts_rank(fts, websearch_to_tsquery('english', ?)) AS rank \
    \            FROM nodes \
    \            WHERE fts @@ websearch_to_tsquery('english', ?) \
    \               OR title ILIKE '%' || ? || '%' \
    \            UNION ALL \
    \            SELECT note_id, ts_rank(fts, websearch_to_tsquery('english', ?)) \
    \            FROM doc_chunks \
    \            WHERE fts @@ websearch_to_tsquery('english', ?)) hits \
    \      GROUP BY id) r ON r.id = n.id \
    \ORDER BY r.rank DESC, n.title \
    \LIMIT ?"
    (q, q, q, q, q, limit)

getNode :: Connection -> Text -> IO (Maybe NodeRow)
getNode conn nid = do
  rows <-
    query
      conn
      "SELECT id, title, file, level, tags, todo, body FROM nodes WHERE id = ?"
      (Only nid)
  pure $ case rows of
    [] -> Nothing
    ((i, title, file, level, PGArray tags, todo, body) : _) ->
      Just (NodeRow i title file level tags todo body)

-- | Notes whose bodies link to the given ID.
backlinks :: Connection -> Text -> IO [(Text, Text, FilePath, Maybe Text)]
backlinks conn nid =
  query
    conn
    "SELECT n.id, n.title, n.file, l.descr \
    \FROM links l JOIN nodes n ON n.id = l.src \
    \WHERE l.dst = ? ORDER BY n.title"
    (Only nid)

-- | The n-hop link neighborhood around a note: every node within @depth@
-- hops of the root following links in either direction (with its hop
-- distance), plus all links among those nodes. Dangling link targets come
-- back with NULL title and file, like 'forwardLinks'. The recursive CTE is
-- bounded by @depth@, which callers must keep small (cycles revisit nodes
-- at increasing depths until the bound stops them).
neighborhood
  :: Connection
  -> Text
  -> Int
  -> IO ([(Text, Maybe Text, Maybe FilePath, Int)], [(Text, Text, Maybe Text)])
neighborhood conn nid depth = do
  nodes <-
    query
      conn
      "WITH RECURSIVE hood(id, depth) AS (\
      \  SELECT ?::text, 0 \
      \  UNION \
      \  SELECT CASE WHEN l.src = h.id THEN l.dst ELSE l.src END, h.depth + 1 \
      \  FROM links l JOIN hood h ON l.src = h.id OR l.dst = h.id \
      \  WHERE h.depth < ?) \
      \SELECT h.id, n.title, n.file, min(h.depth)::int \
      \FROM hood h LEFT JOIN nodes n ON n.id = h.id \
      \GROUP BY h.id, n.title, n.file \
      \ORDER BY min(h.depth), n.title"
      (nid, depth)
  let ids = PGArray [i | (i, _, _, _) <- nodes]
  edges <-
    query
      conn
      "SELECT src, dst, descr FROM links \
      \WHERE src = ANY(?) AND dst = ANY(?) ORDER BY src, dst"
      (ids, ids)
  pure (nodes, edges)

-- | Notes the given ID links to. Dangling targets (an @[[id:...]]@ link to
-- a note not in the index) come back with NULL title and file.
forwardLinks :: Connection -> Text -> IO [(Text, Maybe Text, Maybe FilePath, Maybe Text)]
forwardLinks conn nid =
  query
    conn
    "SELECT l.dst, n.title, n.file, l.descr \
    \FROM links l LEFT JOIN nodes n ON n.id = l.dst \
    \WHERE l.src = ? ORDER BY n.title"
    (Only nid)

-- Embeddings -----------------------------------------------------------------

-- | Chunk contents (note chunks and document-extract chunks) not yet
-- embedded under the given model, deduplicated by content hash (embeddings
-- are keyed by hash + model, so identical content embeds once).
pendingChunks :: Connection -> Text -> IO [(Binary ByteString, Text)]
pendingChunks conn model =
  query
    conn
    "SELECT DISTINCT ON (c.content_sha256) c.content_sha256, c.content \
    \FROM (SELECT content_sha256, content FROM chunks \
    \      UNION ALL \
    \      SELECT content_sha256, content FROM doc_chunks) c \
    \LEFT JOIN embeddings e \
    \  ON e.content_sha256 = c.content_sha256 AND e.model = ? \
    \WHERE e.content_sha256 IS NULL \
    \ORDER BY c.content_sha256"
    (Only model)

insertEmbeddings :: Connection -> Text -> [(Binary ByteString, [Float])] -> IO ()
insertEmbeddings conn model rows = do
  -- Plain ?s only: executeMany's multi-row template parser rejects casts
  -- like ?::vector. The rendered literal coerces to the vector column.
  _ <-
    executeMany
      conn
      "INSERT INTO embeddings (content_sha256, model, embedding) \
      \VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
      [(sha, model, renderVector v) | (sha, v) <- rows]
  pure ()

-- | Embed any chunks still missing vectors for the model. Zero pending —
-- the common case — means zero network. Failures are logged to stderr and
-- retried on the next call; search proceeds over whatever exists.
embedPending
  :: Connection -> Text -> ([Text] -> IO (Either Text [[Float]])) -> IO ()
embedPending conn model embed = do
  pending <- pendingChunks conn model
  unless (null pending) $
    embed (map snd pending) >>= \case
      Left err ->
        hPutStrLn stderr ("dross-mcp: embedding failed: " <> T.unpack err)
      Right vecs ->
        insertEmbeddings conn model (zip (map fst pending) vecs)

-- | Nodes ranked by cosine similarity of their best chunk to the query
-- vector (score = 1 - cosine distance, higher is better). Document-extract
-- chunks count toward their literature note.
semanticSearch
  :: Connection -> Text -> [Float] -> Int -> IO [(Text, Text, FilePath, Double)]
semanticSearch conn model vec limit =
  query
    conn
    "SELECT n.id, n.title, n.file, 1 - min(h.dist) AS score \
    \FROM (SELECT c.node_id AS id, e.embedding <=> ?::vector AS dist \
    \      FROM embeddings e \
    \      JOIN chunks c ON c.content_sha256 = e.content_sha256 \
    \      WHERE e.model = ? \
    \      UNION ALL \
    \      SELECT dc.note_id, e.embedding <=> ?::vector \
    \      FROM embeddings e \
    \      JOIN doc_chunks dc ON dc.content_sha256 = e.content_sha256 \
    \      WHERE e.model = ?) h \
    \JOIN nodes n ON n.id = h.id \
    \GROUP BY n.id, n.title, n.file \
    \ORDER BY score DESC \
    \LIMIT ?"
    (renderVector vec, model, renderVector vec, model, limit)

-- | Link-suggestion candidates: notes ranked by the best chunk-to-chunk
-- cosine similarity against the given note's chunks (document embeddings on
-- both sides), each with a flag saying whether a link already exists in
-- either direction. Document-extract chunks count toward their literature
-- note on both sides of the comparison.
similarNotes
  :: Connection -> Text -> Text -> Int -> IO [(Text, Text, FilePath, Double, Bool)]
similarNotes conn model nid limit =
  query
    conn
    "SELECT n.id, n.title, n.file, \
    \       1 - min(e2.embedding <=> e1.embedding) AS score, \
    \       EXISTS (SELECT 1 FROM links l \
    \               WHERE (l.src = ? AND l.dst = n.id) \
    \                  OR (l.src = n.id AND l.dst = ?)) AS linked \
    \FROM (SELECT node_id AS id, content_sha256 FROM chunks \
    \      UNION ALL \
    \      SELECT note_id, content_sha256 FROM doc_chunks) c1 \
    \JOIN embeddings e1 ON e1.content_sha256 = c1.content_sha256 AND e1.model = ? \
    \JOIN (SELECT node_id AS id, content_sha256 FROM chunks \
    \      UNION ALL \
    \      SELECT note_id, content_sha256 FROM doc_chunks) c2 ON c2.id <> ? \
    \JOIN embeddings e2 ON e2.content_sha256 = c2.content_sha256 AND e2.model = ? \
    \JOIN nodes n ON n.id = c2.id \
    \WHERE c1.id = ? \
    \GROUP BY n.id, n.title, n.file \
    \ORDER BY score DESC \
    \LIMIT ?"
    (nid, nid, model, nid, model, nid, limit)

-- Extraction ----------------------------------------------------------------

-- | An addressable note: the file-level node or any headline carrying an
-- @:ID:@ property, following org-node semantics.
data Node = Node
  { nodeId :: Text
  , nodeTitle :: Text
  , nodeLevel :: Int
  , nodeTodo :: Maybe Text
  , nodeTags :: [Text]
  , nodeSegments :: [Text]
    -- ^ Headline-level pieces of the body (preamble/own body, then one per
    -- child subtree) — the chunking boundaries for embedding.
  }

-- | The stored body: segments joined exactly as 'subtreeText' would.
nodeText :: Node -> Text
nodeText = T.intercalate "\n" . nodeSegments

collectNodes :: FilePath -> Document -> [Node]
collectNodes path doc = fileNode <> concatMap fromHeadline (docHeadlines doc)
  where
    fileNode = case documentId doc of
      Nothing -> []
      Just nid ->
        [ Node
            { nodeId = nid
            , nodeTitle =
                fromMaybe (T.pack (takeBaseName path)) (documentTitle doc)
            , nodeLevel = 0
            , nodeTodo = Nothing
            , nodeTags = docFiletags doc
            , nodeSegments =
                docPreamble doc : map titledSubtree (docHeadlines doc)
            }
        ]
    titledSubtree hl = T.intercalate "\n" [hlTitle hl, subtreeText hl]
    fromHeadline hl =
      let self = case Map.lookup "ID" (hlProperties hl) of
            Nothing -> []
            Just nid ->
              [ Node
                  { nodeId = nid
                  , nodeTitle = hlTitle hl
                  , nodeLevel = hlLevel hl
                  , nodeTodo = hlTodo hl
                  , nodeTags = hlTags hl <> docFiletags doc
                  , nodeSegments =
                      hlBody hl : map titledSubtree (hlChildren hl)
                  }
              ]
       in self <> concatMap fromHeadline (hlChildren hl)

-- | Links attributed to their nearest enclosing node with an @:ID:@, so a
-- link inside a headline-note belongs to that note, not also to the file.
-- Links outside any identified node are dropped.
nodeLinks :: Document -> [(Text, Link)]
nodeLinks doc = preambleLinks <> concatMap (go (documentId doc)) (docHeadlines doc)
  where
    preambleLinks =
      [(owner, l) | Just owner <- [documentId doc], l <- extractLinks (docPreamble doc)]
    go owner hl =
      let owner' = Map.lookup "ID" (hlProperties hl) <|> owner
          own = case owner' of
            Just o -> [(o, l) | l <- extractLinks (hlBody hl)]
            Nothing -> []
       in own <> concatMap (go owner') (hlChildren hl)

-- | Name of the extracted-text sidecar inside an attach dir. A dotfile so
-- org-attach file listings stay clean; `archive-document` writes it and the
-- indexer sweeps for it.
extractFileName :: FilePath
extractFileName = ".extract.txt"

-- | Extracted-text sidecars in the org-attach tree
-- (@data/\<2 chars>/\<rest>/.extract.txt@), each paired with the note ID the
-- attach path encodes.
listExtractFiles :: FilePath -> IO [(FilePath, Text)]
listExtractFiles notesDir = do
  let dataDir = notesDir </> "data"
  hasData <- doesDirectoryExist dataDir
  if not hasData
    then pure []
    else do
      prefixes <- listDirectory dataDir
      fmap concat . forM prefixes $ \pre -> do
        let preDir = dataDir </> pre
        isDir <- doesDirectoryExist preDir
        if not isDir
          then pure []
          else do
            rests <- listDirectory preDir
            fmap concat . forM rests $ \rest -> do
              let p = preDir </> rest </> extractFileName
              ok <- doesFileExist p
              pure [(p, T.pack (pre <> rest)) | ok]

listOrgFiles :: FilePath -> IO [FilePath]
listOrgFiles dir = do
  entries <- listDirectory dir
  fmap concat . traverse orgFilesIn $ entries
  where
    orgFilesIn e = do
      let p = dir </> e
      isDir <- doesDirectoryExist p
      if isDir
        then
          if e `elem` [".git", ".attach", "data"]
            then pure []
            else listOrgFiles p
        else pure [p | takeExtension p == ".org"]
