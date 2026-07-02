-- | Textual surgery on raw org file content, backing the mutating MCP
-- tools. Works line-by-line on the original text (not the AST) so metadata
-- the parser doesn't model still survives a rewrite verbatim.
--
-- Only file-level notes are editable: the file's metadata block — the top
-- property drawer plus the contiguous @#+keyword@ lines after it — is
-- preserved, and everything below it is the note's body.
module Dross.Org.Edit
  ( splitMetadata
  , replaceBody
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

-- | Replace everything after the metadata block with a new body.
replaceBody :: Text -> Text -> Text
replaceBody original newBody =
  let (meta, _) = splitMetadata original
      body = if T.null (T.stripEnd newBody) then "" else T.stripEnd newBody <> "\n"
   in if null meta
        then body
        else T.unlines meta <> (if T.null body then "" else "\n" <> body)

-- | Append a paragraph at the end of the file, separated by a blank line.
appendBody :: Text -> Text -> Text
appendBody original content =
  T.stripEnd (normalize original) <> "\n\n" <> T.stripEnd content <> "\n"

normalize :: Text -> Text
normalize = T.replace "\r\n" "\n"
