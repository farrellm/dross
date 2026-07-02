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
  , searchNodes
  , getNode
  , backlinks
  , NodeRow (..)
  ) where

import Control.Applicative ((<|>))
import Control.Exception (try)
import Control.Monad (forM_, unless, when)
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
import System.Directory (doesDirectoryExist, getModificationTime, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeBaseName, takeExtension, (</>))
import System.IO (hPutStrLn, stderr)

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
-- files, (re)index files whose content hash changed.
refreshIndex :: Connection -> FilePath -> IO ()
refreshIndex conn notesDir = do
  paths <- listOrgFiles notesDir
  let live = Set.fromList paths
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
      _ <-
        executeMany
          conn
          "INSERT INTO nodes (id, file, level, title, tags, todo, body) \
          \VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING"
          [ ( nodeId n
            , path
            , nodeLevel n
            , nodeTitle n
            , PGArray (nodeTags n)
            , nodeTodo n
            , nodeText n
            )
          | n <- collectNodes path doc
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

-- | Full-text search (websearch syntax), with a title substring fallback so
-- partial words still hit.
searchNodes :: Connection -> Text -> Int -> IO [(Text, Text, FilePath)]
searchNodes conn q limit =
  query
    conn
    "SELECT id, title, file FROM nodes \
    \WHERE fts @@ websearch_to_tsquery('english', ?) \
    \   OR title ILIKE '%' || ? || '%' \
    \ORDER BY ts_rank(fts, websearch_to_tsquery('english', ?)) DESC, title \
    \LIMIT ?"
    (q, q, q, limit)

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

-- Extraction ----------------------------------------------------------------

-- | An addressable note: the file-level node or any headline carrying an
-- @:ID:@ property, following org-node semantics.
data Node = Node
  { nodeId :: Text
  , nodeTitle :: Text
  , nodeLevel :: Int
  , nodeTodo :: Maybe Text
  , nodeTags :: [Text]
  , nodeText :: Text
  }

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
            , nodeText =
                T.intercalate "\n" $
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
                  , nodeText = subtreeText hl
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
