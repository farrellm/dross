-- | Tool definitions and implementations for the MCP server, backed by the
-- Postgres index. Every call starts with an incremental 'refreshIndex' so
-- edits made in Emacs since the last call are visible without inotify.
module Dross.Tools
  ( Env (..)
  , toolDefs
  , callTool
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as V4
import Database.PostgreSQL.Simple (Connection)
import System.Directory (doesFileExist)
import System.FilePath ((<.>), (</>))

import Dross.Index

data Env = Env
  { envNotesDir :: FilePath
  , envDb :: Connection
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
      "read-note"
      "Read a note by its org ID. Returns title, tags, file path, and content."
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
      "create-note"
      "Create a new note file with a generated org ID. Returns the new note's ID and file path."
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
    "read-note" -> withParsed (.: "id") $ \nid ->
      getNode (envDb env) nid >>= \case
        Nothing -> pure (Left ("no note with ID " <> nid))
        Just n ->
          pure . Right $
            object
              [ "id" .= nrId n
              , "title" .= nrTitle n
              , "file" .= nrFile n
              , "tags" .= nrTags n
              , "todo" .= nrTodo n
              , "content" .= nrBody n
              ]
    "backlinks" -> withParsed (.: "id") $ \nid -> do
      rows <- backlinks (envDb env) nid
      pure . Right . toJSON $
        [ object ["id" .= i, "title" .= title, "file" .= file, "description" .= descr]
        | (i, title, file, descr) <- rows
        ]
    "create-note" -> withParsed parseCreate $ \(title, content, tags) -> do
      nid <- UUID.toText <$> V4.nextRandom
      path <- freshPath (envNotesDir env) (slugify title) nid
      BS.writeFile path (TE.encodeUtf8 (renderNote nid title tags content))
      refreshIndex (envDb env) (envNotesDir env)
      pure . Right $ object ["id" .= nid, "file" .= path]
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

renderNote :: Text -> Text -> [Text] -> Text -> Text
renderNote nid title tags content =
  T.unlines $
    [ ":PROPERTIES:"
    , ":ID: " <> nid
    , ":END:"
    , "#+title: " <> title
    ]
      <> ["#+filetags: :" <> T.intercalate ":" tags <> ":" | not (null tags)]
      <> (if T.null content then [] else ["", content])
