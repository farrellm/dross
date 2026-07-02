{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Monad (unless)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit

import Dross.Chunk (chunkNode)
import Dross.Embed (renderVector)
import Dross.Org.Edit
import Dross.Org.Parser
import Dross.Org.Types
import Dross.Tools (renderCapture, renderNote)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check :: (Eq a, Show a) => String -> a -> a -> IO ()
      check label expected actual =
        unless (expected == actual) $ do
          modifyIORef' failures (+ 1)
          putStrLn $
            "FAIL "
              <> label
              <> "\n  expected: "
              <> show expected
              <> "\n  actual:   "
              <> show actual

  doc <- case parseDocument "sample.org" sample of
    Left err -> putStrLn err >> exitFailure
    Right d -> pure d

  check "file id" (Just "file-id-123") (documentId doc)
  check "title" (Just "Sample Note") (documentTitle doc)
  check "filetags" ["dross", "test"] (docFiletags doc)

  (h1, h2) <- case docHeadlines doc of
    [a, b] -> pure (a, b)
    hs -> do
      putStrLn ("expected 2 top-level headlines, got " <> show (length hs))
      exitFailure

  check "h1 todo" (Just "TODO") (hlTodo h1)
  check "h1 title" "First headline" (hlTitle h1)
  check "h1 tags" ["alpha", "beta"] (hlTags h1)
  check "h1 id" (Just "hl-id-456") (Map.lookup "ID" (hlProperties h1))
  check "h1 body" "Body of first headline." (T.strip (hlBody h1))
  check "h1 child levels" [2] (map hlLevel (hlChildren h1))
  check "h2 todo" Nothing (hlTodo h2)
  check "h2 title" "Second" (hlTitle h2)
  check "h2 tags" ["gamma"] (hlTags h2)

  check
    "preamble links"
    [Link (IdTarget "other-note") (Just "another note")]
    (extractLinks (docPreamble doc))

  child <- case hlChildren h1 of
    [c] -> pure c
    cs -> do
      putStrLn ("expected 1 child headline, got " <> show (length cs))
      exitFailure

  check
    "child links"
    [ Link (RawTarget "https://example.com") (Just "a web link")
    , Link (IdTarget "third") Nothing
    ]
    (extractLinks (hlBody child))

  check
    "node ids"
    ["file-id-123", "hl-id-456"]
    (documentNodeIds doc)

  -- Edit: splitMetadata keeps the drawer + keyword lines, nothing else.
  check
    "splitMetadata meta"
    [ ":PROPERTIES:"
    , ":ID: file-id-123"
    , ":END:"
    , "#+title: Sample Note"
    , "#+filetags: :dross:test:"
    ]
    (fst (splitMetadata sample))
  check
    "splitMetadata body head"
    (Just "")
    (listToMaybe (snd (splitMetadata sample)))

  -- A #+begin_src line is not a keyword and must stay in the body.
  let srcSample =
        """
        :PROPERTIES:
        :ID: src-note
        :END:
        #+title: Src
        #+begin_src haskell
        main = pure ()
        #+end_src

        """
  check
    "splitMetadata stops at begin_src"
    ([":PROPERTIES:", ":ID: src-note", ":END:", "#+title: Src"], Just "#+begin_src haskell")
    (let (m, b) = splitMetadata srcSample in (m, listToMaybe b))

  -- renderFile keeps metadata verbatim and swaps the body.
  let sampleMeta = fst (splitMetadata sample)
      updated = renderFile sampleMeta "New body text."
  check
    "renderFile"
    """
    :PROPERTIES:
    :ID: file-id-123
    :END:
    #+title: Sample Note
    #+filetags: :dross:test:

    New body text.

    """
    updated
  check
    "renderFile reparses with same id"
    (Right (Just "file-id-123"))
    (documentId <$> parseDocument "sample.org" updated)
  check
    "renderFile empty body keeps metadata only"
    5
    (length (T.lines (renderFile sampleMeta "")))
  check
    "renderFile inverts splitMetadata"
    sample
    (let (m, b) = splitMetadata sample in renderFile m (T.intercalate "\n" b))

  -- setKeyword: replace in place, remove, and append-if-missing.
  check
    "setKeyword replaces title in place"
    [ ":PROPERTIES:"
    , ":ID: file-id-123"
    , ":END:"
    , "#+title: Renamed"
    , "#+filetags: :dross:test:"
    ]
    (setKeyword "title" (Just "Renamed") sampleMeta)
  check
    "setKeyword removes filetags"
    [":PROPERTIES:", ":ID: file-id-123", ":END:", "#+title: Sample Note"]
    (setKeyword "filetags" Nothing sampleMeta)
  check
    "setKeyword appends missing keyword"
    (sampleMeta <> ["#+author: me"])
    (setKeyword "author" (Just "me") sampleMeta)

  -- appendBody separates with exactly one blank line and ends with newline.
  check
    "appendBody"
    (T.stripEnd sample <> "\n\nAppended paragraph.\n")
    (appendBody sample "Appended paragraph.\n")

  -- A rendered capture parses back into one headline with its metadata.
  let cap =
        renderCapture
          "cap-id-1"
          "[2026-07-01 Tue 14:32]"
          (Just "Quick thought")
          (Just "telegram")
          "Raw capture body."
  case parseDocument "inbox.org" cap of
    Left err -> putStrLn err >> exitFailure
    Right capDoc -> case docHeadlines capDoc of
      [hl] -> do
        check "capture title" "[2026-07-01 Tue 14:32] Quick thought" (hlTitle hl)
        check "capture id" (Just "cap-id-1") (Map.lookup "ID" (hlProperties hl))
        check
          "capture created"
          (Just "[2026-07-01 Tue 14:32]")
          (Map.lookup "CREATED" (hlProperties hl))
        check "capture source" (Just "telegram") (Map.lookup "SOURCE" (hlProperties hl))
        check "capture body" "Raw capture body." (T.strip (hlBody hl))
      hs -> do
        putStrLn ("expected 1 capture headline, got " <> show (length hs))
        exitFailure

  -- renderNote with extra drawer properties (archive-document's :SOURCE:).
  case parseDocument "lit.org" (renderNote "lit-1" [("SOURCE", "https://x.test")] "A Paper" ["literature", "ATTACH"] "[[file:data/li/t-1/paper.pdf][paper.pdf]]") of
    Left err -> putStrLn err >> exitFailure
    Right litDoc -> do
      check "lit id" (Just "lit-1") (documentId litDoc)
      check "lit source" (Just "https://x.test") (Map.lookup "SOURCE" (docProperties litDoc))
      check "lit filetags" ["literature", "ATTACH"] (docFiletags litDoc)
      check "lit title" (Just "A Paper") (documentTitle litDoc)

  -- Chunking: typical notes are one title-prefixed chunk; long ones split
  -- at segment (headline) boundaries, then blank lines, then hard splits.
  check
    "chunk small note"
    ["Title\n\nIntro.\nHeadline\nBody."]
    (chunkNode 8000 "Title" ["Intro.", "Headline\nBody."])
  check
    "chunk empty body is just the title"
    ["Title"]
    (chunkNode 8000 "Title" ["", "  \n  "])
  check
    "chunk packs segments up to the budget"
    ["T\n\naaaa\nbbbb", "T\n\ncccc"]
    (chunkNode 9 "T" ["aaaa", "bbbb", "cccc"])
  check
    "chunk splits oversized segment at blank lines"
    ["T\n\naaaa", "T\n\nbbbb"]
    (chunkNode 5 "T" ["aaaa\n\nbbbb"])
  check
    "chunk hard-splits a single long paragraph"
    ["T\n\naaaa", "T\n\naa"]
    (chunkNode 4 "T" ["aaaaaa"])

  -- pgvector literal (pins show's float rendering).
  check
    "renderVector"
    "[0.5,-2.0,1.0e-2]"
    (renderVector [0.5, -2, 1.0e-2])
  check "renderVector empty" "[]" (renderVector [])

  n <- readIORef failures
  if n == 0
    then putStrLn "all checks passed"
    else exitFailure

sample :: Text
sample =
  """
  :PROPERTIES:
  :ID: file-id-123
  :END:
  #+title: Sample Note
  #+filetags: :dross:test:

  Intro paragraph linking to [[id:other-note][another note]].

  * TODO First headline :alpha:beta:
  :PROPERTIES:
  :ID: hl-id-456
  :END:
  Body of first headline.

  ** Child headline
  Nested body with [[https://example.com][a web link]] and [[id:third]].

  * Second :gamma:
  No drawer here.

  """
