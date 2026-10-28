{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

module Hostenv.Provider.Util
  ( randomToken
  , parseForm
  , lookupParam
  , readInt64
  , escapeHtml
  , sanitizeName
  , splitNamespace
  , readSecret
  , pickFirstExisting
  ) where

import "cryptonite" Crypto.Random (getRandomBytes)
import qualified Data.ByteArray.Encoding as BAE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isSpace)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.URI (parseQuery)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

randomToken :: Int -> IO Text
randomToken bytes = do
  raw <- getRandomBytes bytes
  pure (TE.decodeUtf8 (BAE.convertToBase BAE.Base16 (raw :: BS.ByteString)))

parseForm :: BL.ByteString -> [(BS.ByteString, BS.ByteString)]
parseForm body =
  let parsed = parseQuery (BL.toStrict body)
   in foldr collect [] parsed
  where
    collect (k, Just v) acc = (k, v) : acc
    collect _ acc = acc

lookupParam :: BS.ByteString -> [(BS.ByteString, BS.ByteString)] -> Maybe Text
lookupParam key params = TE.decodeUtf8 <$> lookup key params

readInt64 :: Text -> Maybe Int64
readInt64 t =
  case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

escapeHtml :: Text -> Text
escapeHtml =
  T.concatMap
    (\case
      '<' -> "&lt;"
      '>' -> "&gt;"
      '&' -> "&amp;"
      '"' -> "&quot;"
      '\'' -> "&#39;"
      c -> T.singleton c
    )

splitNamespace :: Text -> (Text, Text)
splitNamespace path =
  case T.splitOn "/" path of
    [] -> ("", path)
    [single] -> (single, single)
    (x:xs) -> (x, last xs)

sanitizeName :: Text -> Text
sanitizeName = T.filter isAlphaNum . T.toLower

readSecret :: FilePath -> IO BS.ByteString
readSecret path = do
  raw <- BS.readFile path
  let trimmed = BSC.dropWhile isSpace (BSC.dropWhileEnd isSpace raw)
  if BS.null trimmed
    then dieWith "Webhook secret file is empty."
    else pure trimmed

pickFirstExisting :: [FilePath] -> IO (Maybe BS.ByteString)
pickFirstExisting [] = pure Nothing
pickFirstExisting (p:ps) = do
  exists <- doesFileExist p
  if exists
    then Just <$> readSecret p
    else pickFirstExisting ps


dieWith :: String -> IO a
dieWith msg = do
  hPutStrLn stderr ("hostenv-provider-service: " <> msg)
  exitFailure
