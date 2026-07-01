module Main (main) where

import Control.Monad (unless)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

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
  hPutStrLn stderr ("dross-mcp serving " <> dir')
  runServer (Env dir' conn)
