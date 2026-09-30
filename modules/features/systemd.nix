# Portions of this file are derived from the Nixpkgs/NixOS and home-manager projects,
# originally licensed under the MIT License.
#
# Original source:
# https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/system/boot/systemd.nix
# https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/system/boot/systemd/user.nix
# https://github.com/nix-community/home-manager/blob/82c265faf4e3161d6015db07c9b0f1ee36a9029b/modules/systemd.nix#L521-L547
#
# See:
#   LICENSES/MIT-nixpkgs.
#   LICENSES/MIT-home-manager.

{ ... }:
{
  flake.modules.hostenv.systemd =
    # Based on nixpkgs' systemd.nix but with all the system-level
    # config removed.
    # @todo: add support for restarting/reloading a service when an arbitrary
    # derivation changes. As opposed to `reloadIfChanged` and `restartIfChanged`.
    
    { lib, config, pkgs, ... }:
    
    with lib;
    
    let
      cfg = config.systemd;
      utils = import (pkgs.path + "/nixos/lib/utils.nix") { inherit pkgs lib config; };
      systemdUtils = utils.systemdUtils;
    
      # Useful functions from upstream, also available:
      # makeUnit, generateUnits, mountToUnit, etc.
      inherit (systemdUtils.lib)
        targetToUnit
        serviceToUnit
        sliceToUnit
        socketToUnit
        timerToUnit
        pathToUnit
        ;
    
    in
    {
      options.systemd =
        {
    
          package = mkPackageOption pkgs "systemd" { };
    
          enableStrictShellChecks = mkEnableOption "" // { description = "Whether to run shellcheck on the generated scripts for systemd units."; };
    
          units = mkOption {
            description = "Definition of systemd units; see {manpage}`systemd.unit(5)`.";
            default = { };
            type = systemdUtils.types.units;
          };
    
          packages = mkOption {
            default = [ ];
            type = types.listOf types.package;
            example = literalExpression "[ pkgs.systemd-cryptsetup-generator ]";
            description = "Packages providing systemd units and hooks.";
          };
    
          targets = mkOption {
            default = { };
            type = systemdUtils.types.targets;
            description = "Definition of systemd target units; see {manpage}`systemd.target(5)`";
          };
    
          services = mkOption {
            default = { };
            type = systemdUtils.types.services;
            description = "Definition of systemd service units; see {manpage}`systemd.service(5)`.";
          };
    
          sockets = mkOption {
            default = { };
            type = systemdUtils.types.sockets;
            description = "Definition of systemd socket units; see {manpage}`systemd.socket(5)`.";
          };
    
          timers = mkOption {
            default = { };
            type = systemdUtils.types.timers;
            description = "Definition of systemd timer units; see {manpage}`systemd.timer(5)`.";
          };
    
          paths = mkOption {
            default = { };
            type = systemdUtils.types.paths;
            description = "Definition of systemd path units; see {manpage}`systemd.path(5)`.";
          };
    
          slices = mkOption {
            default = { };
            type = systemdUtils.types.slices;
            description = "Definition of slice configurations; see {manpage}`systemd.slice(5)`.";
          };
    
          globalEnvironment = mkOption {
            type = with types; attrsOf (nullOr (oneOf [ str path package ]));
            default = { };
            example = { TZ = "CET"; };
            description = ''
              Environment variables passed to *all* systemd units (for this user).
            '';
          };
    
        };
    
      config =
        let
          newUnits = pkgs.buildEnv {
            name = "systemd-user-${config.hostenv.userName}";
            paths = mapAttrsToList writeUnit cfg.units;
            # The paths above are the units, in postBuild we create those units'
            # dependencies using systemd's directory + symlink structure.
            postBuild =
              # Finally, concat the list of Bash scripts together.
              concatStringsSep "\n" (
                # Transform the set of named units into a list of string
                # Bash scripts.
                mapAttrsToList
                  (name: unit:
                    # Transforms a unit into a script to install that unit.
                    concatStringsSep "\n" (
                      map (installDeps "wants" name) unit.wantedBy
                      ++ map (installDeps "requires" name) unit.requiredBy
                      ++ map (installDeps "upholds" name) unit.upheldBy
                    ))
                  # The units to map over.
                  cfg.units
              );
          };
    
          writeUnit = name: unit: pkgs.writeTextDir "systemd/user/${name}" unit.text;
    
          # Make a script that will create a systemd dependency.
          # The naming is a bit odd, so think of it this way:
          # unitThat controlVerbs object, or to give a concrete example,
          # app.timer might be a unitThat wants app.service.
          installDeps = controlVerb: objectUnit: unitThat: ''
            mkdir -p $out/systemd/user/${unitThat}.${controlVerb}
            pushd $out/systemd/user/${unitThat}.${controlVerb}
            ln -s ../${objectUnit} ${objectUnit}
            popd
            ls -lah $out
            ls -lah $out/systemd/user/
          '';
    
        in
        {
          systemd.units =
            mapAttrs' (n: v: nameValuePair "${n}.path" (pathToUnit v)) cfg.paths
            // mapAttrs' (n: v: nameValuePair "${n}.service" (serviceToUnit v)) cfg.services
            // mapAttrs' (n: v: nameValuePair "${n}.slice" (sliceToUnit v)) cfg.slices
            // mapAttrs' (n: v: nameValuePair "${n}.socket" (socketToUnit v)) cfg.sockets
            // mapAttrs' (n: v: nameValuePair "${n}.target" (targetToUnit v)) cfg.targets
            // mapAttrs' (n: v: nameValuePair "${n}.timer" (timerToUnit v)) cfg.timers;
    
          # Generate timer units for all services that have a ‘startAt’ value.
          systemd.timers = mapAttrs
            (name: service: {
              wantedBy = [ "timers.target" ];
              timerConfig.OnCalendar = service.startAt;
            })
            (filterAttrs (name: service: service.startAt != [ ]) cfg.services);
    
          # This is simplistic compared to upstream nixpkgs implementation.
          # For example, see upstreams use of `restartTriggers` and `reloadTriggers`:
          # https://github.com/NixOS/nixpkgs/blob/release-24.11/nixos/lib/systemd-lib.nix#L439
          # https://github.com/NixOS/nixpkgs/blob/release-24.11/pkgs/by-name/sw/switch-to-configuration-ng/src/src/main.rs#L388
          activate =
            let
              # Make sure that we have an environment where we are likely to
              # successfully talk with systemd.
              ensureSystemd = ''
                env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
                    PATH="${dirOf cfg.package}/bin:$PATH" \
              '';
    
              systemctl = "${cfg.package}/bin/systemctl";
            in
            ''
              ## systemd activation script.
    
              # The following is snagged from Home Manager:
              # https://github.com/nix-community/home-manager/blob/9a9fef316ad191b3086edda465e850af282de4e0/modules/systemd.nix#L340C1-L368C26
    
              if [ ! -n "$XDG_CONFIG_HOME" ]; then
                echo '⚠️ XDG_CONFIG_HOME is not set.' >&2
                echo 'ℹ️ Set it before activating the environment.' >&2
                exit 1
              fi
    
              # Ensure the config directory exists, if this is a new user there's a good chance it hasn't been created yet.
              mkdir -p "$XDG_CONFIG_HOME" || exit 1
    
              systemdStatus=$(${systemctl} --user is-system-running 2>&1 || true)
    
              if [ "$systemdStatus" == 'running' ] || [ "$systemdStatus" == 'degraded' ]; then
                if [ "$systemdStatus" == 'degraded' ]; then
                  echo "⚠️ The user systemd session is degraded. Failed units:" >&2
                  ${systemctl} --user --no-pager --state=failed >&2
                  echo "ℹ️ Hostenv will try to reload the services anyway." >&2
                fi
    
                mkdir -p "${config.hostenv.stateDir}/hostenv/current-state" || exit 1
                oldUnitsDir="${config.hostenv.stateDir}/hostenv/current-state/systemd/user"
    
                if [ ! -e "$oldUnitsDir" ]; then
                  oldUnitsDir=
                fi
    
                if [ -e "$XDG_CONFIG_HOME"/systemd ]; then
                  # If the file is a symlink to a directory that exists...
                  if [ -L "$XDG_CONFIG_HOME"/systemd ]; then
                    # ...then delete it.
                    rm "$XDG_CONFIG_HOME"/systemd
                  else
                    # Otherwise the file exists, but is not a symlink.
                    echo "⚠️ '$XDG_CONFIG_HOME/systemd' already exists and is not a symbolic link." >&2
                    echo "ℹ️ Move or remove it after checking that it contains nothing you need, then try again." >&2
                    exit 1
                  fi
                fi
    
                # -f covers the case where "XDG_CONFIG_HOME" is a symlink to
                # a file/directory that doesn't exist.
                ln -sf ${newUnits}/systemd "$XDG_CONFIG_HOME"/systemd || exit 1
    
                # This compares the existing units with the ones in the new
                # derivation, with help from the excellent `sd-switch`.
                # https://git.sr.ht/~rycee/sd-switch
                ${ensureSystemd} ${lib.getExe pkgs.sd-switch} --user \
                  ''${oldUnitsDir:+--old-units "$oldUnitsDir"} \
                  --new-units "$XDG_CONFIG_HOME"/systemd/user || exit 1
    
                # The new units become the old in the next activation.
                if [ -e "$XDG_STATE_HOME"/hostenv/current-state/systemd ]; then
                  if [ -L "$XDG_STATE_HOME"/hostenv/current-state/systemd ]; then
                    rm "$XDG_STATE_HOME"/hostenv/current-state/systemd
                  else
                    echo "⚠️ '$XDG_STATE_HOME/hostenv/current-state/systemd' already exists and is not a symbolic link." >&2
                    echo "ℹ️ Move or remove it, then try again." >&2
                    exit 1
                  fi
                fi
    
                ln -sf ${newUnits}/systemd "$XDG_STATE_HOME"/hostenv/current-state/systemd || exit 1
    
                unset oldUnitsDir newUnits
    
              else
                echo "⚠️ The user systemd service manager is not running, so the environment cannot start." >&2
                echo "ℹ️ Ensure that it is running, then try again." >&2
              fi
    
              unset systemdStatus
            '';
    
          profile = [ newUnits ];
        };
    
    }
  ;
}
