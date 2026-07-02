-- | AST for the org subset Dross indexes: headlines, property drawers,
-- tags, file keywords, and links. Anything richer (agenda semantics,
-- complex refiling) is out of scope for the server — that's what Emacs
-- is for.
module Dross.Org.Types
  ( Document (..)
  , Headline (..)
  , Link (..)
  , LinkTarget (..)
  , documentId
  , documentTitle
  , documentNodeIds
  , allHeadlines
  , subtreeText
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

data Document = Document
  { docProperties :: Map Text Text
    -- ^ File-level property drawer (keys uppercased); org-node keeps the
    -- note's @:ID:@ here.
  , docKeywords :: Map Text Text
    -- ^ @#+key: value@ lines (keys lowercased).
  , docFiletags :: [Text]
  , docPreamble :: Text
    -- ^ Body text before the first headline (keyword lines excluded).
  , docHeadlines :: [Headline]
  }
  deriving (Eq, Show)

data Headline = Headline
  { hlLevel :: Int
  , hlTodo :: Maybe Text
  , hlTitle :: Text
  , hlTags :: [Text]
  , hlProperties :: Map Text Text
  , hlBody :: Text
  , hlChildren :: [Headline]
  }
  deriving (Eq, Show)

data Link = Link
  { linkTarget :: LinkTarget
  , linkDescription :: Maybe Text
  }
  deriving (Eq, Show)

data LinkTarget
  = IdTarget Text
    -- ^ @[[id:...]]@ — a link into the Zettelkasten.
  | RawTarget Text
    -- ^ Any other link (URL, file, ...).
  deriving (Eq, Show)

documentId :: Document -> Maybe Text
documentId = Map.lookup "ID" . docProperties

documentTitle :: Document -> Maybe Text
documentTitle = Map.lookup "title" . docKeywords

-- | Every node ID in the document: the file-level ID (if any) followed by
-- headline IDs in document order.
documentNodeIds :: Document -> [Text]
documentNodeIds doc =
  maybe [] pure (documentId doc)
    <> [i | hl <- allHeadlines doc, Just i <- [Map.lookup "ID" (hlProperties hl)]]

allHeadlines :: Document -> [Headline]
allHeadlines = concatMap flatten . docHeadlines
  where
    flatten hl = hl : concatMap flatten (hlChildren hl)

-- | A headline's own body plus everything under it, titles included.
subtreeText :: Headline -> Text
subtreeText hl =
  T.intercalate "\n" $
    hlBody hl : map child (hlChildren hl)
  where
    child c = T.intercalate "\n" [hlTitle c, subtreeText c]
