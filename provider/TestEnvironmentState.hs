{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Hostenv.Provider.EnvironmentState (managedUsersToRetire, movedUsersOnNode, parsePasswdUsers, reconcileObservedNodesInState)
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

nodeFor :: Text -> KM.KeyMap A.Value -> Maybe Text
nodeFor name state = do
    A.Object entry <- KM.lookup (K.fromText name) state
    A.String node <- KM.lookup (K.fromString "node") entry
    pure node

main :: IO ()
main = do
    let state =
            KM.fromList
                [ ("moved", A.object ["userName" A..= ("moved" :: Text), "uid" A..= (2001 :: Integer), "node" A..= ("old-node" :: Text)])
                , ("partial", A.object ["userName" A..= ("partial" :: Text), "uid" A..= (2002 :: Integer), "node" A..= ("old-node" :: Text)])
                , ("retired", A.object ["userName" A..= ("retired" :: Text), "uid" A..= (2003 :: Integer), "node" A..= ("old-node" :: Text)])
                , ("new", A.object ["userName" A..= ("new" :: Text), "uid" A..= (2004 :: Integer)])
                ]
    let desired =
            M.fromList
                [ ("moved", "new-node")
                , ("partial", "new-node")
                , ("new", "new-node")
                ]
    let observed =
            M.fromList
                [ ("old-node", M.fromList [("partial", 2002)])
                , ("new-node", M.fromList [("moved", 2001), ("partial", 2002), ("new", 2004)])
                ]
    let updated = reconcileObservedNodesInState desired ["moved", "new"] observed state

    assertEqual "moved advances when old is absent and destination exists" (Just "new-node") (nodeFor "moved" updated)
    assertEqual "failed environment deploy keeps old placement" (Just "old-node") (nodeFor "partial" updated)
    assertEqual "retired placement clears when old account is absent" Nothing (nodeFor "retired" updated)
    assertEqual "new environment records observed destination" (Just "new-node") (nodeFor "new" updated)

    let destinationOnly = M.fromList [("new-node", M.fromList [("partial", 2002)])]
    let conservative = reconcileObservedNodesInState desired [] destinationOnly state
    assertEqual "unobserved old node keeps prior placement" (Just "old-node") (nodeFor "partial" conservative)

    let oldStillPresent =
            reconcileObservedNodesInState
                desired
                ["partial"]
                (M.fromList
                    [ ("old-node", M.fromList [("partial", 2002)])
                    , ("new-node", M.fromList [("partial", 2002)])
                    ])
                state
    assertEqual
        "successful environment deploy advances placement even when old cleanup failed"
        (Just "new-node")
        (nodeFor "partial" oldStillPresent)

    assertEqual
        "managed users to retire"
        [("moved", 2001), ("retired", 2003)]
        (managedUsersToRetire
            "old-node"
            desired
            (M.fromList [("moved", 2001), ("partial", 2002), ("retired", 2003), ("wrong-uid", 9999)])
            state)

    assertEqual
        "moved users on node"
        ["moved", "partial"]
        (movedUsersOnNode "old-node" desired state)

    assertEqual
        "passwd parser"
        (M.fromList [("alpha", 1234), ("beta", 2345)])
        (parsePasswdUsers "alpha:x:1234:100::/home/alpha:/bin/sh\nbeta:x:2345:100::/home/beta:/bin/sh\ninvalid\n")

    TIO.putStrLn "ok"
