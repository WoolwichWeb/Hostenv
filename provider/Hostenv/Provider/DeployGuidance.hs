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
    "workaround: rerun this deployment with `nix run .#hostenv-provider -- deploy --remote-build`."

commonPlanRefreshLines :: [Text]
commonPlanRefreshLines =
    [ "run `nix run .#hostenv-provider -- plan`."
    ]

keyLine :: Text -> Text
keyLine key = "  nixSigning.trustedPublicKeys = [ \"" <> key <> "\" ];"

localTrustSetupLines :: FlakeKeyStatus -> Text -> [Text]
localTrustSetupLines flakeKeyStatus key =
    case flakeKeyStatus of
        FlakeKeyPresent ->
            [ remoteBuildWorkaround
            , "local signing key is already present in `flake.nix`, but `generated/plan.json` is stale."
            ]
                ++ commonPlanRefreshLines
                ++
                [ "retry `deploy` after regenerating plan artifacts."
                ]
        FlakeKeyMissing ->
            [ remoteBuildWorkaround
            , "nix needs a trusted signing key before nodes accept packages built on this machine."
            , "add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "retry `deploy` after regenerating plan artifacts."
                ]
        FlakeKeyUnknown err ->
            [ remoteBuildWorkaround
            , "could not confirm whether `flake.nix` already includes this key: " <> err
            , "if needed, add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "retry `deploy` after regenerating plan artifacts."
                ]

remoteNodeTrustLines :: FlakeKeyStatus -> Text -> [Text]
remoteNodeTrustLines flakeKeyStatus key =
    case flakeKeyStatus of
        FlakeKeyPresent ->
            [ remoteBuildWorkaround
            , "the key appears configured in `flake.nix`; this node likely has not applied the latest NixOS config yet."
            , "apply the updated NixOS configuration on the node, then retry deploy."
            ]
        FlakeKeyMissing ->
            [ remoteBuildWorkaround
            , "this node cannot trust local builds until the signing key is configured."
            , "add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "apply the updated NixOS configuration on the node, then retry deploy."
                ]
        FlakeKeyUnknown err ->
            [ remoteBuildWorkaround
            , "could not confirm whether `flake.nix` already includes this key: " <> err
            , "if needed, add this line under `provider = { ... };` in `flake.nix`:"
            , keyLine key
            ]
                ++ commonPlanRefreshLines
                ++
                [ "apply the updated NixOS configuration on the node, then retry deploy."
                ]
