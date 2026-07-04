-- | Tool definitions and implementations for the MCP server, backed by the
-- Postgres index. Every call starts with an incremental 'refreshIndex' so
-- edits made in Emacs since the last call are visible without inotify.
module Dross.Tools
  ( Env (..)
  , toolDefs
  , callTool
  , renderCapture
  , renderNote
  ) where

import Control.Monad (filterM, when, zipWithM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (intToDigit, isAlphaNum, isSpace)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as V4
import Database.PostgreSQL.Simple (Connection)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeFileName, (<.>), (</>))

import Dross.Embed (EmbedConfig (..), InputType (..), embedTexts)
import Dross.Git (autoCommit)
import Dross.Index
import Dross.Org.Edit
import Dross.Org.Parser (parseDocument)
import Dross.Org.Types (documentNodeIds)

data Env = Env
  { envNotesDir :: FilePath
  , envDb :: Connection
  , envEmbed :: Maybe EmbedConfig
    -- ^ Nothing when VOYAGE_API_KEY is unset; semantic-search is disabled
    -- but everything else works (local-first).
  , envGit :: Bool
    -- ^ True when the notes dir is a git work tree: every mutation is
    -- auto-committed (decided policy). False = plain directory, no commits.
  }

toolDefs :: [Value]
toolDefs =
  [ tool
      "search"
      "Full-text search over notes (Postgres websearch syntax, e.g. quoted phrases). Returns matching note IDs, titles, and files."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Search query (words, quoted phrases)"
                      ]
                , "limit"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "Maximum number of results (default 20)"
                      ]
                ]
          , "required" .= [t "query"]
          ]
      )
  , tool
      "semantic-search"
      "Embedding-similarity search over notes and archived-document text (Voyage + pgvector). Returns matching note IDs, titles, files, and a 0-1 similarity score. Requires VOYAGE_API_KEY."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Natural-language query to embed and match against note content"
                      ]
                , "limit"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "Maximum number of results (default 10)"
                      ]
                ]
          , "required" .= [t "query"]
          ]
      )
  , tool
      "read-note"
      "Read a note by its org ID. Returns title, tags, file path, content, and the file's content hash (pass it to update-note / append-note)."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The note's org :ID: property"
                      ]
                ]
          , "required" .= [t "id"]
          ]
      )
  , tool
      "backlinks"
      "List notes that link to the given note ID."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The target note's org :ID: property"
                      ]
                ]
          , "required" .= [t "id"]
          ]
      )
  , tool
      "forward-links"
      "List notes the given note links to. Dangling links (target not in the index) have null title and file."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The source note's org :ID: property"
                      ]
                ]
          , "required" .= [t "id"]
          ]
      )
  , tool
      "neighborhood"
      "The link graph around a note: every note within `depth` hops following links in either direction (with its hop distance from the root), plus the links among them. Dangling link targets have null title and file."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The root note's org :ID: property"
                      ]
                , "depth"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "Maximum hops from the root, 1-10 (default 2)"
                      ]
                ]
          , "required" .= [t "id"]
          ]
      )
  , tool
      "similar-notes"
      "Notes most similar to a given note by embedding distance -- candidates for linking. Returns note IDs, titles, files, a 0-1 similarity score, and whether a link between the notes already exists in either direction. Requires VOYAGE_API_KEY."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The note's org :ID: property"
                      ]
                , "limit"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "Maximum number of results (default 10)"
                      ]
                ]
          , "required" .= [t "id"]
          ]
      )
  , tool
      "create-note"
      "Create a new note file with a generated org ID. Returns the new note's ID, file path, and content hash (usable with update-note / append-note)."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "title"
                    .= object
                      ["type" .= t "string", "description" .= t "Note title"]
                , "content"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Initial body text (optional)"
                      ]
                , "tags"
                    .= object
                      [ "type" .= t "array"
                      , "items" .= object ["type" .= t "string"]
                      , "description" .= t "Filetags for the note (optional)"
                      ]
                ]
          , "required" .= [t "title"]
          ]
      )
  , tool
      "update-note"
      "Update a note: replace its body and/or set its title and filetags, keeping its ID and other metadata (property drawer and #+keyword lines). Only file-level notes. Refuses if the file changed since it was read: pass the hash from read-note, and on a conflict re-read and retry."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The note's org :ID: property"
                      ]
                , "content"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "New body (raw org text); replaces everything below the file's metadata block. Omit to keep the current body."
                      ]
                , "title"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "New #+title (optional)"
                      ]
                , "tags"
                    .= object
                      [ "type" .= t "array"
                      , "items" .= object ["type" .= t "string"]
                      , "description" .= t "New #+filetags, replacing the current set; an empty array removes them (optional)"
                      ]
                , "hash"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "File content hash from read-note"
                      ]
                ]
          , "required" .= [t "id", t "hash"]
          ]
      )
  , tool
      "append-note"
      "Append text to the end of a note's file, separated by a blank line. Only file-level notes. Refuses if the file changed since it was read: pass the hash from read-note, and on a conflict re-read and retry."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The note's org :ID: property"
                      ]
                , "content"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Text to append (raw org)"
                      ]
                , "hash"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "File content hash from read-note"
                      ]
                ]
          , "required" .= [t "id", t "content", t "hash"]
          ]
      )
  , tool
      "stale-notes"
      "File-level notes least recently modified, oldest first -- the resurfacing pool for review/gardening. Returns note IDs, titles, files, and last-modified timestamps."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "tag"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Only notes carrying this tag (optional)"
                      ]
                , "limit"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "Maximum number of results (default 10)"
                      ]
                ]
          ]
      )
  , tool
      "recent-notes"
      "File-level notes modified in the last N days, newest first -- raw material for digests. Returns note IDs, titles, files, and last-modified timestamps."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "days"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "How many days back to look (default 7)"
                      ]
                , "limit"
                    .= object
                      [ "type" .= t "integer"
                      , "description" .= t "Maximum number of results (default 50)"
                      ]
                ]
          ]
      )
  , tool
      "capture"
      "Append a raw capture to the inbox (inbox.org, created on first use). Each capture becomes a timestamped headline with its own org ID. No hash needed: capture is append-only."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "content"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "The captured text (raw org)"
                      ]
                , "title"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Short headline for the capture (optional; the timestamp alone otherwise)"
                      ]
                , "source"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Where this came from, e.g. telegram or a URL (optional)"
                      ]
                ]
          , "required" .= [t "content"]
          ]
      )
  , tool
      "archive-document"
      "Archive a document: copy a local file into the org-attach directory and create a literature note (tagged :literature:ATTACH:) linking to it. For URLs, download the file first and pass its local path."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "path"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Absolute path of the local file to archive"
                      ]
                , "title"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Literature note title (e.g. the document's title)"
                      ]
                , "source"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Where the document came from: URL or citation (optional)"
                      ]
                , "content"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Initial note body, e.g. a summary (optional)"
                      ]
                , "tags"
                    .= object
                      [ "type" .= t "array"
                      , "items" .= object ["type" .= t "string"]
                      , "description" .= t "Extra filetags beyond literature/ATTACH (optional)"
                      ]
                , "text"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Extracted plain text of the document (optional). Stored beside the attachment and indexed, so search and semantic-search cover the document's content; extraction (pdftotext, OCR, ...) is the caller's job."
                      ]
                , "extra_paths"
                    .= object
                      [ "type" .= t "array"
                      , "items" .= object ["type" .= t "string"]
                      , "description" .= t "Additional local files to attach to the same note (optional), e.g. the PDF alongside a page snapshot"
                      ]
                ]
          , "required" .= [t "path", t "title"]
          ]
      )
  ]
  where
    t :: Text -> Text
    t = id
    tool :: Text -> Text -> Value -> Value
    tool name desc schema =
      object ["name" .= name, "description" .= desc, "inputSchema" .= schema]

callTool :: Env -> Text -> Value -> IO (Either Text Value)
callTool env name args = do
  refreshIndex (envDb env) (envNotesDir env)
  case name of
    "search" -> withParsed (\o -> (,) <$> o .: "query" <*> o .:? "limit" .!= (20 :: Int)) $
      \(q, limit) -> do
        hits <- searchNodes (envDb env) q limit
        pure . Right . toJSON $
          [ object ["id" .= i, "title" .= title, "file" .= file]
          | (i, title, file) <- hits
          ]
    "semantic-search" -> withParsed (\o -> (,) <$> o .: "query" <*> o .:? "limit" .!= (10 :: Int)) $
      \(q, limit) -> case envEmbed env of
        Nothing ->
          pure (Left "semantic-search is disabled: set VOYAGE_API_KEY and restart the server")
        Just cfg -> do
          -- Catch up on anything not yet embedded (content-hash keyed, so
          -- unchanged notes cost nothing); a failure here is logged and
          -- search runs over the embeddings that exist.
          embedPending (envDb env) (embedModel cfg) (embedTexts cfg Document)
          embedTexts cfg Query [q] >>= \case
            Left err -> pure (Left ("could not embed query: " <> err))
            Right [vec] -> do
              hits <- semanticSearch (envDb env) (embedModel cfg) vec limit
              pure . Right . toJSON $
                [ object ["id" .= i, "title" .= title, "file" .= file, "score" .= score]
                | (i, title, file, score) <- hits
                ]
            Right _ -> pure (Left "embedding API returned an unexpected number of vectors")
    "similar-notes" -> withParsed (\o -> (,) <$> o .: "id" <*> o .:? "limit" .!= (10 :: Int)) $
      \(nid, limit) -> case envEmbed env of
        Nothing ->
          pure (Left "similar-notes is disabled: set VOYAGE_API_KEY and restart the server")
        Just cfg ->
          getNode (envDb env) nid >>= \case
            Nothing -> pure (Left ("no note with ID " <> nid))
            Just _ -> do
              -- Same catch-up as semantic-search, so the note being matched
              -- (often just created or edited) has vectors to compare.
              embedPending (envDb env) (embedModel cfg) (embedTexts cfg Document)
              rows <- similarNotes (envDb env) (embedModel cfg) nid limit
              pure . Right . toJSON $
                [ object
                    [ "id" .= i
                    , "title" .= title
                    , "file" .= file
                    , "score" .= score
                    , "linked" .= linked
                    ]
                | (i, title, file, score, linked) <- rows
                ]
    "read-note" -> withParsed (.: "id") $ \nid ->
      getNode (envDb env) nid >>= \case
        Nothing -> pure (Left ("no note with ID " <> nid))
        Just n -> do
          bytes <- BS.readFile (nrFile n)
          pure . Right $
            object
              [ "id" .= nrId n
              , "title" .= nrTitle n
              , "file" .= nrFile n
              , "tags" .= nrTags n
              , "todo" .= nrTodo n
              , "content" .= nrBody n
              , "hash" .= sha256Hex bytes
              ]
    "backlinks" -> withParsed (.: "id") $ \nid -> do
      rows <- backlinks (envDb env) nid
      pure . Right . toJSON $
        [ object ["id" .= i, "title" .= title, "file" .= file, "description" .= descr]
        | (i, title, file, descr) <- rows
        ]
    "forward-links" -> withParsed (.: "id") $ \nid -> do
      rows <- forwardLinks (envDb env) nid
      pure . Right . toJSON $
        [ object ["id" .= i, "title" .= title, "file" .= file, "description" .= descr]
        | (i, title, file, descr) <- rows
        ]
    "neighborhood" -> withParsed (\o -> (,) <$> o .: "id" <*> o .:? "depth" .!= (2 :: Int)) $
      \(nid, depth) ->
        if depth < 1 || depth > 10
          then pure (Left "depth must be between 1 and 10")
          else
            getNode (envDb env) nid >>= \case
              Nothing -> pure (Left ("no note with ID " <> nid))
              Just _ -> do
                (ns, es) <- neighborhood (envDb env) nid depth
                pure . Right $
                  object
                    [ "nodes"
                        .= [ object ["id" .= i, "title" .= title, "file" .= file, "distance" .= d]
                           | (i, title, file, d) <- ns
                           ]
                    , "edges"
                        .= [ object ["from" .= s, "to" .= dst, "description" .= descr]
                           | (s, dst, descr) <- es
                           ]
                    ]
    "stale-notes" -> withParsed (\o -> (,) <$> o .:? "tag" <*> o .:? "limit" .!= (10 :: Int)) $
      \(mtag, limit) -> do
        rows <- staleNotes (envDb env) mtag limit
        pure . Right . toJSON $
          [ object ["id" .= i, "title" .= title, "file" .= file, "mtime" .= mtime]
          | (i, title, file, mtime) <- rows
          ]
    "recent-notes" -> withParsed (\o -> (,) <$> o .:? "days" .!= (7 :: Int) <*> o .:? "limit" .!= (50 :: Int)) $
      \(days, limit) ->
        if days < 1
          then pure (Left "days must be at least 1")
          else do
            rows <- recentNotes (envDb env) days limit
            pure . Right . toJSON $
              [ object ["id" .= i, "title" .= title, "file" .= file, "mtime" .= mtime]
              | (i, title, file, mtime) <- rows
              ]
    "create-note" -> withParsed parseCreate $ \(title, content, tags) -> do
      nid <- UUID.toText <$> V4.nextRandom
      path <- freshPath (envNotesDir env) (slugify title) nid
      let bytes = TE.encodeUtf8 (renderNote nid [] title tags content)
      atomicWrite path bytes
      commitMutation env ("dross: create-note: " <> title) [path]
      refreshIndex (envDb env) (envNotesDir env)
      pure . Right $ object ["id" .= nid, "file" .= path, "hash" .= sha256Hex bytes]
    "update-note" -> withParsed parseUpdate $ \(nid, expected, mcontent, mtitle, mtags) ->
      case validateUpdate mcontent mtitle mtags of
        Left err -> pure (Left err)
        Right () -> mutateNote env "update-note" nid expected $ \path old ->
          let (meta, bodyLines) = splitMetadata old
              meta' =
                maybe id (\ti -> setKeyword "title" (Just ti)) mtitle
                  . maybe id (setKeyword "filetags" . renderTags) mtags
                  $ meta
              body = fromMaybe (T.intercalate "\n" bodyLines) mcontent
           in checkedRewrite path old (renderFile meta' body)
    "append-note" -> withParsed parseEdit $ \(nid, content, expected) ->
      mutateNote env "append-note" nid expected $ \_path old ->
        if T.null (T.strip content)
          then Left "nothing to append: content is empty"
          else Right (appendBody old content)
    -- Deliberately not routed through mutateNote: capture is append-only
    -- and inserts fresh content without a prior read, so there is no stale
    -- read for the hash check to catch (recorded in CONCEPT.md Decisions).
    "capture" -> withParsed parseCapture $ \(content, mtitle, msource) ->
      case validateCapture content mtitle msource of
        Left err -> pure (Left err)
        Right () -> do
          nid <- UUID.toText <$> V4.nextRandom
          ts <-
            T.pack . formatTime defaultTimeLocale "[%Y-%m-%d %a %H:%M]"
              <$> getZonedTime
          let path = envNotesDir env </> "inbox.org"
          exists <- doesFileExist path
          old <-
            if exists
              then TE.decodeUtf8Lenient <$> BS.readFile path
              else do
                inboxId <- UUID.toText <$> V4.nextRandom
                pure (renderNote inboxId [] "Inbox" ["inbox"] "")
          let entry = renderCapture nid ts mtitle msource content
              newBytes = TE.encodeUtf8 (appendBody old entry)
          atomicWrite path newBytes
          commitMutation env ("dross: capture: " <> fromMaybe ts mtitle) [path]
          refreshIndex (envDb env) (envNotesDir env)
          pure . Right $ object ["id" .= nid, "file" .= path, "hash" .= sha256Hex newBytes]
    -- Like create-note, this writes a brand-new note file (no existing
    -- note to conflict with), so there is no hash parameter; the copied
    -- document lands in the org-attach uuid layout Emacs expects.
    "archive-document" -> withParsed parseArchive $ \(path, title, msource, content, tags, extractText, extraPaths) ->
      case validateArchive title msource tags of
        Left err -> pure (Left err)
        Right () -> do
          missing <- filterM (fmap not . doesFileExist) (path : extraPaths)
          case missing of
            m : _ -> pure (Left ("no such file: " <> T.pack m))
            [] -> do
              nid <- UUID.toText <$> V4.nextRandom
              let attachRel =
                    "data" </> T.unpack (T.take 2 nid) </> T.unpack (T.drop 2 nid)
                  attachDir = envNotesDir env </> attachRel
                  sources = path : extraPaths
                  target = attachDir </> takeFileName path
                  extraTargets = [attachDir </> takeFileName p | p <- extraPaths]
                  targets = target : extraTargets
                  hasExtract = not (T.null (T.strip extractText))
              createDirectoryIfMissing True attachDir
              zipWithM_ copyFile sources targets
              -- The sidecar keeps extracted text on disk (source of truth);
              -- the note must be written before refreshIndex sees the
              -- sidecar, and it is, just below.
              when hasExtract $
                atomicWrite (attachDir </> extractFileName) (TE.encodeUtf8 extractText)
              notePath <- freshPath (envNotesDir env) (slugify title) nid
              let link :: FilePath -> Text
                  link p =
                    "[[file:"
                      <> T.pack (attachRel </> takeFileName p)
                      <> "]["
                      <> T.pack (takeFileName p)
                      <> "]]"
                  links = T.intercalate "\n" (map link sources)
                  body = links <> (if T.null content then "" else "\n\n" <> content)
                  props = [("SOURCE", src) | Just src <- [msource]]
                  bytes =
                    TE.encodeUtf8 $
                      renderNote nid props title (["literature"] <> tags <> ["ATTACH"]) body
              atomicWrite notePath bytes
              commitMutation env ("dross: archive-document: " <> title) $
                [notePath] <> targets <> [attachDir </> extractFileName | hasExtract]
              refreshIndex (envDb env) (envNotesDir env)
              pure . Right $
                object
                  [ "id" .= nid
                  , "file" .= notePath
                  , "attached" .= target
                  , "extra_attached" .= extraTargets
                  , "extract"
                      .= (if hasExtract then Just (attachDir </> extractFileName) else Nothing)
                  , "hash" .= sha256Hex bytes
                  ]
    _ -> pure (Left ("unknown tool: " <> name))
  where
    withParsed :: (Object -> Parser a) -> (a -> IO (Either Text Value)) -> IO (Either Text Value)
    withParsed p k =
      either (pure . Left) k $
        first T.pack (parseEither (withObject "arguments" p) args)
    parseCreate o =
      (,,)
        <$> o .: "title"
        <*> o .:? "content" .!= ""
        <*> o .:? "tags" .!= []
    parseEdit o =
      (,,)
        <$> o .: "id"
        <*> o .: "content"
        <*> o .: "hash"
    parseCapture o =
      (,,)
        <$> o .: "content"
        <*> o .:? "title"
        <*> o .:? "source"
    parseArchive o =
      (,,,,,,)
        <$> o .: "path"
        <*> o .: "title"
        <*> o .:? "source"
        <*> o .:? "content" .!= ""
        <*> o .:? "tags" .!= []
        <*> o .:? "text" .!= ""
        <*> o .:? "extra_paths" .!= []
    parseUpdate o =
      (,,,,)
        <$> o .: "id"
        <*> o .: "hash"
        <*> o .:? "content"
        <*> o .:? "title"
        <*> o .:? "tags"

-- | Refuse malformed update arguments before touching the file.
validateUpdate :: Maybe Text -> Maybe Text -> Maybe [Text] -> Either Text ()
validateUpdate mcontent mtitle mtags
  | isNothing mcontent && isNothing mtitle && isNothing mtags =
      Left "nothing to update: provide content, title, and/or tags"
  | Just ti <- mtitle, T.null (T.strip ti) || T.any (== '\n') ti =
      Left "invalid title: must be a single non-empty line"
  | Just tg <- mtags, any badTag tg =
      Left "invalid tags: each tag must be non-empty, with no whitespace or ':'"
  | otherwise = Right ()

renderTags :: [Text] -> Maybe Text
renderTags [] = Nothing
renderTags tags = Just (":" <> T.intercalate ":" tags <> ":")

validateArchive :: Text -> Maybe Text -> [Text] -> Either Text ()
validateArchive title msource tags
  | T.null (T.strip title) || T.any (== '\n') title =
      Left "invalid title: must be a single non-empty line"
  | Just src <- msource, T.null (T.strip src) || T.any (== '\n') src =
      Left "invalid source: must be a single non-empty line"
  | any badTag tags =
      Left "invalid tags: each tag must be non-empty, with no whitespace or ':'"
  | otherwise = Right ()

badTag :: Text -> Bool
badTag tg = T.null tg || T.any (\c -> c == ':' || isSpace c) tg

validateCapture :: Text -> Maybe Text -> Maybe Text -> Either Text ()
validateCapture content mtitle msource
  | T.null (T.strip content) = Left "nothing to capture: content is empty"
  | Just ti <- mtitle, T.null (T.strip ti) || T.any (== '\n') ti =
      Left "invalid title: must be a single non-empty line"
  | Just src <- msource, T.null (T.strip src) || T.any (== '\n') src =
      Left "invalid source: must be a single non-empty line"
  | otherwise = Right ()

-- | One inbox entry: a top-level headline carrying its own ID, so each
-- capture is individually addressable and processable. The timestamp leads
-- the headline for scannability; the drawer holds the structured copy.
renderCapture :: Text -> Text -> Maybe Text -> Maybe Text -> Text -> Text
renderCapture nid ts mtitle msource content =
  T.unlines $
    [ "* " <> ts <> maybe "" (" " <>) mtitle
    , ":PROPERTIES:"
    , ":ID: " <> nid
    , ":CREATED: " <> ts
    ]
      <> [":SOURCE: " <> src | Just src <- [msource]]
      <> [":END:", T.stripEnd content]

-- | Accept a rewrite only if the result still parses and keeps every node
-- ID the file had before — refusals name the IDs so the agent can retry.
checkedRewrite :: FilePath -> Text -> Text -> Either Text Text
checkedRewrite path old new = case parseDocument path new of
  Left err ->
    Left ("rejected: the updated file would not parse:\n" <> T.pack err)
  Right newDoc ->
    let oldIds = either (const []) documentNodeIds (parseDocument path old)
        lost = filter (`notElem` documentNodeIds newDoc) oldIds
     in if null lost
          then Right new
          else
            Left
              ( "rejected: the update would delete note IDs still in the file: "
                  <> T.intercalate ", " lost
                  <> ". Keep their headlines (with :PROPERTIES: drawers) in the new content, or edit the file in Emacs."
              )

-- | Shared harness for the mutating tools: resolve the note, apply the
-- check-then-refuse policy (file-level notes only; the file's current hash
-- must match the one the caller got from read-note), then run the pure edit
-- and write the result atomically. Conflicts come back as tool errors so
-- the agent can re-read and retry. @tool@ names the caller for the
-- auto-commit message.
mutateNote
  :: Env
  -> Text
  -> Text
  -> Text
  -> (FilePath -> Text -> Either Text Text)
  -> IO (Either Text Value)
mutateNote env tool nid expected edit =
  getNode (envDb env) nid >>= \case
    Nothing -> pure (Left ("no note with ID " <> nid))
    Just n
      | nrLevel n /= 0 ->
          pure . Left $
            "note "
              <> nid
              <> " is a headline inside "
              <> T.pack (nrFile n)
              <> "; only file-level notes can be modified"
      | otherwise -> do
          bytes <- BS.readFile (nrFile n)
          if sha256Hex bytes /= expected
            then
              pure . Left $
                "conflict: "
                  <> T.pack (nrFile n)
                  <> " changed since it was read; call read-note again and retry with the new hash"
            else case edit (nrFile n) (TE.decodeUtf8Lenient bytes) of
              Left err -> pure (Left err)
              Right new -> do
                let newBytes = TE.encodeUtf8 new
                atomicWrite (nrFile n) newBytes
                commitMutation env ("dross: " <> tool <> ": " <> nrTitle n) [nrFile n]
                refreshIndex (envDb env) (envNotesDir env)
                pure . Right $
                  object
                    ["id" .= nid, "file" .= nrFile n, "hash" .= sha256Hex newBytes]

-- | Auto-commit a mutation's files when the notes dir is a git repo
-- (decided policy: every agent-initiated change is a commit).
commitMutation :: Env -> Text -> [FilePath] -> IO ()
commitMutation env msg paths =
  when (envGit env) $ autoCommit (envNotesDir env) msg paths

-- | Write via a temp file in the same directory + rename, so a crash never
-- leaves a half-written note (decided policy: atomic writes).
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bytes = do
  let tmp = path <.> "tmp"
  BS.writeFile tmp bytes
  renameFile tmp path

sha256Hex :: ByteString -> Text
sha256Hex = T.pack . BS.foldr step [] . SHA256.hash
  where
    step b acc =
      intToDigit (fromIntegral (b `shiftR` 4))
        : intToDigit (fromIntegral (b .&. 0x0f))
        : acc

slugify :: Text -> Text
slugify title =
  let s =
        T.dropAround (== '-')
          . T.intercalate "-"
          . filter (not . T.null)
          . T.splitOn "-"
          . T.map (\c -> if isAlphaNum c then c else '-')
          . T.toLower
          $ title
   in if T.null s then "note" else s

freshPath :: FilePath -> Text -> Text -> IO FilePath
freshPath dir slug nid = do
  let base = dir </> T.unpack slug <.> "org"
  exists <- doesFileExist base
  pure $
    if exists
      then dir </> T.unpack (slug <> "-" <> T.take 8 nid) <.> "org"
      else base

renderNote :: Text -> [(Text, Text)] -> Text -> [Text] -> Text -> Text
renderNote nid extraProps title tags content =
  T.unlines $
    [ ":PROPERTIES:"
    , ":ID: " <> nid
    ]
      <> [":" <> k <> ": " <> v | (k, v) <- extraProps]
      <> [ ":END:"
         , "#+title: " <> title
         ]
      <> ["#+filetags: :" <> T.intercalate ":" tags <> ":" | not (null tags)]
      <> (if T.null content then [] else ["", content])
