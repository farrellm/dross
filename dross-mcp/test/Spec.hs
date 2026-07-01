module Main (main) where

import Control.Monad (unless)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit

import Dross.Org.Parser
import Dross.Org.Types

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

  n <- readIORef failures
  if n == 0
    then putStrLn "all checks passed"
    else exitFailure

sample :: Text
sample =
  T.unlines
    [ ":PROPERTIES:"
    , ":ID: file-id-123"
    , ":END:"
    , "#+title: Sample Note"
    , "#+filetags: :dross:test:"
    , ""
    , "Intro paragraph linking to [[id:other-note][another note]]."
    , ""
    , "* TODO First headline :alpha:beta:"
    , ":PROPERTIES:"
    , ":ID: hl-id-456"
    , ":END:"
    , "Body of first headline."
    , ""
    , "** Child headline"
    , "Nested body with [[https://example.com][a web link]] and [[id:third]]."
    , ""
    , "* Second :gamma:"
    , "No drawer here."
    ]
