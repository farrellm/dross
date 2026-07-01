-- | Tool definitions and implementations for the MCP server.
--
-- MVP versions: notes are re-read from disk on every call and 'search' is a
-- naive in-memory substring scan. The Postgres index (db/schema.sql)
-- replaces this once wired up.
module Dross.Tools
  ( Env (..)
  , toolDefs
  , callTool
  ) where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as V4
import System.Directory
import System.FilePath

import Dross.Org.Parser
import Dross.Org.Types

newtype Env = Env
  { envNotesDir :: FilePath
  }

-- | An addressable note: the file-level node or any headline carrying an
-- @:ID:@ property, following org-node semantics.
data Node = Node
  { nodeId :: Text
  , nodeTitle :: Text
  , nodeFile :: FilePath
  , nodeTags :: [Text]
  , nodeText :: Text
  }

toolDefs :: [Value]
toolDefs =
  [ tool
      "search"
      "Search notes by substring match on titles and bodies. Returns matching note IDs, titles, and files."
      ( object
          [ "type" .= t "object"
          , "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= t "string"
                      , "description" .= t "Text to search for (case-insensitive)"
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
callTool env "search" args =
  case parseArgs args (\o -> (,) <$> o .: "query" <*> o .:? "limit" .!= (20 :: Int)) of
    Left e -> pure (Left e)
    Right (query, limit) -> do
      nodes <- loadNodes env
      let q = T.toLower query
          matches n =
            q `T.isInfixOf` T.toLower (nodeTitle n)
              || q `T.isInfixOf` T.toLower (nodeText n)
          hits = take limit (filter matches nodes)
      pure . Right . toJSON $
        [ object ["id" .= nodeId n, "title" .= nodeTitle n, "file" .= nodeFile n]
        | n <- hits
        ]
callTool env "read-note" args =
  case parseArgs args (.: "id") of
    Left e -> pure (Left e)
    Right nid -> do
      nodes <- loadNodes env
      case filter ((== nid) . nodeId) nodes of
        [] -> pure (Left ("no note with ID " <> nid))
        (n : _) ->
          pure . Right $
            object
              [ "id" .= nodeId n
              , "title" .= nodeTitle n
              , "file" .= nodeFile n
              , "tags" .= nodeTags n
              , "content" .= nodeText n
              ]
callTool env "create-note" args =
  case parseArgs args parseCreate of
    Left e -> pure (Left e)
    Right (title, content, tags) -> do
      nid <- UUID.toText <$> V4.nextRandom
      path <- freshPath (envNotesDir env) (slugify title) nid
      BS.writeFile path (TE.encodeUtf8 (renderNote nid title tags content))
      pure . Right $ object ["id" .= nid, "file" .= path]
  where
    parseCreate o =
      (,,)
        <$> o .: "title"
        <*> o .:? "content" .!= ""
        <*> o .:? "tags" .!= []
callTool _ name _ = pure (Left ("unknown tool: " <> name))

parseArgs :: Value -> (Object -> Parser a) -> Either Text a
parseArgs v p = first T.pack (parseEither (withObject "arguments" p) v)

loadNodes :: Env -> IO [Node]
loadNodes env = do
  files <- listOrgFiles (envNotesDir env)
  fmap concat . forM files $ \f -> do
    txt <- TE.decodeUtf8Lenient <$> BS.readFile f
    case parseDocument f txt of
      Left _ -> pure [] -- unparsable file; skip rather than fail the tool call
      Right doc -> pure (collectNodes f doc)

listOrgFiles :: FilePath -> IO [FilePath]
listOrgFiles dir = do
  entries <- listDirectory dir
  fmap concat . forM entries $ \e -> do
    let p = dir </> e
    isDir <- doesDirectoryExist p
    if isDir
      then
        if e `elem` [".git", ".attach", "data"]
          then pure []
          else listOrgFiles p
      else pure [p | takeExtension p == ".org"]

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
            , nodeFile = path
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
                  , nodeFile = path
                  , nodeTags = hlTags hl <> docFiletags doc
                  , nodeText = subtreeText hl
                  }
              ]
       in self <> concatMap fromHeadline (hlChildren hl)

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
