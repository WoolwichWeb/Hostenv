{ pkgs, inputs }:
let
  lib = pkgs.lib;
  asserts = import ../support/assert.nix { inherit pkgs lib; };

  expectedPlan = pkgs.writeText "provider-tooling-plan.json" "{}";
  expectedState = pkgs.writeText "provider-tooling-state.json" "{}";
  expectedFlake = pkgs.writeText "provider-tooling-flake.nix" "{}";

  toolingModule = import ../../modules/entrypoints/provider/tooling.nix {
    inherit inputs lib;
    config = {
      provider = {
        enable = true;
        secretsFile = "secrets/secrets.yaml";
      };
      flake.lib = {
        provider.plan =
          args:
          assert
            args.sopsSecretKeys == {
              "provider-test" = [ "backups_secret" ];
            };
          {
            plan = expectedPlan;
            state = expectedState;
            flake = expectedFlake;
          };
        hostenvInputs.requireInput = _: {
          outPath = ../..;
        };
        hostenv.readYaml = _pkgs: _path: {
          "provider-test" = {
            backups_secret = "";
          };
        };
      };
    };
  };

  perSystem = toolingModule.config.content.perSystem {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    config = {
      provider.haskellDevPackages = [ ];
      documentation.haskell = {
        dependencies.enable = false;
        haddock.enable = false;
      };
    };
  };

  unwrapDefault = value:
    if builtins.isAttrs value && value ? _type && value._type == "override" then
      value.content
    else
      value;

  providerPackage = perSystem.packages.hostenv-provider;
  defaultPackage = unwrapDefault perSystem.packages.default;
  providerApp = perSystem.apps.hostenv-provider;
  defaultApp = unwrapDefault perSystem.apps.default;

  # Package and dev-shell values are lazy. Force their derivations here so
  # invalid package paths and other evaluation errors cannot remain hidden
  # until a downstream provider evaluates its dev shell.
  toolingDerivations =
    [
      providerPackage
      defaultPackage
    ]
    ++ builtins.attrValues perSystem.provider.planPaths
    ++ perSystem.devshells.default.devshell.packages;
  toolingDerivationsEvaluate = lib.all (
    drv: lib.isDerivation drv && builtins.seq drv.drvPath true
  ) toolingDerivations;
in
asserts.assertTrue "provider-tooling-plan-paths-eval" (
  perSystem.provider.planPaths.plan == expectedPlan
  && defaultPackage.outPath == providerPackage.outPath
  && defaultApp.program == providerApp.program
  && toolingDerivationsEvaluate
) "provider tooling should fully evaluate its packages, dev-shell dependencies, plan paths, and default CLI"
