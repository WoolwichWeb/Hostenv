{ inputs, lib, config, ... }:
let
  inherit (lib) mkOption types;
  providerNixosModules = [
    config.flake.modules.nixos.provider-common
    config.flake.modules.nixos.hostenv-top-level
    config.flake.modules.nixos.nginx-tuning
    config.flake.modules.nixos.monitoring
  ];
  libHostenv = config.flake.lib.hostenv;
  providerServiceDeprecationNote =
    " Temporary compatibility option while deploy-rs provider tooling remains in use; will be deprecated once provider-service is complete.";

  providerNixosSystem =
    { config
    , nixpkgs
    , pkgs
    , node
    , inputs
    , nodesPath
    , secretsFile
    , secretsPath
    , sopsSecretKeys
    , nodeModules ? [ ]
    , nodeSystems ? { }
    , ...
    }:
    let
      plan = config;
      nodesBase =
        if builtins.isPath nodesPath
        then nodesPath
        else builtins.path { path = nodesPath; name = "nodes"; };
      nodePath =
        if builtins.typeOf node == "path"
        then node
        else (nodesBase + "/${node}");

      system =
        if builtins.hasAttr node nodeSystems then nodeSystems.${node}
        else builtins.throw "No system specified for node '${node}' (set provider.nodeSystems.${node})";

      nodeConfig = plan.nodes.${node};
      envsAll = plan.environments or { };
      envsForNode = lib.filterAttrs (_: env: (env.node or null) == node) envsAll;
      environmentWith = userName: envsForNode.${userName};
      packages = pkgs.${system};
      envUsers = builtins.attrNames envsForNode;

      providerPlanModule = {
        provider.plan = {
          environments = envsForNode;
          defaultEnvironment = plan.defaultEnvironment or null;
        };
      };

      userPackages = userInfo:
        let
          envOnly = packages.lib.filterAttrs (name: _: builtins.elem name envUsers) userInfo.users.users;
        in
        {
          users.users = packages.lib.concatMapAttrs
            (name: _user:
              let
                userPackage = inputs.${name}.packages.${system}.${(environmentWith name).hostenv.environmentName};
              in
              { ${name}.packages = [ userPackage ]; }
            )
            envOnly;
        };

      envUserMismatch =
        let
          envs = envsForNode;
          mismatched =
            packages.lib.filterAttrs
              (name: env: (env.hostenv.userName or name) != name)
              envs;
        in
        builtins.attrNames mismatched;

      sopsSecrets = userInfo:
        let
          orgFromName = name: (environmentWith name).hostenv.organisation;
          orgProjectFromName = name:
            (environmentWith name).hostenv.organisation
            + "_" + (environmentWith name).hostenv.project;
          envOnly = packages.lib.filterAttrs (name: _: builtins.elem name envUsers) userInfo.users.users;
          requiredSecretNamesFor = name:
            lib.unique ((environmentWith name).requiredSecretFiles or [ ]);
          secretNamesFor = name:
            lib.unique (
              [ "backups_secret" "backups_env" ]
              ++ (requiredSecretNamesFor name)
            );
          secretRestartServiceName = name: "hostenv-required-secrets-${name}";
          resolveSecretKey = name: secretName:
            let
              scopes = [ name (orgProjectFromName name) (orgFromName name) ];
              matchingScopes = builtins.filter
                (scope:
                  builtins.hasAttr scope sopsSecretKeys
                  && builtins.elem secretName sopsSecretKeys.${scope}
                )
                scopes;
            in
            if matchingScopes != [ ] then
              "${builtins.head matchingScopes}/${secretName}"
            else
              throw ''
                The secrets file does not contain '${secretName}' for '${name}'.

                From the hosting root directory, run `sops edit ${secretsFile}`
                and add the key at one of these locations:

                - '${name}/${secretName}' (this environment)
                - '${orgProjectFromName name}/${secretName}' (this project)
                - '${orgFromName name}/${secretName}' (this organisation).
              '';
        in
        {
          sops.secrets = lib.concatMapAttrs
            (
              name: _user:
                builtins.listToAttrs (map
                  (secretName: {
                    name = "${name}/${secretName}";
                    value = {
                      owner = name;
                      group = name;
                      key = resolveSecretKey name secretName;
                      restartUnits = lib.optional
                        (builtins.elem secretName (requiredSecretNamesFor name))
                        "${secretRestartServiceName name}.service";
                    };
                  })
                  (secretNamesFor name))
            )
            envOnly;

          # sops-nix can restart only system services directly, while Hostenv
          # application services run in the environment user's systemd
          # manager.
          # Find any active user services that load any provider-managed
          # runtime secret and restarting those services through the
          # user's manager.
          systemd.services = lib.concatMapAttrs
            (
              name: user:
                lib.optionalAttrs (requiredSecretNamesFor name != [ ]) {
                  ${secretRestartServiceName name} = {
                    description = "Restart ${name} services after runtime secrets change";
                    wantedBy = [ "multi-user.target" ];
                    wants = [ "user@${toString user.uid}.service" ];
                    after = [ "user@${toString user.uid}.service" ];
                    environment = {
                      XDG_RUNTIME_DIR = "/run/user/${toString user.uid}";
                      DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${toString user.uid}/bus";
                    };
                    serviceConfig = {
                      Type = "oneshot";
                      User = name;
                      RemainAfterExit = true;
                    };
                    script = ''
                      secret_root=${lib.escapeShellArg "/run/secrets/${name}/"}
                      units=()

                      while read -r unit _; do
                        if [ -z "$unit" ]; then
                          continue
                        fi

                        service_type="$(${packages.systemd}/bin/systemctl --user show \
                          --property=Type --value "$unit")"
                        if [ "$service_type" = oneshot ]; then
                          continue
                        fi

                        environment_files="$(${packages.systemd}/bin/systemctl --user show \
                          --property=EnvironmentFiles --value "$unit")"
                        if printf '%s\n' "$environment_files" \
                          | ${packages.gnugrep}/bin/grep -Fq "$secret_root"; then
                          units+=("$unit")
                        fi
                      done < <(${packages.systemd}/bin/systemctl --user list-units \
                        --type=service --state=active --no-legend --plain --no-pager)

                      if [ "''${#units[@]}" -gt 0 ]; then
                        ${packages.systemd}/bin/systemctl --user restart -- "''${units[@]}"
                      fi
                    '';
                  };
                }
            )
            envOnly;
        };

    in
    if envUserMismatch == [ ] then
      nixpkgs.lib.nixosSystem
        {
          inherit system;
          specialArgs = { inherit inputs system; };
          modules =
            [
              {
                _module.args = {
                  inherit inputs system;
                };
              }
              inputs.sops-nix.nixosModules.sops
              { sops.defaultSopsFile = secretsPath; }
            ]
            ++ providerNixosModules
            ++ [
              providerPlanModule
            ]
            ++ nodeModules
            ++ [
              (nodePath + "/configuration.nix")
              nodeConfig
              (sopsSecrets nodeConfig)
              (userPackages nodeConfig)
            ];
        }
    else
      throw "hostenv provider: environment keys must match hostenv.userName (mismatched: ${toString envUserMismatch})";

  providerDeployOutputs =
    { inputs
    , config
    , nixpkgs
    , deploy-rs
    , systems
    , localSystem
    , nodesPath
    , secretsFile
    , secretsPath
    , sopsSecretKeys
    , nodeModules ? [ ]
    , nodeSystems ? { }
    , nodeAddresses ? { }
    , nodeSshPorts ? { }
    , nodeSshOpts ? { }
    , nodeRemoteBuild ? { }
    , nodeMagicRollback ? { }
    , nodeAutoRollback ? { }
    }:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
      pkgs = forEachSystem (system: import nixpkgs { inherit system; });

      nixosSystem = node: providerNixosSystem {
        inherit config node nixpkgs pkgs inputs nodesPath secretsFile secretsPath sopsSecretKeys nodeSystems nodeModules;
      };

      nodes = builtins.mapAttrs
        (node: _: nixosSystem node)
        config.nodes;

      environments = forEachSystem (system: builtins.mapAttrs
        (name: environment: pkgs.${system}.buildEnv {
          inherit name;
          paths = [ inputs.${name}.packages.${system}.${environment.hostenv.environmentName} ];
        })
        config.environments
      );

      environmentsWith = node: forEachSystem (system: (
        nixpkgs.lib.filterAttrs
          (name: environment: node == config.environments.${name}.node)
          environments.${system}
      ));
    in
    {
      inherit inputs config environmentsWith;

      packages = forEachSystem (system:
        let
          nodeSystemOf = sys: sys.pkgs.stdenv.hostPlatform.system;

          envPkgs = nixpkgs.lib.mapAttrs'
            (name: drv: { name = "env-${name}"; value = drv; })
            environments.${system};

          nodePkgs = nixpkgs.lib.mapAttrs'
            (node: sys: {
              name = "node-${node}";
              value = sys.config.system.build.toplevel;
            })
            (nixpkgs.lib.filterAttrs
              (_: sys: nodeSystemOf sys == system)
              nodes);
        in
        envPkgs // nodePkgs
      );

      deploy.nodes = builtins.mapAttrs
        (node: _: {
          # Allow local demos and non-standard network topologies to override
          # default `<node>.<hostenvHostname>` SSH addressing.
          hostname =
            if builtins.hasAttr node nodeAddresses
            then nodeAddresses.${node}
            else node + "." + config.hostenvHostname;
          # Keep port override and raw ssh options separate so callers can use
          # either `nodeSshPorts` or `nodeSshOpts` without duplicating flags.
          sshOpts =
            let
              portOpts =
                if builtins.hasAttr node nodeSshPorts
                then [ "-p" (toString nodeSshPorts.${node}) ]
                else [ ];
              extraOpts =
                if builtins.hasAttr node nodeSshOpts
                then nodeSshOpts.${node}
                else [ ];
            in
            portOpts ++ extraOpts;
          fastConnection = true;
          remoteBuild =
            if builtins.hasAttr node nodeRemoteBuild
            then nodeRemoteBuild.${node}
            else false;
          magicRollback =
            if builtins.hasAttr node nodeMagicRollback
            then nodeMagicRollback.${node}
            else true;
          autoRollback =
            if builtins.hasAttr node nodeAutoRollback
            then nodeAutoRollback.${node}
            else true;
          profilesOrder = [ "system" ] ++ builtins.attrNames (environmentsWith node).${localSystem};
          profiles =
            let
              remoteSystem = nodes.${node}.pkgs.stdenv.hostPlatform.system;
            in
            {
              system = {
                sshUser = config.deployUser or "deploy";
                user = "root";
                path = deploy-rs.lib.${remoteSystem}.activate.nixos nodes.${node};
              };
            } // builtins.mapAttrs
              (name: environment: {
                sshUser = config.deployUser or "deploy";
                user = name;
                path = deploy-rs.lib.${remoteSystem}.activate.custom
                  environment
                  ''
                    # Setup paths for systemd, so 'systemctl --user' works
                    # as expected.
                    export XDG_RUNTIME_DIR="/run/user/$UID"
                    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
                    exec ./bin/activate
                  '';
              })
              (environmentsWith node).${remoteSystem};
          checks = { };
        })
        config.nodes;

      nixosConfigurations = nodes;
    };
in
{
  # By necessity a lot of these options are duplicated here and in
  # modules/nixos/provider-common.nix
  # This is due to the evaluation boundary between the outer flake, plan.json,
  # and the generated/ flake.
  # @todo: find a clean way to obviate this code duplication.
  options.provider = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable provider outputs and tooling.";
    };

    hostenvHostname = mkOption {
      type = types.str;
      default = "example.invalid";
      description = "Hostenv control-plane hostname (must be set by provider).";
    };

    deployUser = mkOption {
      type = types.str;
      default = "deploy";
      description = "SSH/sudo user used for deploy-rs operations.";
    };

    letsEncrypt = mkOption {
      type = types.attrs;
      default = { adminEmail = "admin@example.invalid"; acceptTerms = true; };
    };

    deployPublicKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "SSH public keys for deploy user;
      must be set by provider.";
    };

    nixSigning = mkOption {
      type = types.submodule {
        options = {
          trustedPublicKeys = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Public Nix signing keys trusted by provider nodes for deploy-rs copy checks.";
          };
        };
      };
      default = { };
      description = "Nix signing key configuration shared by generated plan and node configuration.";
    };

    deploy = mkOption {
      type = types.submodule {
        options = {
          enable = lib.mkEnableOption "reserved provider-deploy node agent wiring";
          providerApiBaseUrl = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Reserved base URL for provider deploy APIs used by node workers.";
          };
          nodeAuthTokenFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Reserved default path for node bearer token used in provider-deploy requests.";
          };
          nodeAuthTokenFiles = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = "Reserved map of node name -> provider-deploy bearer token file path.";
          };
          reconnectSeconds = mkOption {
            type = types.int;
            default = 5;
            description = "Reserved provider-deploy reconnect delay in seconds.";
          };
        };
      };
      default = { };
      description = "Reserved provider-deploy settings. These are rejected until provider-service node agent wiring lands.";
    };

    serviceResolution = libHostenv.mkServiceResolutionOption { inherit lib; };

    cache = mkOption {
      type = types.submodule {
        options = {
          enable = lib.mkEnableOption "reserved provider-service cache server secret wiring";
        };
      };
      default = { };
      description = "Reserved provider-service cache secret projection. This is rejected until provider-service cache wiring lands.";
    };

    nodeFor = mkOption {
      type = types.attrs;
      default = { default = null; };
    };

    nodeSystems = mkOption {
      type = types.attrs;
      default = { };
      description = "Map of node name -> system string (e.g. x86_64-linux, aarch64-linux).";
    };

    nodeAddresses = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Optional map of node name -> SSH hostname/IP override for deploy-rs." + providerServiceDeprecationNote;
    };

    nodeSshPorts = mkOption {
      type = types.attrsOf types.int;
      default = { };
      description = "Optional map of node name -> SSH port override for deploy-rs." + providerServiceDeprecationNote;
    };

    nodeSshOpts = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      description = "Optional map of node name -> extra SSH options for deploy-rs." + providerServiceDeprecationNote;
    };

    nodeRemoteBuild = mkOption {
      type = types.attrsOf types.bool;
      default = { };
      description = "Optional map of node name -> whether deploy-rs should build on the remote host." + providerServiceDeprecationNote;
    };

    nodeMagicRollback = mkOption {
      type = types.attrsOf types.bool;
      default = { };
      description = "Optional map of node name -> deploy-rs magicRollback override." + providerServiceDeprecationNote;
    };

    nodeAutoRollback = mkOption {
      type = types.attrsOf types.bool;
      default = { };
      description = "Optional map of node name -> deploy-rs autoRollback override." + providerServiceDeprecationNote;
    };

    nodeModules = mkOption {
      type = types.listOf (types.oneOf [ types.path types.str ]);
      default = [ ];
      description = "Extra NixOS modules applied to every node. Strings are paths relative to the provider root.";
    };

    secretsFile = mkOption {
      type = types.str;
      default = "secrets/secrets.yaml";
      description = "Path to the provider SOPS secrets file, relative to the provider repository root.";
    };

    generatedFlake = mkOption {
      type = types.submodule {
        options = {
          inputs = mkOption {
            type = types.attrsOf types.unspecified;
            default = { };
            description = "Extra inputs injected into generated/flake.nix (appended to allow overrides).";
          };
          envInputs = mkOption {
            type = types.submodule {
              options = {
                follows = mkOption {
                  type = types.nullOr (types.attrsOf types.str);
                  default = null;
                  description = "Override the inputs.<name>.follows mapping for every environment input (null = default mapping).";
                };
                extra = mkOption {
                  type = types.functionTo (types.attrsOf types.unspecified);
                  default = _: { };
                  description = "Function env -> attrs merged into each environment input spec.";
                };
              };
            };
            default = { };
          };
        };
      };
      default = { };
      description = "Customization for generated/flake.nix inputs and per-environment inputs.";
    };

    cloudflare = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = false; };
          zoneId = mkOption { type = types.nullOr types.str; default = null; };
          apiTokenFile = mkOption { type = types.nullOr types.path; default = null; };
        };
      };
      default = { enable = false; zoneId = null; apiTokenFile = null; };
    };
  };

  config.flake.lib.provider = {
    nixosModules = providerNixosModules;
    nixosSystem = providerNixosSystem;
    deployOutputs = providerDeployOutputs;
    deployPublicKeys = config.provider.deployPublicKeys;
    deployUser = config.provider.deployUser;
    nixSigning = config.provider.nixSigning;
  };
}
