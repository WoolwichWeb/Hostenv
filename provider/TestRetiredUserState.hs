{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Hostenv.Provider.RetiredUserState (clearPendingCleanupNodesInState)
import System.Exit (exitFailure)

assertEqual :: (Eq a, Show a) => Text -> a -> a -> IO ()
assertEqual label expected actual =
    if expected == actual
        then pure ()
        else do
            TIO.putStrLn ("assertion failed (" <> label <> ")")
            print expected
            print actual
            exitFailure

pendingFor :: Text -> KM.KeyMap A.Value -> [Text]
pendingFor name state =
    case KM.lookup (K.fromText name) state of
        Just (A.Object entry) ->
            case KM.lookup (K.fromString "pendingCleanupNodes") entry of
                Just value -> case A.fromJSON value of
                    A.Success pending -> pending
                    A.Error _ -> []
                Nothing -> []
        _ -> []

main :: IO ()
main = do
    let state = KM.fromList
            [ ("moved", A.object ["pendingCleanupNodes" A..= (["old-node", "older-node"] :: [Text])])
            , ("retired", A.object ["pendingCleanupNodes" A..= (["old-node"] :: [Text])])
            , ("unrelated", A.object ["pendingCleanupNodes" A..= (["other-node"] :: [Text])])
            ]
    let updated = clearPendingCleanupNodesInState ["old-node"] state

    assertEqual "moved cleanup clears only successful node" ["older-node"] (pendingFor "moved" updated)
    assertEqual "retired cleanup clears successful node" [] (pendingFor "retired" updated)
    assertEqual "unrelated cleanup stays pending" ["other-node"] (pendingFor "unrelated" updated)

    let failedDeployment = clearPendingCleanupNodesInState [] state
    assertEqual "failed deployment leaves cleanup pending" ["old-node", "older-node"] (pendingFor "moved" failedDeployment)

    TIO.putStrLn "ok"
