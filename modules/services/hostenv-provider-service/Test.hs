{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

import Control.Monad (unless)
import "cryptonite" Crypto.Hash (SHA256)
import "cryptonite" Crypto.MAC.HMAC (HMAC (..), hmac)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Text as T
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (ExitFailure), exitFailure)
import System.IO (hClose, openTempFile)

import Hostenv.Provider.Service

assert :: Bool -> String -> IO ()
assert cond msg = unless cond $ do
  putStrLn ("FAIL: " <> msg)
  exitFailure

main :: IO ()
main = do
  testGitHubSig
  testGitLabToken
  testPlanParsing
  testProjectHashSelection
  testCommandSequence
  testNodeDeployFailureIsReported
  testRemovedEnvironmentRequiresUnfilteredDeploy
  testTemplateRender
  testGitCredentials
  testReadGitlabSecrets
  putStrLn "ok"


testGitHubSig :: IO ()
testGitHubSig = do
  let secret = "secret"
  let body = BL.fromStrict "payload"
  let digest = hmac secret (BL.toStrict body) :: HMAC SHA256
  let expected = BAE.convertToBase BAE.Base16 (BA.convert digest :: BS.ByteString)
  let header = "sha256=" <> expected
  assert (verifyGitHubSignature secret body header) "github signature should validate"
  assert (not (verifyGitHubSignature secret body "sha256=deadbeef")) "github signature should reject invalid"


testGitLabToken :: IO ()
testGitLabToken = do
  assert (verifyGitLabToken "token" "token") "gitlab token should validate"
  assert (not (verifyGitLabToken "token" "bad")) "gitlab token should reject invalid"


testPlanParsing :: IO ()
testPlanParsing = do
  let planJson =
        BLC.pack
          "{\"environments\":{\"env-a\":{\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-main\"},\"node\":\"node-a\"},\"env-b\":{\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-dev\"},\"node\":\"node-b\"},\"env-c\":{\"hostenv\":{\"organisation\":\"other\",\"project\":\"x\",\"projectNameHash\":\"hash-x\"},\"node\":\"node-c\"}}}"
  case projectForHash "hash-main" planJson of
    Left err -> assert False ("projectForHash failed: " <> show err)
    Right ref ->
      assert (ref.prOrg == "acme" && ref.prProject == "site") "projectForHash should resolve org/project"

testCommandSequence :: IO ()
testCommandSequence = do
  let planJson =
        BLC.pack
          "{\"environments\":{\"env-a\":{\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-main\"},\"node\":\"node-a\"},\"env-b\":{\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-dev\"},\"node\":\"node-b\"}}}"
  ref <- newIORef ([] :: [CommandSpec])
  let runner = recordRunner ref
  let cfg = WebhookConfig "/tmp/provider" "/tmp/provider/generated/plan.json"
  let proj = ProjectRef "acme" "site"
  result <- runWebhookWith runner (pure planJson) cfg proj
  case result of
    Left err -> assert False ("webhook run failed: " <> show err)
    Right res -> do
      assert (res.webhookOk) "webhook run should succeed"
      cmds <- readIORef ref
      let expected =
            [ CommandSpec "nix" ["flake", "update", "acme__site"] "/tmp/provider"
            , CommandSpec "nix" ["run", ".#hostenv-provider", "--", "plan"] "/tmp/provider"
            , CommandSpec "nix" ["run", ".#hostenv-provider", "--", "deploy", "--node", "node-a"] "/tmp/provider"
            , CommandSpec "nix" ["run", ".#hostenv-provider", "--", "deploy", "--node", "node-b"] "/tmp/provider"
            ]
      assert (cmds == expected) "webhook command sequence should match"


testNodeDeployFailureIsReported :: IO ()
testNodeDeployFailureIsReported = do
  let planJson =
        BLC.pack
          "{\"environments\":{\"env-a\":{\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-main\"},\"node\":\"new-node\"}}}"
  ref <- newIORef ([] :: [CommandSpec])
  let runner spec = do
        modifyIORef' ref (<> [spec])
        if spec.cmdArgs == ["run", ".#hostenv-provider", "--", "deploy", "--node", "new-node"]
          then pure (Left (CommandError spec (ExitFailure 1) "" "node-scoped deploy refused"))
          else pure (Right (CommandOutput "" ""))
  let cfg = WebhookConfig "/tmp/provider" "/tmp/provider/generated/plan.json"
  let proj = ProjectRef "acme" "site"
  result <- runWebhookWith runner (pure planJson) cfg proj
  case result of
    Left err -> assert False ("webhook run failed unexpectedly: " <> show err)
    Right res -> do
      assert (not res.webhookOk) "failed node-scoped deploy should make the webhook fail"
      assert (res.webhookNodes == ["new-node"]) "webhook should deploy only the project's current destination node"
      cmds <- readIORef ref
      let expected =
            [ CommandSpec "nix" ["flake", "update", "acme__site"] "/tmp/provider"
            , CommandSpec "nix" ["run", ".#hostenv-provider", "--", "plan"] "/tmp/provider"
            , CommandSpec "nix" ["run", ".#hostenv-provider", "--", "deploy", "--node", "new-node"] "/tmp/provider"
            ]
      assert (cmds == expected) "webhook should delegate node lifecycle safety to hostenv-provider deploy"


testRemovedEnvironmentRequiresUnfilteredDeploy :: IO ()
testRemovedEnvironmentRequiresUnfilteredDeploy = do
  let previousPlan =
        BLC.pack
          "{\"environments\":{\"prod\":{\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-prod\"},\"node\":\"node-b\"}}}"
  let currentPlan =
        BLC.pack
          "{\"environments\":{}}"
  plansRef <- newIORef [previousPlan, currentPlan]
  let loadPlan = do
        plans <- readIORef plansRef
        case plans of
          [] -> pure currentPlan
          (planRaw:rest) -> do
            modifyIORef' plansRef (const rest)
            pure planRaw
  commandsRef <- newIORef ([] :: [CommandSpec])
  let runner = recordRunner commandsRef
  let cfg = WebhookConfig "/tmp/provider" "/tmp/provider/generated/plan.json"
  let proj = ProjectRef "acme" "site"
  result <- runWebhookWith runner loadPlan cfg proj
  case result of
    Left (WebhookPlanError err) -> do
      assert ("prod" `T.isInfixOf` err) "removal error should name the removed environment"
      assert ("nix run .#hostenv-provider -- deploy" `T.isInfixOf` err) "removal error should require an unfiltered provider deploy"
      cmds <- readIORef commandsRef
      let expected =
            [ CommandSpec "nix" ["flake", "update", "acme__site"] "/tmp/provider"
            , CommandSpec "nix" ["run", ".#hostenv-provider", "--", "plan"] "/tmp/provider"
            ]
      assert (cmds == expected) "environment removal should stop before any node-scoped deploy"
    Left err -> assert False ("unexpected webhook error: " <> show err)
    Right _ -> assert False "environment removal should fail closed instead of guessing a cleanup node"


recordRunner :: IORef [CommandSpec] -> CommandRunner
recordRunner ref spec = do
  modifyIORef' ref (<> [spec])
  pure (Right (CommandOutput "" ""))


testProjectHashSelection :: IO ()
testProjectHashSelection = do
  let planJson =
        BLC.pack
          "{\"environments\":{\"main\":{\"type\":\"production\",\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-prod\"}},\"dev\":{\"type\":\"development\",\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-dev\"}}}}"
  case projectHashFor "acme" "site" planJson of
    Left err -> assert False ("projectHashFor failed: " <> show err)
    Right hash -> assert (hash == "hash-prod") "projectHashFor should prefer production"

  let planJson2 =
        BLC.pack
          "{\"environments\":{\"main\":{\"type\":\"development\",\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-main\"}},\"feature\":{\"type\":\"development\",\"hostenv\":{\"organisation\":\"acme\",\"project\":\"site\",\"projectNameHash\":\"hash-feature\"}}}}"
  case projectHashFor "acme" "site" planJson2 of
    Left err -> assert False ("projectHashFor failed: " <> show err)
    Right hash -> assert (hash == "hash-main") "projectHashFor should prefer main when no production"

testTemplateRender :: IO ()
testTemplateRender = do
  let template = "inputs = {\\n{{HOSTENV_PROJECT_INPUTS}}\\n};"
  let inputs = renderProjectInputs [("acme__site", "gitlab:acme/site?dir=.hostenv")]
  case renderFlakeTemplate template inputs of
    Left err -> assert False ("renderFlakeTemplate failed: " <> show err)
    Right out -> assert (T.isInfixOf "acme__site.url" out) "template should include rendered inputs"


testGitCredentials :: IO ()
testGitCredentials = do
  let rendered = renderGitCredentials [("https://gitlab.com/acme/site.git", "token123")]
  assert (T.isInfixOf "oauth2:token123@gitlab.com" rendered) "credentials should inject token"


testReadGitlabSecrets :: IO ()
testReadGitlabSecrets = do
  tmpDir <- getTemporaryDirectory
  (path, handle) <- openTempFile tmpDir "gitlab-secrets"
  hClose handle
  writeFile path "client_id=abc123\n# comment\nclient_secret=def456\n"
  secrets <- readGitlabSecrets path
  removeFile path
  assert (secrets.gitlabClientId == "abc123") "readGitlabSecrets should parse client_id"
  assert (secrets.gitlabClientSecret == "def456") "readGitlabSecrets should parse client_secret"
