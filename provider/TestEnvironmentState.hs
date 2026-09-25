{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Hostenv.Provider.EnvironmentState (managedIdentities, managedReservedUidConflicts, managedUserUidMismatches, managedUsersToRetire, observedNodesForUser, parsePasswdUsers, resolveMigrationSourceNode)
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

main :: IO ()
main = do
    let state =
            KM.fromList
                [ ("moved", A.object ["userName" A..= ("moved" :: Text), "uid" A..= (2001 :: Integer)])
                , ("retired", A.object ["userName" A..= ("retired" :: Text), "uid" A..= (2003 :: Integer)])
                , ("wrong-uid", A.object ["userName" A..= ("wrong-uid" :: Text), "uid" A..= (2004 :: Integer)])
                ]
    let desired = M.fromList [("moved", "new-node")]
    let oldUsers =
            M.fromList
                [ ("moved", 2001)
                , ("retired", 2003)
                , ("wrong-uid", 9999)
                ]

    assertEqual
        "managed users to retire"
        [("moved", 2001), ("retired", 2003)]
        (managedUsersToRetire "old-node" desired oldUsers S.empty state)

    assertEqual
        "stale managed UID mismatch"
        [("wrong-uid", 2004, 9999)]
        (managedUserUidMismatches oldUsers state)

    assertEqual
        "orphan runtime is still retired without passwd entry"
        [("moved", 2001), ("retired", 2003)]
        (managedUsersToRetire "old-node" desired (M.delete "retired" oldUsers) (S.singleton "retired") state)

    let uidConflictUsers =
            M.fromList
                [ ("moved", 2001)
                , ("someone-else", 2003)
                , ("wrong-uid", 9999)
                ]
    assertEqual
        "reserved UID owned by another username"
        [("retired", 2003, "someone-else")]
        (managedReservedUidConflicts uidConflictUsers state)

    assertEqual
        "managed identities"
        [("moved", 2001), ("retired", 2003), ("wrong-uid", 2004)]
        (managedIdentities state)

    let observed =
            M.fromList
                [ ("old-node", M.fromList [("moved", 2001)])
                , ("new-node", M.empty)
                ]
    assertEqual
        "observed user nodes"
        ["old-node"]
        (observedNodesForUser "moved" 2001 observed)

    assertEqual
        "observed migration source"
        (Right (Just "old-node"))
        (resolveMigrationSourceNode "new-node" "moved" 2001 Nothing observed)

    assertEqual
        "no migration source"
        (Right Nothing)
        (resolveMigrationSourceNode "new-node" "new" 2002 Nothing observed)

    assertEqual
        "explicit current node cannot suppress an observed source"
        (Left "migration source override for moved names its destination node new-node, but the same Hostenv user with UID 2001 is still present on source node(s): old-node. Use --skip-migrations moved only when intentionally deploying without migration.")
        (resolveMigrationSourceNode "new-node" "moved" 2001 (Just "new-node") observed)

    assertEqual
        "explicit current node is harmless when no source exists"
        (Right Nothing)
        (resolveMigrationSourceNode "new-node" "new" 2002 (Just "new-node") observed)

    assertEqual
        "explicit source validates UID"
        (Left "migration source old-node does not contain Hostenv user moved with UID 9999")
        (resolveMigrationSourceNode "new-node" "moved" 9999 (Just "old-node") observed)

    let ambiguous = M.insert "other-node" (M.fromList [("moved", 2001)]) observed
    assertEqual
        "ambiguous observed migration source"
        (Left "Hostenv user moved with UID 2001 exists on more than one possible migration source: old-node, other-node. Set --migration-source moved=<node>.")
        (resolveMigrationSourceNode "new-node" "moved" 2001 Nothing ambiguous)

    assertEqual
        "passwd parser"
        (M.fromList [("alpha", 1234), ("beta", 2345)])
        (parsePasswdUsers "alpha:x:1234:100::/home/alpha:/bin/sh\nbeta:x:2345:100::/home/beta:/bin/sh\ninvalid\n")

    TIO.putStrLn "ok"
