{ config, ... }:
let
  hostenvInputs = config.flake.lib.hostenvInputs;
  # Provider-side infrastructure generator.
  providerPlan =
    {
      inputs,
      system,
      lib,
      pkgs,
      letsEncrypt,
      deployPublicKeys ? [ ],
      deployUser ? "deploy",
      nixSigning ? {
        trustedPublicKeys = [ ];
      },
      hostenvHostname,
      nodeFor ? {
        default = null;
      },
      nodeModules ? [ ],
      statePath ? (if inputs ? self then inputs.self + /generated/state.json else null),
      nodeSystems ? { },
      nodeStatus ? { },
      # Server address overrides, particularly for SSH bastions, private IPs, or management hosts.
      nodeAddresses ? { },
      nodeSshPorts ? { },
      nodeSshOpts ? { },
      nodeRemoteBuild ? { },
      nodeMagicRollback ? { },
      nodeAutoRollback ? { },
      cloudflare ? {
        enable = false;
        zoneId = null;
        apiTokenFile = null;
      },
      generatedFlake ? { },
      secretsFile,
      sopsSecretKeys ? { },
      lockPath ? (if inputs ? self then inputs.self + /flake.lock else ../../../flake.lock),
      # Reserved provider-service configuration. These are accepted only so
      # provider entrypoint callers can fail fast instead of silently dropping
      # settings before provider-service node wiring lands.
      # @todo: when the new provider-service is included, make these mandatory.
      deploy ? { },
      serviceResolution ? null,
      cache ? { },
    }:

    let
      hostenvInput = hostenvInputs.requireInput {
        inherit inputs;
        name = "hostenv";
        context = "provider plan";
      };
      hostenvMakeHostenv =
        hostenvInput.makeHostenv.${system}
          or (throw "provider plan: hostenv input missing makeHostenv.${system} output.");

      defaultEnvInputFollows = {
        hostenv = "hostenv";
        nixpkgs = "nixpkgs";
        flake-parts = "flake-parts";
        phps = "phps";
      };

      generatedFlakeInputs = generatedFlake.inputs or { };
      envInputsCfg = generatedFlake.envInputs or { };
      envInputFollows =
        if (envInputsCfg.follows or null) != null then envInputsCfg.follows else defaultEnvInputFollows;
      envInputExtra = envInputsCfg.extra or (_: { });

      nodeModulesRel =
        let
          basePath = if inputs ? self then toString inputs.self else null;
          normalize =
            module:
            if builtins.isString module then
              module
            else if builtins.isPath module then
              if basePath == null then
                throw "provider plan: nodeModules path values require inputs.self; use string paths relative to the provider root."
              else
                let
                  modulePath = toString module;
                in
                if lib.hasPrefix (basePath + "/") modulePath then
                  lib.removePrefix (basePath + "/") modulePath
                else
                  throw "provider plan: nodeModules path '${modulePath}' must be under provider root (${basePath})"
            else
              throw "provider plan: nodeModules entries must be strings or paths.";
        in
        map normalize nodeModules;

      # Detect project inputs once. The environment output is safe to access
      # directly after this filter; unrelated flake inputs are ignored.
      projectInputs = builtins.filter (
        name:
        let
          input = inputs.${name};
        in
        lib.hasInfix "__" name
        && input ? lib.hostenv.${system}.environments
        && builtins.pathExists (input + /hostenv.nix)
      ) (builtins.attrNames inputs);

      assertProjectInputs =
        if projectInputs == [ ] then
          throw ''
            provider plan: no client projects found.

            Each client flake must expose a `lib.hostenv.<system>.environments` output.
            Ensure inputs are named organisation__project, export `outputs.lib.hostenv`,
            and include `hostenv.nix` at the flake root (typically by using dir=.hostenv).
          ''
        else
          true;

      state =
        let
          rawState =
            if statePath == null || !(builtins.pathExists statePath) then { } else lib.importJSON statePath;
        in
        lib.mapAttrs (
          _: entry:
          if builtins.isAttrs entry then removeAttrs entry [ "node" ] else entry
        ) (removeAttrs rawState [ "_description" ]);

      lockData =
        if builtins.pathExists lockPath then
          lib.importJSON lockPath
        else
          throw ''
            flake.lock is missing at ${toString lockPath}.
            Please run: nix flake lock (or nix flake update) at repo root
          '';

      deployHasSettings =
        (deploy.enable or false)
        || (deploy.providerApiBaseUrl or null) != null
        || (deploy.nodeAuthTokenFile or null) != null
        || (deploy.nodeAuthTokenFiles or { }) != { }
        || (deploy.reconnectSeconds or 5) != 5
        ||
          (removeAttrs deploy [
            "enable"
            "providerApiBaseUrl"
            "nodeAuthTokenFile"
            "nodeAuthTokenFiles"
            "reconnectSeconds"
          ]) != { };

      cacheHasSettings = (cache.enable or false) || (removeAttrs cache [ "enable" ]) != { };

      assertUnsupportedProviderServiceOptions =
        if deployHasSettings then
          throw ''
            provider plan: provider.deploy is reserved for provider-service node agent wiring, but it is not wired into generated node configuration yet.

            Leave provider.deploy at its defaults until the provider-service node wiring PR lands.
          ''
        else if serviceResolution != null then
          throw ''
            provider plan: provider.serviceResolution is reserved for provider-service secret wiring, but it is not wired into generated node configuration yet.

            Leave provider.serviceResolution unset until the provider-service wiring PR lands.
          ''
        else if cacheHasSettings then
          throw ''
            provider plan: provider.cache is reserved for provider-service cache wiring, but outer provider.cache settings are not wired into generated node configuration yet.

            Leave provider.cache at its defaults until the provider-service cache wiring PR lands.
          ''
        else
          true;

      # Retired environments still reserve their UIDs. Keep the existing lower
      # bound and allocation order so this refactor does not renumber users.
      nextUid =
        1 + builtins.foldl' (highest: env: lib.max highest env.uid) 1001 (builtins.attrValues state);

      inputNameToProject =
        inputName:
        let
          parts = lib.filter (part: part != "") (lib.splitString "__" inputName);
        in
        if builtins.length parts != 2 then
          throw "provider plan: input '${inputName}' must be named organisation__project."
        else
          {
            organisation = builtins.elemAt parts 0;
            project = builtins.elemAt parts 1;
          };

      # Re-evaluate each enabled environment with the provider's identity and
      # hostname. Project outputs determine which environments exist.
      evaluatedEnvironments = builtins.concatMap (
        name:
        let
          repo =
            lockData.nodes.${name}.original or (throw ''
              Could not find ${name} in Flake inputs, do you need to run 'nix flake update ${name}'?
            '');
          orgAndProject = inputNameToProject name;
          enabledProjectEnvironments = lib.filterAttrs (
            _: env: env.enable
          ) inputs.${name}.lib.hostenv.${system}.environments;
        in
        lib.mapAttrsToList (
          envName: envCfg:
          let
            envRoot =
              envCfg.hostenv.root
                or (throw "provider plan: environment '${envName}' in ${name} is missing hostenv.root");
            evaluatedHostenv = hostenvMakeHostenv [
              (inputs.${name} + /hostenv.nix)
              ({ ... }: {
                hostenv.organisation = lib.mkForce orgAndProject.organisation;
                hostenv.project = lib.mkForce orgAndProject.project;
                hostenv.root = lib.mkForce envRoot;
                hostenv.hostenvHostname = lib.mkForce hostenvHostname;
              })
            ] envName;
            effectiveEnvCfg = evaluatedHostenv.config.environments.${envName} or envCfg;
            hostenv = effectiveEnvCfg.hostenv;
          in
          effectiveEnvCfg
          // {
            node = nodeFor.${effectiveEnvCfg.type} or nodeFor.default;
            authorizedKeys = builtins.concatMap (user: user.publicKeys or [ ]) (
              builtins.attrValues effectiveEnvCfg.users
            );
            migrations = builtins.filter (name: lib.hasSuffix "-migrate" name) (
              builtins.attrNames (evaluatedHostenv.config.services.restic.backups or { })
            );
            hostenv = hostenv // {
              inherit hostenvHostname;
              # Preserve the project's per-environment backup setting,
              # including an explicit null, rather than leaking a default
              # from the environment used to discover project metadata.
              backupsRepoHost = envCfg.hostenv.backupsRepoHost or (hostenv.backupsRepoHost or null);
            };
            repo = repo // {
              ref = hostenv.gitRef;
            };
          }
        ) enabledProjectEnvironments
      ) projectInputs;

      # One ownership check for both persisted reservations and current claims.
      # Identity and diagnostic labels are separate: the same user in state and
      # the new plan is one owner, not a hostname collision.
      validatedEnvironments =
        let
          stateClaims = builtins.concatMap (
            owner:
            map (name: {
              inherit name owner;
              label = "state:${owner}";
            }) (state.${owner}.virtualHosts or [ ])
          ) (builtins.attrNames state);
          newClaims = builtins.concatMap (
            env:
            map (name: {
              inherit name;
              owner = env.hostenv.userName;
              label = env.hostenv.userName;
            }) (builtins.attrNames env.virtualHosts)
          ) evaluatedEnvironments;
          claimsByHostname = builtins.groupBy (claim: claim.name) (stateClaims ++ newClaims);
          conflicts = lib.filterAttrs (
            _: claims: builtins.length (lib.unique (map (claim: claim.owner) claims)) > 1
          ) claimsByHostname;
          describeConflict =
            hostname: claims:
            "${hostname} claimed by ${lib.concatStringsSep "," (lib.unique (map (claim: claim.label) claims))}";
        in
        if conflicts != { } then
          throw "provider plan: duplicate virtualHosts detected: ${lib.concatStringsSep "; " (lib.mapAttrsToList describeConflict conflicts)}"
        else
          evaluatedEnvironments;

      nodeStatuses =
        lib.genAttrs (builtins.attrNames nodeSystems) (
          node: nodeStatus.${node} or "active"
        );

      assertNodeLifecycle =
        let
          unknownStatusNodes =
            lib.filter (node: !(builtins.hasAttr node nodeSystems)) (builtins.attrNames nodeStatus);

          nodeForTargets =
            lib.filter
              (node: builtins.isString node && node != "" && node != "default")
              (lib.unique (builtins.attrValues nodeFor));

          unknownNodeForTargets =
            lib.filter (node: !(builtins.hasAttr node nodeSystems)) nodeForTargets;

          retiringNodeForTargets =
            lib.filter
              (node: nodeStatuses.${node} == "retiring")
              nodeForTargets;
        in
        if unknownStatusNodes != [ ] then
          throw "provider plan: provider.nodeStatus contains nodes missing from provider.nodeSystems: ${lib.concatStringsSep ", " unknownStatusNodes}"
        else if unknownNodeForTargets != [ ] then
          throw "provider plan: provider.nodeFor selects nodes missing from provider.nodeSystems: ${lib.concatStringsSep ", " unknownNodeForTargets}"
        else if retiringNodeForTargets != [ ] then
          throw "provider plan: retiring nodes cannot be selected by provider.nodeFor: ${lib.concatStringsSep ", " retiringNodeForTargets}"
        else
          true;

      # Assign unique UIDs to new environments, reusing persisted state when present.
      environmentsWithUid = lib.imap0 (
        idx: env:
        let
          previous = state.${env.hostenv.userName} or { };
        in
        env
        // {
          uid = if (previous.uid or null) != null then previous.uid else nextUid + idx;
        }
      ) validatedEnvironments;

      nodeConnections =
        let
          namesFromEnvs = map (env: env.node) environmentsWithUid;
          knownNodes = lib.filter (name: builtins.isString name && name != "" && name != "default") (
            lib.unique (
              builtins.attrNames nodeSystems
              ++ builtins.attrNames nodeAddresses
              ++ builtins.attrNames nodeSshPorts
              ++ builtins.attrNames nodeSshOpts
              ++ namesFromEnvs
            )
          );
        in
        lib.genAttrs knownNodes (node: {
          # SSH routing only. DNS/HTTP verification must not use an override
          # that might name a bastion or private management address.
          hostname = nodeAddresses.${node} or "${node}.${hostenvHostname}";
          sshOpts =
            lib.optionals (nodeSshPorts ? ${node}) [
              "-p"
              (toString nodeSshPorts.${node})
            ]
            ++ (nodeSshOpts.${node} or [ ]);
        });

      generatedFlakeFile =
        let
          toNix = lib.generators.toPretty { };
          envInputSpec =
            val:
            let
              lockNode = lockData.nodes.${val.hostenv.userName} or null;
              lockedRev = if lockNode != null && lockNode ? locked then lockNode.locked.rev else null;
              lockedNarHash = if lockNode != null && lockNode ? locked then lockNode.locked.narHash else null;
              lockedRef =
                if lockNode != null && lockNode ? locked then lockNode.locked.ref or val.repo.ref else val.repo.ref;
              repoAttrs = {
                type = val.repo.type;
                dir = val.repo.dir or ".";
                ref = lockedRef;
              }
              // (lib.optionalAttrs (lockedRev != null) { rev = lockedRev; })
              // (lib.optionalAttrs (lockedNarHash != null) { narHash = lockedNarHash; })
              // (
                if val.repo ? url then
                  { url = val.repo.url; }
                else
                  {
                    owner = val.repo.owner;
                    repo = val.repo.repo;
                  }
              );
              followsAttrs = lib.mapAttrs (_: v: { follows = v; }) envInputFollows;
              base = repoAttrs // {
                inputs = followsAttrs;
              };
              extra = envInputExtra val;
            in
            lib.recursiveUpdate base extra;

          envInputs =
            let
              inputsList = map (val: {
                name = val.hostenv.userName;
                value = envInputSpec val;
              }) validatedEnvironments;
              cfInputs =
                if cloudflare.enable && cloudflare.apiTokenFile != null && cloudflare.zoneId != null then
                  map (val: {
                    name = "${val.hostenv.userName}-cf";
                    value = {
                      type = "path";
                      path = "${cloudflare.apiTokenFile}";
                    };
                  }) validatedEnvironments
                else
                  [ ];
            in
            builtins.listToAttrs (inputsList ++ cfInputs);

          baseInputs = {
            parent.url = "path:..";
            systems.follows = "parent/deploy-rs/utils/systems";
            deploy-rs.follows = "parent/deploy-rs";
            sops-nix.follows = "parent/sops-nix";
            hostenv.follows = "parent/hostenv";
            nixpkgs.follows = "parent/nixpkgs";
            flake-parts.follows = "parent/flake-parts";
            phps.follows = "parent/phps";
          };
          inputsText = toNix (baseInputs // generatedFlakeInputs // envInputs);
          nodeModulesText = lib.concatMapStringsSep "\n" (
            rel: "              (inputs.parent + ${toNix ("/" + rel)})"
          ) nodeModulesRel;
        in
        pkgs.writeText "flake.nix" ''
          {
            inputs = ${inputsText};

            outputs = { self, nixpkgs, deploy-rs, systems, ... } @ inputs:
              let
                config = builtins.removeAttrs
                  (builtins.fromJSON (builtins.readFile ./plan.json))
                  [ "_description" ];
                localSystem = "x86_64-linux";
              in
              inputs.parent.lib.provider.deployOutputs {
                inherit config nixpkgs deploy-rs systems inputs localSystem;
                nodesPath = ../nodes;
                secretsFile = ${toNix secretsFile};
                secretsPath = inputs.parent + ${toNix ("/" + secretsFile)};
                sopsSecretKeys = ${toNix sopsSecretKeys};
                nodeSystems = ${toNix nodeSystems};
                nodeAddresses = ${toNix nodeAddresses};
                nodeSshPorts = ${toNix nodeSshPorts};
                nodeSshOpts = ${toNix nodeSshOpts};
                nodeRemoteBuild = ${toNix nodeRemoteBuild};
                nodeMagicRollback = ${toNix nodeMagicRollback};
                nodeAutoRollback = ${toNix nodeAutoRollback};
                nodeModules = [
          ${nodeModulesText}
                ];
              };
          }
        '';

      # JSON representation of every environment returned by each hostenv flake.
      generatedConfig =
        let
          base = {
            _description = ''
              Contains a build and deployment plan for hostenv servers on NixOS.
              There are three data substructures:

              1. Under **environments** is a JSON representation of hostenv's own modules config, retaining the original structure of that representation.
              2. Each element under **nodes** is NixOS server configuration, and will be merged into the configuration of that server during build.
              3. Under **nodeConnections** is node routing metadata used by provider tooling (SSH hostname/options).

              Note: all manual changes to this file will be discarded.
            '';
            inherit
              hostenvHostname
              cloudflare
              deployUser
              nodeRemoteBuild
              nodeConnections
              ;
            nodeStatus = nodeStatuses;
            nixSigning.trustedPublicKeys = nixSigning.trustedPublicKeys or [ ];
            environments = { };

            # Every configured provider node is a deployable system target.
            # This lets deploy reconcile stale Hostenv accounts from the node's
            # actual passwd database even when the node has no current
            # environments.
            nodes = lib.genAttrs (builtins.attrNames nodeSystems) (_nodeName: {
              provider = {
                inherit deployPublicKeys deployUser;
                nixSigning.trustedPublicKeys = nixSigning.trustedPublicKeys or [ ];
              };

              # providerNixosSystem derives per-environment packages and
              # secrets from this attrset. Nodes without environments have
              # neither.
              users.users = { };
            });
          };
          configAttrs = builtins.foldl' (
            acc: env:
            let
              firstPart = builtins.head (lib.splitString "-" env.hostenv.userName);
              sliceName = "user-${env.hostenv.organisation}-${firstPart}";
              uidText = toString env.uid;
              nodeName =
                if builtins.isString env.node && env.node != "" then
                  env.node
                else
                  throw "nodeFor/default must be set to a node name for environment ${env.hostenv.userName}";
            in
            lib.recursiveUpdate acc {
              environments = acc.environments // {
                ${env.hostenv.userName} = env;
              };
              nodes = acc.nodes // {
                ${nodeName} =
                  let
                    existing = acc.nodes.${nodeName} or { };
                    nginxCfg = config.flake.lib.hostenv.nginxFrontdoor.mkNodeNginxConfig {
                      inherit lib;
                      envs = {
                        ${env.hostenv.userName} = env;
                      };
                      runtimeRoot = "/run/hostenv";
                      defaultEnableLetsEncrypt = letsEncrypt.enable or true;
                    };
                  in
                  lib.recursiveUpdate existing (
                    lib.recursiveUpdate {
                      security.acme = {
                        acceptTerms = letsEncrypt.acceptTerms;
                        defaults.email = letsEncrypt.adminEmail;
                      };
                      provider = {
                        inherit deployPublicKeys deployUser;
                        nixSigning.trustedPublicKeys = nixSigning.trustedPublicKeys or [ ];
                      };
                      users.groups.${env.hostenv.userName}.gid = env.uid;
                      users.users.${env.hostenv.userName} = {
                        uid = env.uid;
                        group = env.hostenv.userName;
                        openssh.authorizedKeys.keys = env.authorizedKeys;
                        isNormalUser = true;
                        createHome = true;
                        linger = true;
                      };
                      systemd.slices = {
                        ${sliceName} = {
                          description = "${firstPart} slice";
                          sliceConfig = {
                            CPUAccounting = "yes";
                            CPUQuota = "300%";
                            MemoryAccounting = "yes";
                            MemoryMax = "24G";
                          };
                        };
                        "user-${env.hostenv.organisation}-" = { };
                        "${sliceName}-" = { };
                      };
                      systemd.services."user@${uidText}" = {
                        overrideStrategy = "asDropin";
                        serviceConfig.Slice = "${sliceName}-${uidText}.slice";
                      };
                    } nginxCfg
                  );
              };
            }
          ) base environmentsWithUid;
        in
        pkgs.writers.writeJSON "plan.json" configAttrs;

      generatedState =
        let
          environmentState = builtins.listToAttrs (
            map (env: {
              name = env.hostenv.userName;
              value = {
                userName = env.hostenv.userName;
                inherit (env) uid;
                virtualHosts = builtins.attrNames env.virtualHosts;
              };
            }) environmentsWithUid
          );
        in
        pkgs.writers.writeJSON "state.json" (
          {
            _description = ''
              Persistent state to retain across deployments. Should be committed to version control.
            '';
          }
          # Keep reservations for old environments and update the reservations
          # for environments in the current plan. We do not store which node an
          # environment is on; deploy discovers that from the provider nodes.
          // lib.recursiveUpdate state environmentState
        );

    in
    assert (assertProjectInputs && assertUnsupportedProviderServiceOptions && assertNodeLifecycle);
    {
      flake = generatedFlakeFile;
      plan = generatedConfig;
      state = generatedState;
      environments = validatedEnvironments;
    };
in
{
  config.flake.lib.provider.plan = providerPlan;
}
