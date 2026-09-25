{
  inputs,
  lib,
  config,
  ...
}:
let
  flakeParts = inputs.flake-parts.lib;
  cfg = config.provider;
  providerPlan = config.flake.lib.provider.plan;
  hostenvInputs = config.flake.lib.hostenvInputs;
  readYaml = config.flake.lib.hostenv.readYaml;
  hostenvInput = hostenvInputs.requireInput {
    inherit inputs;
    name = "hostenv";
    context = "provider tooling";
  };
  providerRoot = hostenvInput.outPath + "/provider";
in
{
  options.perSystem = flakeParts.mkPerSystemOption (
    { lib, ... }: {
      options.provider.haskellDevPackages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "aeson"
          "aeson-pretty"
          "containers"
          "text"
          "text-conversions"
          "bytestring"
          "optparse-applicative"
          "turtle"
        ];
        description = "Haskell package names to include in the dev shell for provider tooling.";
      };

      options.provider.planPaths = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = "Generated plan/state/flake store paths for provider tooling.";
      };
    }
  );

  config = lib.mkIf cfg.enable {
    perSystem =
      {
        system,
        pkgs,
        config,
        ...
      }:
      let
        providerHsDeps = p: map (name: p.${name}) config.provider.haskellDevPackages;
        providerGhc =
          (pkgs.haskellPackages.ghcWithPackages.override {
            installDocumentation = config.documentation.haskell.dependencies.enable;
          })
            providerHsDeps;
        providerCliPackage = pkgs.callPackage (providerRoot + /package.nix) {
          providerSrc = providerRoot;
          documentationEnabled = config.documentation.haskell.haddock.enable;
        };
        hostenvProviderCLI = providerCliPackage.wrapped;
        hostenvProviderApp = {
          type = "app";
          program = "${hostenvProviderCLI}/bin/hostenv-provider";
          meta.description = "Hostenv provider CLI";
        };

        # Extract secret names while generating the plan so node configuration
        # can resolve per-secret scope fallbacks without parsing YAML itself.
        sopsSecretKeys =
          let
            secretsPath = inputs.self + "/${cfg.secretsFile}";
            sopsKeys = readYaml pkgs secretsPath;
          in
          pkgs.lib.mapAttrs (
            _: secrets: if builtins.isAttrs secrets then builtins.attrNames secrets else [ ]
          ) sopsKeys;

        providerGenerator = providerPlan {
          inputs = inputs // { hostenv = hostenvInput; };
          lib = pkgs.lib;
          inherit pkgs system sopsSecretKeys;
          inherit (cfg)
            letsEncrypt deployPublicKeys deployUser nixSigning hostenvHostname
            nodeFor nodeSystems nodeStatus nodeAddresses nodeSshPorts nodeSshOpts
            nodeRemoteBuild nodeMagicRollback nodeAutoRollback nodeModules
            secretsFile cloudflare generatedFlake deploy serviceResolution cache;
        };
      in
      {
        packages.hostenv-provider = hostenvProviderCLI;
        packages.default = lib.mkDefault hostenvProviderCLI;
        apps.hostenv-provider = hostenvProviderApp;
        apps.default = lib.mkDefault hostenvProviderApp;

        provider.planPaths = {
          inherit (providerGenerator) plan state flake;
        };

        # Add to dev packages for hostenv developers.
        hostenv.haskell.devPackages = lib.mkDefault (
          [ "haskell-language-server" ] ++ config.provider.haskellDevPackages
        );

        devshells.default = {
          devshell.packages = [
            hostenvProviderCLI
            providerGhc
            pkgs.sops
            pkgs.age
            pkgs.jq
            pkgs.bind
            pkgs.deploy-rs
            pkgs.postgresql
            pkgs.haskellPackages.cabal-install
          ];
          env = [
            {
              name = "DEVSHELL_NO_MOTD";
              value = 1;
            }
          ];
        };
      };

    flake.lib.provider.planPaths = lib.genAttrs config.systems (
      system: config.allSystems.${system}.provider.planPaths
    );
  };
}
