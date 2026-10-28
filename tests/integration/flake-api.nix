{ pkgs, inputs }:
let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;

  downstreamInputs = {
    self = inputs.self;
    hostenv = inputs.self;
    inherit (inputs) nixpkgs flake-parts;
  };
  projectModules = [ {
    hostenv = {
      organisation = "test";
      project = "flake-api";
      hostenvHostname = "hosting.test";
      root = ./fixtures/flake-api;
    };
    environments.main = { enable = true; type = "production"; };
  } ];
  evaluation = inputs.flake-parts.lib.evalFlakeModule {
    inputs = downstreamInputs;
  } {
    imports = [
      inputs.self.flakeModules.project
      ./fixtures/flake-api/aspect.nix
    ];
    systems = [ system ];
    flake.modules.hostenv.api-fixture.apiFixture = [ "second" ];
    perSystem.hostenvProject.modules = projectModules;
  };
  outputs = evaluation.config.processedFlake;
  environment = evaluation.config.allSystems.${system}.hostenvProject.eval;
  fromExport = outputs.lib.hostenv.makeHostenv.${system} projectModules "main";
  exportedHostenv = lib.evalModules {
    class = "hostenv";
    modules = [ outputs.lib.hostenv.modules.api-fixture ];
  };
  exportedNixos = lib.evalModules {
    class = "nixos";
    modules = [ outputs.nixosModules.api-fixture ];
  };
  wrongClass = builtins.tryEval ((lib.evalModules {
    class = "nixos";
    modules = [ outputs.lib.hostenv.modules.api-fixture ];
  }).config.apiFixture);

  packages = inputs.self.lib.hostenv.packagesFor pkgs;
  providerOverrideSource = builtins.path {
    path = ../../packages/hostenv-provider;
    name = "hostenv-provider-override-source";
  };
  overriddenProvider = packages.hostenv-provider.override {
    sourceRoot = providerOverrideSource;
  };
  overriddenService = packages.hostenv-provider-service.override {
    sourceRoot = ./fixtures/flake-api;
    haskellDeps = [ ];
    dependencyDocumentationEnabled = false;
  };
  serviceEnvironment = outputs.lib.hostenv.makeHostenv.${system} (projectModules ++ [ {
    services.hostenv-provider = {
      enable = true;
      source = ./fixtures/flake-api;
      haskellDeps = [ ];
    };
  } ]) "main";
  moduleService = serviceEnvironment.config.services.hostenv-provider.package;
  names = [ "hostenv-provider" "hostenv-provider-service" "hostenv-runtime" ];
  packageOutputsEvaluate = lib.all (name:
    lib.isDerivation inputs.self.packages.${system}.${name}
    && builtins.seq inputs.self.packages.${system}.${name}.drvPath true
  ) names;
  assertions = [
    { assertion = !(inputs.self ? modules) && !(inputs.self ? makeHostenv);
      message = "Hostenv must not expose the obsolete top-level outputs."; }
    { assertion = !(outputs ? modules) && !(outputs ? makeHostenv);
      message = "Downstream project outputs must also hide the internal registry."; }
    { assertion = inputs.self ? nixosModules && inputs.self.lib.hostenv ? modules;
      message = "Both public module classes must remain available."; }
    { assertion = lib.sort builtins.lessThan environment.config.apiFixture == [ "first" "second" ];
      message = "The default project evaluator must use locally composed modules."; }
    { assertion = lib.sort builtins.lessThan fromExport.config.apiFixture == [ "first" "second" ];
      message = "The public evaluator must retain downstream module contributions."; }
    { assertion = lib.sort builtins.lessThan exportedHostenv.config.apiFixture == [ "first" "second" ];
      message = "Exporting a Hostenv module must preserve merged definitions."; }
    { assertion = exportedNixos.config.apiFixture == [ "nixos" ] && !wrongClass.success;
      message = "Module exports must retain their class checks."; }
    { assertion = outputs.lib.hostenv.${system}.defaultEnvironment == "main"
        && outputs.lib.hostenv.${system}.environments.main.enable;
      message = "Project environment metadata must retain its existing public shape."; }
    { assertion = packageOutputsEvaluate;
      message = "All standalone software outputs must remain buildable derivations."; }
    { assertion = packages.hostenv-provider.src == ../../packages/hostenv-provider
        && overriddenProvider.src == providerOverrideSource
        && overriddenService.src == ./fixtures/flake-api
        && overriddenService.haskellDeps == [ ]
        && moduleService.src == ./fixtures/flake-api
        && moduleService.haskellDeps == [ ];
      message = "Default sources must not resolve to pkgs.src; explicit source and dependency overrides must still work."; }
  ];
  failures = map (item: item.message) (builtins.filter (item: !item.assertion) assertions);
in
assert lib.assertMsg (failures == [ ]) (lib.concatStringsSep "\n" failures);
pkgs.runCommand "hostenv-flake-api" { } ''
  set -euo pipefail
  ${overriddenService}/bin/hostenv-provider-service > actual
  grep -Fx 'Hostenv package override fixture' actual
  touch "$out"
''
