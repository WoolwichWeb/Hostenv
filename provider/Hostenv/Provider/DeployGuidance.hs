module Hostenv.Provider.DeployGuidance
    ( FlakeKeyStatus (..)
    , localTrustSetupLines
    , remoteNodeTrustLines
    ) where

import Data.Text (Text)

data FlakeKeyStatus
    = FlakeKeyPresent
    | FlakeKeyMissing
    | FlakeKeyUnknown Text

remoteBuildWorkaround :: Text
remoteBuildWorkaround =
    "Alternatively, run `nix run .#hostenv-provider -- deploy --remote-build` to build on the remote nodes."

commonPlanRefreshLines :: [Text]
commonPlanRefreshLines =
    [ "Run `nix run .#hostenv-provider -- plan`."
    ]

keyLine :: Text -> Text
keyLine key = "  nixSigning.trustedPublicKeys = [ \"" <> key <> "\" ];"

localTrustSetupLines :: FlakeKeyStatus -> Text -> [Text]
localTrustSetupLines flakeKeyStatus key =
    case flakeKeyStatus of
        FlakeKeyPresent ->
            [ remoteBuildWorkaround
            , "The local signing key is already in `flake.nix`, but `generated/plan.json` is out of date."
            ]
                ++ commonPlanRefreshLines
                ++
                [ "Run `deploy` again after regenerating the plan."
                ]
        FlakeKeyMissing ->
            [ remoteBuildWorkaround
            , "Provider nodes must trust this machine's signing key before they can accept locally built packages."
            , "Add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "Run `deploy` again after regenerating the plan."
                ]
        FlakeKeyUnknown err ->
            [ remoteBuildWorkaround
            , "Could not check whether `flake.nix` already contains this key: " <> err
            , "If needed, add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "Run `deploy` again after regenerating the plan."
                ]

remoteNodeTrustLines :: FlakeKeyStatus -> Text -> [Text]
remoteNodeTrustLines flakeKeyStatus key =
    case flakeKeyStatus of
        FlakeKeyPresent ->
            [ remoteBuildWorkaround
            , "The key is configured in `flake.nix`, but this node may not have applied the latest NixOS configuration."
            , "Apply the updated NixOS configuration on the node, then run `deploy` again."
            ]
        FlakeKeyMissing ->
            [ remoteBuildWorkaround
            , "This node cannot trust local builds until the signing key is configured."
            , "Add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "Apply the updated NixOS configuration on the node, then run `deploy` again."
                ]
        FlakeKeyUnknown err ->
            [ remoteBuildWorkaround
            , "Could not check whether `flake.nix` already contains this key: " <> err
            , "If needed, add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "Apply the updated NixOS configuration on the node, then run `deploy` again."
                ]
