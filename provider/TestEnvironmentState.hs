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

entryHas :: Text -> Text -> KM.KeyMap A.Value -> Bool
entryHas name field state =
    case KM.lookup (K.fromText name) state of
        Just (A.Object entry) -> KM.member (K.fromText field) entry
        _ -> False

main :: IO ()
main = do
    let state =
            KM.fromList
                [ ("moved", A.object ["userName" A..= ("moved" :: Text), "uid" A..= (2001 :: Integer), "node" A..= ("old-node" :: Text)])
                , ("partial", A.object ["userName" A..= ("partial" :: Text), "uid" A..= (2002 :: Integer), "node" A..= ("old-node" :: Text)])
                , ("retired", A.object ["userName" A..= ("retired" :: Text), "uid" A..= (2003 :: Integer), "node" A..= ("old-node" :: Text)])
                , ("new", A.object ["userName" A..= ("new" :: Text), "uid" A..= (2004 :: Integer)])
                , ("legacy", A.object
                    [ "userName" A..= ("legacy" :: Text)
                    , "uid" A..= (2005 :: Integer)
                    , "node" A..= ("new-node" :: Text)
                    , "present" A..= True
                    , "pendingCleanupNodes" A..= (["old-node"] :: [Text])
                    ])
                ]
    let desired =
            M.fromList
                [ ("moved", "new-node")
                , ("partial", "new-node")
                , ("new", "new-node")
                , ("legacy", "new-node")
                ]
    let observed =
            M.fromList
                [ ("old-node", M.fromList [("partial", 2002)])
                , ("new-node", M.fromList [("moved", 2001), ("partial", 2002), ("new", 2004), ("legacy", 2005)])
                ]
    let updated = reconcileObservedNodesInState desired observed state

    assertEqual "moved advances when old is absent and destination exists" (Just "new-node") (nodeFor "moved" updated)
    assertEqual "partial move keeps old placement while both accounts exist" (Just "old-node") (nodeFor "partial" updated)
    assertEqual "retired placement clears when old account is absent" Nothing (nodeFor "retired" updated)
    assertEqual "new environment records observed destination" (Just "new-node") (nodeFor "new" updated)
    assertEqual "legacy pending cleanup collapses to observed placement" (Just "new-node") (nodeFor "legacy" updated)
    assertEqual "legacy present field removed" False (entryHas "legacy" "present" updated)
    assertEqual "legacy pending field removed" False (entryHas "legacy" "pendingCleanupNodes" updated)

    let destinationOnly = M.fromList [("new-node", M.fromList [("partial", 2002)])]
    let conservative = reconcileObservedNodesInState desired destinationOnly state
    assertEqual "unobserved old node keeps prior placement" (Just "old-node") (nodeFor "partial" conservative)

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
