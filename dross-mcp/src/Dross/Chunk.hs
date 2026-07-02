-- | Pure chunking of node text for embedding. A node arrives as its title
-- plus the headline-level segments 'Dross.Index.collectNodes' assembles the
-- body from; typical notes become a single chunk, long ones split at
-- headline boundaries (per CONCEPT.md), falling back to blank-line and
-- finally hard splits for pathological segments. Every chunk is prefixed
-- with the note title so the embedding carries context; the prefixed text
-- is what gets stored, hashed, and embedded.
module Dross.Chunk
  ( chunkNode
  , defaultChunkChars
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | ~2K tokens; well under voyage-3.5's 32K-token context.
defaultChunkChars :: Int
defaultChunkChars = 8000

-- | @chunkNode maxChars title segments@: pack segments into title-prefixed
-- chunks of at most roughly @maxChars@ characters (the title prefix may
-- push a chunk over; only the packed body is budgeted). Never returns an
-- empty list or empty chunks — a note with no body text still yields its
-- title, so title-only notes are searchable.
chunkNode :: Int -> Text -> [Text] -> [Text]
chunkNode maxChars title segments
  | null pieces = [title]
  | otherwise = map withTitle (pack pieces)
  where
    body = filter (not . T.null) (map T.strip segments)
    pieces = concatMap (splitOversized maxChars) body
    withTitle t = title <> "\n\n" <> t
    pack = go []
      where
        go acc [] = [joinPieces (reverse acc) | not (null acc)]
        go acc (p : ps)
          | null acc || fits = go (p : acc) ps
          | otherwise = joinPieces (reverse acc) : go [p] ps
          where
            fits = sum (map T.length acc) + length acc + T.length p <= maxChars
    joinPieces = T.intercalate "\n"

-- | Split a single segment that exceeds the budget: first at blank-line
-- (paragraph) boundaries, then hard character splits as a last resort.
splitOversized :: Int -> Text -> [Text]
splitOversized maxChars t
  | T.length t <= maxChars = [t]
  | otherwise = concatMap hardSplit paragraphs
  where
    paragraphs = filter (not . T.null) (map T.strip (T.splitOn "\n\n" t))
    hardSplit p
      | T.length p <= maxChars = [p]
      | otherwise = T.take maxChars p : hardSplit (T.drop maxChars p)
