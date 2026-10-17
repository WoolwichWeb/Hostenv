{ ... }:
{
  flake.modules.nixos.hostenv-top-level =
    { config, pkgs, lib, ... }:
    let
      enabledEnvs =
        lib.filterAttrs
          (_: env: env.enable or true)
          config.provider.plan.environments;
      envUser = name: env: env.hostenv.userName or name;
      envKeys = env:
        lib.foldlAttrs (acc: _n: u: acc ++ (u.publicKeys or [ ])) [ ] (env.users or { });
    in
    {
      # Options for NixOS fed from plan.json.
      options.provider.plan = {
        environments = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = { };
          description = "Hostenv environments (provider plan or project output).";
        };

        defaultEnvironment = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Default environment name for hostenv, when one is defined.";
        };

        runtimeRoot = lib.mkOption {
          type = lib.types.str;
          default = "/run/hostenv";
          description = "Root directory for hostenv runtime sockets and state.";
        };
      };

      config = lib.mkMerge [
        {
          # The provider runtime root is required even before any environment
          # has been allocated to the node.
          systemd.tmpfiles.rules = [
            "d ${config.provider.plan.runtimeRoot} 0755 root root -"
          ];
        }
        (lib.mkIf (enabledEnvs != { }) {
          # Ensure runtime directories exist for user-level services and upstream sockets.
          # Permissions align with the hostenv/nginx contract:
          # - user/<env>: owned by the env user, setgid to keep group 'users', private to others.
          # - nginx/<env>: owned by env user but group 'nginx' so system nginx can reach sockets; setgid keeps group.
          systemd.tmpfiles.rules =
            let
              base = [
                "d ${config.provider.plan.runtimeRoot}/nginx   0755 root root  -"
                "d ${config.provider.plan.runtimeRoot}/user    0755 root root  -"
              ];
              perEnv = lib.flatten (lib.mapAttrsToList
                (name: env:
                  let user = envUser name env;
                  in [
                    "d ${config.provider.plan.runtimeRoot}/nginx/${user} 2770 ${user} nginx -"
                    "d ${config.provider.plan.runtimeRoot}/user/${user}  2700 ${user} users -"
                  ])
                enabledEnvs);
            in
            base ++ perEnv;

          # Basic users/groups for environments (idempotent; real UID assignment handled in provider plan).
          users =
            let
              userEntries = lib.listToAttrs (lib.mapAttrsToList
                (name: env:
                  let user = envUser name env;
                  in {
                    name = user;
                    value = {
                      isNormalUser = true;
                      uid = env.uid or null;
                      group = user;
                      createHome = true;
                      openssh.authorizedKeys.keys = envKeys env;
                      linger = true;
                    };
                  })
                enabledEnvs);
              groupEntries = lib.listToAttrs (lib.mapAttrsToList
                (name: env:
                  let user = envUser name env;
                  in { name = user; value = { }; })
                enabledEnvs);
            in
            {
              users = userEntries;
              groups = groupEntries;
            };
        })
      ];
    }
  ;
}
