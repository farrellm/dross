{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RecordWildCards #-}

-- | Megaparsec parser for the org subset in "Dross.Org.Types".
--
-- Line-oriented: input is normalized to LF line endings with a trailing
-- newline, and every line parser consumes through its newline. A malformed
-- property drawer degrades to body text rather than failing the document.
module Dross.Org.Parser
  ( parseDocument
  , extractLinks
  ) where

import Control.Monad (guard, void)
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Text.Megaparsec
import Text.Megaparsec.Char

import Dross.Org.Types

type Parser = Parsec Void Text

parseDocument :: FilePath -> Text -> Either String Document
parseDocument path input =
  first errorBundlePretty (parse pDocument path (normalize input))
  where
    normalize t =
      let t' = T.replace "\r\n" "\n" t
       in if T.null t' || "\n" `T.isSuffixOf` t' then t' else t' <> "\n"

pDocument :: Parser Document
pDocument = do
  props <- option Map.empty (try pPropertyDrawer)
  preLines <- many pNonHeadlineLine
  flats <- many pFlatHeadline
  eof
  let (kws, bodyLines) = foldl' classify (Map.empty, []) preLines
  pure
    Document
      { docProperties = props
      , docKeywords = kws
      , docFiletags = maybe [] parseFiletags (Map.lookup "filetags" kws)
      , docPreamble = T.intercalate "\n" (reverse bodyLines)
      , docHeadlines = buildTree flats
      }
  where
    classify (kws, body) ln = case parseKeyword ln of
      Just (k, v) -> (Map.insertWith (\_new old -> old) k v kws, body)
      Nothing -> (kws, ln : body)

-- | @#+key: value@ (key lowercased).
parseKeyword :: Text -> Maybe (Text, Text)
parseKeyword ln = do
  rest <- T.stripPrefix "#+" (T.stripStart ln)
  let (k, v) = T.breakOn ":" rest
  v' <- T.stripPrefix ":" v
  guard (not (T.null k))
  guard (not (T.any (== ' ') k))
  pure (T.toLower k, T.strip v')

-- | @:a:b:@ → @["a","b"]@.
parseFiletags :: Text -> [Text]
parseFiletags = filter (not . T.null) . T.splitOn ":" . T.strip

-- Headlines are parsed flat, then nested by level.

data FlatHeadline = FlatHeadline
  { fhLevel :: Int
  , fhTodo :: Maybe Text
  , fhTitle :: Text
  , fhTags :: [Text]
  , fhProperties :: Map Text Text
  , fhBody :: Text
  }

pFlatHeadline :: Parser FlatHeadline
pFlatHeadline = do
  stars <- try (takeWhile1P (Just "headline stars") (== '*') <* char ' ')
  rest <- takeWhileP Nothing (/= '\n') <* eol
  props <- option Map.empty (try pPropertyDrawer)
  bodyLines <- many pNonHeadlineLine
  let (todo, title, tags) = splitHeadline (T.strip rest)
  pure
    FlatHeadline
      { fhLevel = T.length stars
      , fhTodo = todo
      , fhTitle = title
      , fhTags = tags
      , fhProperties = props
      , fhBody = T.intercalate "\n" bodyLines
      }

pNonHeadlineLine :: Parser Text
pNonHeadlineLine = do
  notFollowedBy pHeadlineMarker
  takeWhileP Nothing (/= '\n') <* eol

pHeadlineMarker :: Parser ()
pHeadlineMarker = void (takeWhile1P Nothing (== '*') *> char ' ')

pPropertyDrawer :: Parser (Map Text Text)
pPropertyDrawer = do
  _ <- hspace *> string' ":PROPERTIES:" <* hspace <* eol
  entries <- manyTill pPropertyLine (try (hspace *> string' ":END:" <* hspace <* eol))
  pure (Map.fromList entries)

pPropertyLine :: Parser (Text, Text)
pPropertyLine = do
  hspace
  _ <- char ':'
  key <- takeWhile1P (Just "property key") (\c -> c /= ':' && c /= ' ' && c /= '\n')
  _ <- char ':'
  val <- takeWhileP Nothing (/= '\n') <* eol
  pure (T.toUpper key, T.strip val)

todoKeywords :: [Text]
todoKeywords = ["TODO", "NEXT", "WAIT", "DONE", "CANCELLED"]

splitHeadline :: Text -> (Maybe Text, Text, [Text])
splitHeadline t0 =
  let (todo, t1) = case [kw | kw <- todoKeywords, kw == t0 || (kw <> " ") `T.isPrefixOf` t0] of
        (kw : _) -> (Just kw, T.strip (T.drop (T.length kw) t0))
        [] -> (Nothing, t0)
      (title, tags) = splitTags t1
   in (todo, title, tags)

-- | Peel a trailing @:tag1:tag2:@ group off a headline.
splitTags :: Text -> (Text, [Text])
splitTags t =
  let t' = T.stripEnd t
      (before, lastWord) = T.breakOnEnd " " t'
   in if T.length lastWord >= 2
        && ":" `T.isPrefixOf` lastWord
        && ":" `T.isSuffixOf` lastWord
        then (T.stripEnd before, filter (not . T.null) (T.splitOn ":" lastWord))
        else (t', [])

buildTree :: [FlatHeadline] -> [Headline]
buildTree [] = []
buildTree (f : rest) =
  let (kids, siblings) = span (\g -> fhLevel g > fhLevel f) rest
   in toHeadline f (buildTree kids) : buildTree siblings
  where
    toHeadline FlatHeadline {..} children =
      Headline
        { hlLevel = fhLevel
        , hlTodo = fhTodo
        , hlTitle = fhTitle
        , hlTags = fhTags
        , hlProperties = fhProperties
        , hlBody = fhBody
        , hlChildren = children
        }

-- | Scan free text for @[[target]]@ and @[[target][description]]@ links.
extractLinks :: Text -> [Link]
extractLinks t0 =
  case T.breakOn "[[" t0 of
    (_, rest)
      | T.null rest -> []
      | otherwise ->
          case tryLink (T.drop 2 rest) of
            Just (lnk, rest') -> lnk : extractLinks rest'
            Nothing -> extractLinks (T.drop 2 rest)
  where
    tryLink s =
      let (target, rest) = T.breakOn "]" s
       in if
            | T.null rest -> Nothing
            | "][" `T.isPrefixOf` rest ->
                let (desc, rest') = T.breakOn "]]" (T.drop 2 rest)
                 in if T.null rest'
                      then Nothing
                      else Just (mkLink target (Just desc), T.drop 2 rest')
            | "]]" `T.isPrefixOf` rest -> Just (mkLink target Nothing, T.drop 2 rest)
            | otherwise -> Nothing
    mkLink target desc =
      Link (maybe (RawTarget target) IdTarget (T.stripPrefix "id:" target)) desc
