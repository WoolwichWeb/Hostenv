{ ... }:
{
  flake.modules.hostenv.tools-devshells =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      devenvCompat = config.hostenv.compatibility.devenv;
      withDevenvCompat = script: ''
        ${lib.optionalString devenvCompat.enable devenvCompat.script}
        ${script}
      '';

      hostenvShells =
        # Build a hostenv CLI for each environment.
        lib.mapAttrs (
          environmentName: environment:
          let
            # Ensure the project git branch tied to this hostenv environment
            # is checked out.
            envStartup = withDevenvCompat ''
              currentBranch=$(git symbolic-ref --short HEAD)

              if [ ! "$currentBranch" = "${environmentName}" ]; then
                if git show-ref --quiet --branches "${environmentName}"; then
                  git checkout "${environmentName}" || exit 1
                fi
              fi

              hostenv banner
            '';

          in
          {
            devshell = {
              name = "devshell-${environmentName}";

              packages = with pkgs; [
                config.hostenv.cliPackage
                restic
                boxes
                jq
              ];

              startup.hostenv = {
                text = envStartup;
              };

            };
            env = [
              {
                name = "DEVSHELL_NO_MOTD";
                value = 1;
              }
            ];
          }
        ) (lib.filterAttrs (_: v: v.enable) config.exportedEnvironments)
        // {
          default = {
            devshell = {
              name = "devshell";
              # On startup of the project CLI, we check if the current git
              # branch is tied to a hostenv environment. If it is, we set the
              # CLI to work with that environment. If it is not, we warn the
              # user, and provide some quick guidance.
              startup.hostenv = {
                text = withDevenvCompat ''
                  ENV_JSON='${builtins.toJSON (lib.filterAttrs (_: v: v.enable) config.exportedEnvironments)}'

                  if gitRef=$(git symbolic-ref -q --short HEAD 2>/dev/null); then
                    # Is current branch a hostenv environment?
                    if jq -e --arg ref "$gitRef" 'has($ref)' <<<"$ENV_JSON" >/dev/null; then
                      : # OK
                    else
                      printf '%s\n\n%s\n' \
                        "⚠️ Hostenv is not configured for branch '$gitRef'." \
                        "ℹ️ To use this branch, add 'environments.$gitRef.enable = true;' to hostenv.nix." >&2
                    fi
                  else
                    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                      echo "⚠️ Hostenv cannot select an environment because Git is in detached HEAD state." >&2
                      echo "ℹ️ Check out a configured branch." >&2
                    else
                      echo "⚠️ Hostenv cannot select an environment because this directory is not a Git repository." >&2
                      echo "ℹ️ Run the development shell from the project repository." >&2
                    fi
                  fi
                '';
              };
            };
            env = [
              {
                name = "DEVSHELL_NO_MOTD";
                value = 1;
              }
            ];
          };
        };
    in
    {
      config.hostenv.devShells = lib.mkDefault hostenvShells;
    };
}
