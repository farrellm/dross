{-# LANGUAGE OverloadedStrings #-}

-- | Minimal JSON-RPC 2.0 types for MCP over stdio. Only what the server
-- needs: parse incoming requests, build result/error responses.
module Dross.Mcp.Protocol
  ( Request (..)
  , mkResult
  , mkError
  , parseErrorCode
  , methodNotFoundCode
  , invalidParamsCode
  ) where

import Data.Aeson

data Request = Request
  { reqId :: Maybe Value
    -- ^ Absent for notifications, which must not be answered.
  , reqMethod :: Text
  , reqParams :: Maybe Value
  }
  deriving (Show)

instance FromJSON Request where
  parseJSON = withObject "Request" $ \o ->
    Request
      <$> o .:? "id"
      <*> o .: "method"
      <*> o .:? "params"

mkResult :: Value -> Value -> Value
mkResult rid result =
  object ["jsonrpc" .= ("2.0" :: Text), "id" .= rid, "result" .= result]

mkError :: Value -> Int -> Text -> Value
mkError rid code msg =
  object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "id" .= rid
    , "error" .= object ["code" .= code, "message" .= msg]
    ]

parseErrorCode, methodNotFoundCode, invalidParamsCode :: Int
parseErrorCode = -32700
methodNotFoundCode = -32601
invalidParamsCode = -32602
