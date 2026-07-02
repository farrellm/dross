-- | Textual surgery on raw org file content, backing the mutating MCP
-- tools. Works line-by-line on the original text (not the AST) so metadata
-- the parser doesn't model still survives a rewrite verbatim.
--
-- Only file-level notes are editable: the file's metadata block — the top
-- property drawer plus the contiguous @#+keyword@ lines after it — is
-- preserved, and everything below it is the note's body.
module Dross.Org.Edit
  ( splitMetadata
  , setKeyword
  , renderFile
  , appendBody
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T

import Dross.Org.Parser (parseKeyword)

-- | Split file content into (metadata lines, body lines). Metadata is the
-- optional @:PROPERTIES:@ drawer at the very top plus the contiguous run of
-- @#+keyword:@ lines following it; @#+begin_src@ and friends are not
-- keywords and stay in the body.
splitMetadata :: Text -> ([Text], [Text])
splitMetadata content =
  let (drawer, rest) = spanDrawer (T.lines (normalize content))
      (kws, body) = span (isJust . parseKeyword) rest
   in (drawer <> kws, body)
  where
    spanDrawer ls = case ls of
      (l : more)
        | isMarker ":PROPERTIES:" l ->
            case break (isMarker ":END:") more of
              (inner, end : after) -> (l : inner <> [end], after)
              -- Unterminated drawer: the parser degrades it to body text,
              -- so treat it as body here too.
              (_, []) -> ([], ls)
      _ -> ([], ls)
    isMarker m l = T.toUpper (T.strip l) == m

-- | Set or replace a @#+key:@ line among metadata lines, in place (first
-- match wins; later duplicates are left alone — the parser ignores them);
-- 'Nothing' removes every match. A missing keyword is appended after the
-- existing metadata. The key must be lowercase, matching 'parseKeyword'.
setKeyword :: Text -> Maybe Text -> [Text] -> [Text]
setKeyword key mval meta = case mval of
  Nothing -> filter (not . matches) meta
  Just val ->
    let line = "#+" <> key <> ": " <> val
     in case break matches meta of
          (before, _old : after) -> before <> (line : after)
          (_, []) -> meta <> [line]
  where
    matches l = (fst <$> parseKeyword l) == Just key

-- | Reassemble a file from metadata lines and body text: metadata, one
-- blank separator line, body, trailing newline. Inverse of 'splitMetadata'
-- up to blank-line normalization at the seam.
renderFile :: [Text] -> Text -> Text
renderFile meta body =
  let b = T.stripEnd (T.dropWhile (== '\n') (normalize body))
      bodyPart = if T.null b then "" else b <> "\n"
   in if null meta
        then bodyPart
        else T.unlines meta <> (if T.null bodyPart then "" else "\n" <> bodyPart)

-- | Append a paragraph at the end of the file, separated by a blank line.
appendBody :: Text -> Text -> Text
appendBody original content =
  T.stripEnd (normalize original) <> "\n\n" <> T.stripEnd content <> "\n"

normalize :: Text -> Text
normalize = T.replace "\r\n" "\n"
