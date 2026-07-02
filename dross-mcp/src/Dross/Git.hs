-- | Git auto-commit for the notes repo (decided policy: every
-- agent-initiated change is a commit — auditable, revertable, doubles as
-- sync). All git output is captured so nothing leaks onto stdout (the MCP
-- protocol stream); failures are logged to stderr and never fatal, because
-- by the time we commit the note is already safely on disk.
module Dross.Git
  ( isGitRepo
  , autoCommit
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)
import System.Process (proc, readCreateProcessWithExitCode)

-- | Captured-output git call; Left holds a one-line diagnostic.
runGit :: FilePath -> [String] -> IO (Either String String)
runGit dir args = do
  r <-
    try (readCreateProcessWithExitCode (proc "git" ("-C" : dir : args)) "")
      :: IO (Either IOException (ExitCode, String, String))
  pure $ case r of
    Left e -> Left (show e)
    Right (ExitSuccess, out, _) -> Right out
    Right (ExitFailure c, out, err) ->
      Left ("git exited " <> show c <> ": " <> strip (err <> out))
  where
    strip = T.unpack . T.strip . T.pack

-- | True when the directory lives inside a git work tree (and git exists).
isGitRepo :: FilePath -> IO Bool
isGitRepo dir =
  either (const False) ((== "true") . T.strip . T.pack)
    <$> runGit dir ["rev-parse", "--is-inside-work-tree"]

-- | Stage and commit the given paths on the current branch. Only those
-- paths: concurrent Emacs edits or staged work must not be swept into an
-- agent commit. Signing is disabled so a gpg prompt can never hang the
-- server. A no-op commit (content unchanged) fails; that and every other
-- failure is logged and swallowed.
autoCommit :: FilePath -> Text -> [FilePath] -> IO ()
autoCommit dir msg paths = do
  add <- runGit dir (["add", "--"] <> paths)
  case add of
    Left err -> warn ("add failed: " <> err)
    Right _ -> do
      c <-
        runGit dir $
          ["-c", "commit.gpgsign=false", "commit", "-m", T.unpack msg, "--"] <> paths
      case c of
        Left err -> warn ("commit failed: " <> err)
        Right _ -> pure ()
  where
    warn s = hPutStrLn stderr ("dross-mcp: auto-commit: " <> s)
