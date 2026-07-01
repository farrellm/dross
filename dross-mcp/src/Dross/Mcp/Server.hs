-- | MCP server over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout.
-- Diagnostics go to stderr; stdout carries protocol messages only.
module Dross.Mcp.Server
  ( runServer
  ) where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.IO

import Dross.Mcp.Protocol
import Dross.Tools

runServer :: Env -> IO ()
runServer env = do
  hSetBuffering stdout LineBuffering
  loop
  where
    loop = do
      end <- isEOF
      unless end $ do
        line <- BS.getLine
        unless (BS.null line) $
          case eitherDecodeStrict line :: Either String Request of
            Left err -> respond (mkError Null parseErrorCode (T.pack err))
            Right (Request Nothing _ _) -> pure () -- notification: no response
            Right (Request (Just rid) method params) ->
              respond =<< dispatch env rid method (fromMaybe Null params)
        loop

respond :: Value -> IO ()
respond v = do
  BSL.hPut stdout (encode v)
  BSL.hPut stdout "\n"
  hFlush stdout

dispatch :: Env -> Value -> Text -> Value -> IO Value
dispatch env rid method params = case method of
  "initialize" ->
    let clientVer =
          parseMaybe (withObject "params" (.: "protocolVersion")) params
        ver = fromMaybe ("2025-06-18" :: Text) clientVer
     in pure . mkResult rid $
          object
            [ "protocolVersion" .= ver
            , "capabilities" .= object ["tools" .= object []]
            , "serverInfo"
                .= object
                  [ "name" .= ("dross-mcp" :: Text)
                  , "version" .= ("0.1.0" :: Text)
                  ]
            ]
  "ping" -> pure (mkResult rid (object []))
  "tools/list" -> pure (mkResult rid (object ["tools" .= toolDefs]))
  "tools/call" ->
    case parseMaybe pCall params of
      Nothing ->
        pure (mkError rid invalidParamsCode "tools/call requires a tool name")
      Just (name, args) -> do
        res <- callTool env name args
        pure . mkResult rid $ case res of
          Right v -> toolResult False (jsonText v)
          Left e -> toolResult True e
  _ -> pure (mkError rid methodNotFoundCode ("method not found: " <> method))
  where
    pCall = withObject "params" $ \o ->
      (,) <$> o .: "name" <*> o .:? "arguments" .!= object []

toolResult :: Bool -> Text -> Value
toolResult isErr txt =
  object
    [ "content" .= [object ["type" .= ("text" :: Text), "text" .= txt]]
    , "isError" .= isErr
    ]

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BSL.toStrict . encode
