module Main (main) where

import System.Directory (doesDirectoryExist, makeAbsolute)
import System.IO (hPutStrLn)

import Data.Text qualified as T

import Dross.Embed (EmbedConfig (..), newEmbedConfig)
import Dross.Git (isGitRepo)
import Dross.Index (checkSchema, connectDb, refreshIndex)
import Dross.Mcp.Server (runServer)
import Dross.Tools (Env (..))

main :: IO ()
main = do
  args <- getArgs
  envDir <- lookupEnv "DROSS_NOTES_DIR"
  dir <- case (args, envDir) of
    ([d], _) -> pure d
    ([], Just d) -> pure d
    _ -> die "usage: dross-mcp <notes-dir>  (or set DROSS_NOTES_DIR)"
  dir' <- makeAbsolute dir
  ok <- doesDirectoryExist dir'
  unless ok $ die ("notes directory does not exist: " <> dir')
  conn <- connectDb
  hasSchema <- checkSchema conn
  unless hasSchema $
    die "database schema missing — run `make db-migrate` (see Makefile)"
  refreshIndex conn dir'
  apiKey <- lookupEnv "VOYAGE_API_KEY"
  modelOverride <- lookupEnv "DROSS_EMBED_MODEL"
  urlOverride <- lookupEnv "DROSS_EMBED_URL"
  embed <- case apiKey of
    Nothing -> do
      hPutStrLn stderr "dross-mcp: VOYAGE_API_KEY unset — semantic-search and similar-notes disabled"
      pure Nothing
    Just key -> do
      cfg <- newEmbedConfig (toText key) (toText <$> modelOverride) urlOverride
      hPutStrLn stderr ("dross-mcp: embeddings enabled (" <> T.unpack (embedModel cfg) <> ")")
      pure (Just cfg)
  git <- isGitRepo dir'
  unless git $
    hPutStrLn stderr "dross-mcp: notes dir is not a git repo — auto-commit disabled"
  hPutStrLn stderr ("dross-mcp serving " <> dir')
  runServer (Env dir' conn embed git)
