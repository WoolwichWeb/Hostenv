{
  inputs,
  lib,
  config,
  ...
}:
let
  fp = inputs.flake-parts.lib;
  types = lib.types;
  cfg = config.project;
  cfgTop = config;
in
{
  options.project.enable = lib.mkEnableOption "Enable project outputs and hostenv project evaluation.";

  options.perSystem = fp.mkPerSystemOption (
    { system, ... }: {
      options.hostenvProject = {
        makeHostenv = lib.mkOption {
          type = types.functionTo (types.functionTo types.unspecified);
          # Include Hostenv modules defined by the consuming project.
          default = cfgTop.flake.lib.hostenv.makeHostenv.${system};
        };

        modules = lib.mkOption {
          type = types.listOf types.deferredModule;
          default = [ ];
        };

        environmentName = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
        };

        eval = lib.mkOption {
          type = types.unspecified;
          readOnly = true;
          internal = true;
          description = "Internal: selected full evalModules result, or null when no environment is selected.";
        };

        outputs = lib.mkOption {
          type = types.unspecified;
          readOnly = true;
          description = "Export-ready hostenv discovery outputs.";
        };
      };
    }
  );

  config.perSystem =
    {
      system,
      config,
      pkgs,
      ...
    }:
    lib.mkIf cfg.enable (
      let
        makeHostenv = config.hostenvProject.makeHostenv;
        discoverProject = cfgTop.flake.lib.hostenv.discoverProject.${system};
        baseModules = config.hostenvProject.modules;
        project = discoverProject baseModules;
        environmentNames = builtins.attrNames project.environments;
        selectedEnvironmentName =
          if config.hostenvProject.environmentName != null then
            config.hostenvProject.environmentName
          else
            project.defaultEnvironment;

        # Disabled environments must remain visible for retirement.
        metadataEnvironmentName =
          if selectedEnvironmentName != null && builtins.hasAttr selectedEnvironmentName project.environments then
            selectedEnvironmentName
          else if environmentNames != [ ] then
            builtins.head environmentNames
          else
            null;
        metadataEval =
          if metadataEnvironmentName == null then null else makeHostenv baseModules metadataEnvironmentName;

        envs = if metadataEval == null then { } else metadataEval.config.environments;
        enabledEnvs = pkgs.lib.filterAttrs (_: environment: environment.enable) envs;

        envPackages = pkgs.lib.mapAttrs (
          environmentName: _environment: (makeHostenv baseModules environmentName).config.activatePackage
        ) enabledEnvs;

        selectedEval =
          if selectedEnvironmentName == null then
            null
          else if selectedEnvironmentName == metadataEnvironmentName then
            metadataEval
          else
            makeHostenv baseModules selectedEnvironmentName;

        projectApps = if selectedEval == null then { } else selectedEval.config.hostenv.apps;

        outputs = {
          environments = envs;
          inherit (project) defaultEnvironment;
        };
      in
      {
        hostenvProject.eval = selectedEval;
        hostenvProject.outputs = outputs;

        packages = envPackages // lib.optionalAttrs (selectedEval != null) {
          default = selectedEval.config.activatePackage;
        };
        apps = projectApps // lib.optionalAttrs (projectApps ? hostenv && !(projectApps ? default)) {
          default = lib.mkDefault projectApps.hostenv;
        };
        devshells = if selectedEval == null then { } else selectedEval.config.hostenv.devShells;
      }
    );

  config.flake.lib.hostenv = lib.mkIf cfg.enable (
    lib.genAttrs config.systems (system: config.allSystems.${system}.hostenvProject.outputs)
  );
}
