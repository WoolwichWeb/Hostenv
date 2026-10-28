{ pkgs, inputs }:
let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;
  asserts = import ../support/assert.nix { inherit pkgs lib; };
  expectedPlan = pkgs.writeText "provider-tooling-plan.json" "{}";
  expectedState = pkgs.writeText "provider-tooling-state.json" "{}";
  expectedFlake = pkgs.writeText "provider-tooling-flake.nix" "{}";

  evaluation = inputs.flake-parts.lib.evalFlakeModule {
    inputs = inputs // { hostenv = inputs.self; };
  } {
    imports = [ inputs.self.flakeModules.provider ];
    systems = [ system ];
    provider = {
      hostenvHostname = "hosting.test";
      secretsFile = "secrets/secrets.yaml";
    };

    flake.lib.provider = lib.mkForce (inputs.self.lib.provider // {
      plan = args:
        assert args.sopsSecretKeys == { "provider-test" = [ "backups_secret" ]; };
        {
          plan = expectedPlan;
          state = expectedState;
          flake = expectedFlake;
        };
    });
    flake.lib.hostenv = lib.mkForce (inputs.self.lib.hostenv // {
      readYaml = _pkgs: _path: {
        "provider-test" = { backups_secret = ""; };
      };
    });
    perSystem = {
      provider.haskellDevPackages = lib.mkForce [ ];
      documentation.haskell = {
        dependencies.enable = false;
        haddock.enable = false;
      };
    };
  };
  perSystem = evaluation.config.allSystems.${system};
  providerPackage = perSystem.packages.hostenv-provider;
  defaultPackage = perSystem.packages.default;
  providerApp = perSystem.apps.hostenv-provider;
  defaultApp = perSystem.apps.default;
  toolingDerivations = [
    providerPackage
    defaultPackage
  ] ++ builtins.attrValues perSystem.provider.planPaths
    ++ perSystem.devshells.default.devshell.packages;
  toolingDerivationsEvaluate = lib.all
    (drv: lib.isDerivation drv && builtins.seq drv.drvPath true)
    toolingDerivations;
in
asserts.assertTrue "provider-tooling-plan-paths-eval" (
  perSystem.provider.planPaths.plan == expectedPlan
  && defaultPackage.outPath == providerPackage.outPath
  && defaultApp.program == providerApp.program
  && toolingDerivationsEvaluate
) "provider tooling should fully evaluate its packages, dev-shell dependencies, plan paths, and default CLI"
