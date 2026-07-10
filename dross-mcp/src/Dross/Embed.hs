{-# LANGUAGE OverloadedStrings #-}

-- | Voyage AI embeddings client: POST texts, get vectors. Kept behind a
-- small interface (config + 'embedTexts') so swapping providers or moving
-- to a local model later is a config change, per CONCEPT.md. All failures
-- come back as 'Left'; nothing here writes to stdout (MCP protocol stream).
module Dross.Embed
  ( EmbedConfig (..)
  , InputType (..)
  , newEmbedConfig
  , embedTexts
  , renderVector
  ) where

import Control.Exception (try)
import Data.Aeson
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)

import Data.ByteString.Lazy qualified as BL

data EmbedConfig = EmbedConfig
  { embedApiKey :: Text
  , embedUrl :: String
  , embedModel :: Text
  , embedManager :: Manager
  }

-- | Voyage prepends different retrieval prompts for documents vs queries.
data InputType = Document | Query

-- | Config for the Voyage API; @model@ overrides the voyage-3.5 default
-- (its 1024-dim output matches the @vector(1024)@ schema column) and @url@
-- overrides the endpoint (another provider, a local model, a test mock).
newEmbedConfig :: Text -> Maybe Text -> Maybe String -> IO EmbedConfig
newEmbedConfig apiKey model url = do
  manager <- newTlsManager
  pure
    EmbedConfig
      { embedApiKey = apiKey
      , embedUrl = fromMaybe "https://api.voyageai.com/v1/embeddings" url
      , embedModel = fromMaybe "voyage-3.5" model
      , embedManager = manager
      }

-- | Maximum texts per request; Voyage allows up to 1000 but per-request
-- token limits bite first, and 64 8K-char chunks stay comfortably under.
batchSize :: Int
batchSize = 64

-- | Embed texts in order, batching internally. Returns one vector per
-- input, or the first error encountered.
embedTexts :: EmbedConfig -> InputType -> [Text] -> IO (Either Text [[Float]])
embedTexts _ _ [] = pure (Right [])
embedTexts cfg itype texts = go (batches texts)
  where
    batches [] = []
    batches ts = let (b, rest) = splitAt batchSize ts in b : batches rest
    go [] = pure (Right [])
    go (b : bs) =
      embedBatch cfg itype b >>= \case
        Left err -> pure (Left err)
        Right vs ->
          fmap (vs <>) <$> go bs

embedBatch :: EmbedConfig -> InputType -> [Text] -> IO (Either Text [[Float]])
embedBatch cfg itype texts = do
  req0 <- parseRequest (embedUrl cfg)
  let req =
        req0
          { method = "POST"
          , requestHeaders =
              [ ("Content-Type", "application/json")
              , ("Authorization", "Bearer " <> TE.encodeUtf8 (embedApiKey cfg))
              ]
          , requestBody = RequestBodyLBS (encode (embedRequest cfg itype texts))
          , responseTimeout = responseTimeoutMicro 120_000_000
          }
  r <- try (httpLbs req (embedManager cfg))
  pure $ case r of
    Left (e :: HttpException) -> Left ("embedding request failed: " <> show e)
    Right resp
      | code < 200 || code >= 300 ->
          Left
            ( "embedding API returned HTTP "
                <> show code
                <> ": "
                <> bodySnippet (responseBody resp)
            )
      | otherwise -> case eitherDecode (responseBody resp) of
          Left err -> Left ("could not parse embedding response: " <> toText err)
          Right (EmbedResponse items)
            | length items /= length texts ->
                Left "embedding API returned an unexpected number of vectors"
            | otherwise -> Right (map itemEmbedding (sortOn itemIndex items))
      where
        code = statusCode (responseStatus resp)

bodySnippet :: BL.ByteString -> Text
bodySnippet = T.take 300 . TE.decodeUtf8With TE.lenientDecode . BL.toStrict

embedRequest :: EmbedConfig -> InputType -> [Text] -> Value
embedRequest cfg itype texts =
  object
    [ "input" .= texts
    , "model" .= embedModel cfg
    , "input_type" .= inputType
    ]
  where
    inputType :: Text
    inputType = case itype of
      Document -> "document"
      Query -> "query"

newtype EmbedResponse = EmbedResponse [EmbedItem]

data EmbedItem = EmbedItem
  { itemIndex :: Int
  , itemEmbedding :: [Float]
  }

instance FromJSON EmbedResponse where
  parseJSON = withObject "EmbedResponse" $ \o ->
    EmbedResponse <$> o .: "data"

instance FromJSON EmbedItem where
  parseJSON = withObject "EmbedItem" $ \o ->
    EmbedItem <$> o .: "index" <*> o .: "embedding"

-- | pgvector input literal: @[0.1,0.2,...]@ (accepts @show@'s scientific
-- notation).
renderVector :: [Float] -> Text
renderVector v = "[" <> T.intercalate "," (map show v) <> "]"
