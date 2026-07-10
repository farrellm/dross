{-# LANGUAGE OverloadedStrings #-}

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
  , removeHeadlineById
  ) where

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

-- | Delete the headline whose own @:ID:@ property equals the target, along
-- with its whole subtree (everything up to the next headline of the same or
-- a shallower level). Returns 'Left' naming the ID if no headline carries it.
-- The match is on a headline's *own* ID — the drawer beginning on the line
-- immediately after it — so a descendant's ID never matches, and the
-- file-level property drawer (which isn't under any headline) is never touched.
removeHeadlineById :: Text -> Text -> Either Text Text
removeHeadlineById target content =
  case listToMaybe [(i, lvl) | (i, lvl) <- headlines, ownId (drop (i + 1) ls) == Just target] of
    Nothing -> Left ("no headline with :ID: " <> target <> " in this note")
    Just (i, lvl) ->
      let end = case [j | (j, l) <- drop (i + 1) indexed, Just hl <- [headlineLevel l], hl <= lvl] of
            (j : _) -> j
            [] -> length ls
          kept = take i ls <> drop end ls
       in Right (tidy kept)
  where
    ls = T.lines (normalize content)
    indexed = zip [0 ..] ls
    headlines = [(i, lvl) | (i, l) <- indexed, Just lvl <- [headlineLevel l]]
    -- Trailing blank lines stripped, single trailing newline, blank-line gap
    -- left between former siblings collapsed — same seam behaviour as renderFile.
    tidy kept = let out = T.stripEnd (T.unlines kept) in if T.null out then "" else out <> "\n"

-- | A headline's level (count of leading @*@) when the stars are followed by a
-- space — so @*bold*@ and @** @ without a title don't count. 'Nothing' otherwise.
headlineLevel :: Text -> Maybe Int
headlineLevel l =
  let n = T.length (T.takeWhile (== '*') l)
   in if n > 0 && T.take 1 (T.drop n l) == " " then Just n else Nothing

-- | The @:ID:@ of the property drawer that begins on the head of these lines
-- (the lines right after a headline). 'Nothing' if they don't open with a
-- @:PROPERTIES:@ drawer, so a headline without its own drawer has no own ID.
ownId :: [Text] -> Maybe Text
ownId ls = case ls of
  (l : more)
    | isMarker ":PROPERTIES:" l ->
        listToMaybe
          [ T.strip v
          | drawerLine <- takeWhile (not . isMarker ":END:") more
          , Just v <- [T.stripPrefix ":ID:" (T.strip drawerLine)]
          ]
  _ -> Nothing
  where
    isMarker m x = T.toUpper (T.strip x) == m

normalize :: Text -> Text
normalize = T.replace "\r\n" "\n"
