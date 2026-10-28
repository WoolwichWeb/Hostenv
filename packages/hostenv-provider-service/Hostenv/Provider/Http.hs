{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Hostenv.Provider.Http
  ( ErrorResponse(..)
  , errorWithBody
  ) where

import Data.Aeson (ToJSON (..), (.=))
import qualified Data.Aeson as A
import Data.Text (Text)
import Servant (ServerError(..))


data ErrorResponse = ErrorResponse
  { errMessage :: Text
  , errCommand :: Maybe Text
  , errExitCode :: Maybe Int
  , errStdout :: Maybe Text
  , errStderr :: Maybe Text
  }

instance ToJSON ErrorResponse where
  toJSON e =
    A.object
      [ "error" .= e.errMessage
      , "command" .= e.errCommand
      , "exitCode" .= e.errExitCode
      , "stdout" .= e.errStdout
      , "stderr" .= e.errStderr
      ]

errorWithBody :: ToJSON a => ServerError -> a -> ServerError
errorWithBody base payload =
  base
    { errBody = A.encode payload
    , errHeaders = [("Content-Type", "application/json")]
    }
