module Main (main) where

import Control.Monad (unless)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

import Data.Text qualified as T

import Dross.Embed (EmbedConfig (..), newEmbedConfig)
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
      hPutStrLn stderr "dross-mcp: VOYAGE_API_KEY unset — semantic-search disabled"
      pure Nothing
    Just key -> do
      cfg <- newEmbedConfig (T.pack key) (T.pack <$> modelOverride) urlOverride
      hPutStrLn stderr ("dross-mcp: embeddings enabled (" <> T.unpack (embedModel cfg) <> ")")
      pure (Just cfg)
  hPutStrLn stderr ("dross-mcp serving " <> dir')
  runServer (Env dir' conn embed)
