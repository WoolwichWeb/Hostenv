# Private network isolation for the main process of a systemd user service.
# Keep the namespace machinery independent of application integrations.
{ ... }:
{
  flake.lib.hostenv.privateNetwork.wrapService = pkgs: service:
    if !service.hostenv.network.isolated then
      service
    else
      let
        command = service.serviceConfig.ExecStart or null;

        # A single ordinary ExecStart may be prefixed without changing how
        # systemd parses its arguments. Prefix flags (@, -, +, ! and :) and
        # multiple commands have different semantics and need explicit support.
        # Semicolons can separate commands inside an ExecStart directive.
        supported = builtins.isString command
          && builtins.match "/[^[:space:]]+([[:space:]]+.*)?" command != null
          && builtins.match ".*;.*" command == null;

        enter = pkgs.writeShellScript "hostenv-private-network-enter" ''
          set -e
          ${pkgs.iproute2}/bin/ip link set lo up
          exec ${pkgs.util-linux}/bin/setpriv \
            --bounding-set=-all --inh-caps=-all --ambient-caps=-all "$@"
        '';
      in
      if !supported then
        throw "Hostenv private networking for ${service.name} requires one ExecStart command with an absolute executable path (no systemd prefixes or command separators)."
      else if service.serviceConfig.NoNewPrivileges != true then
        throw "Hostenv private networking for ${service.name} requires NoNewPrivileges=true."
      else
        service // {
          serviceConfig = service.serviceConfig // {
            ExecStart =
              "${pkgs.util-linux}/bin/unshare --user --map-current-user --keep-caps --net ${enter} ${command}";
          };
        };

  flake.modules.hostenv.private-network = { lib, ... }: {
    options.systemd.services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ config, lib, ... }: {
        options.hostenv.network.isolated = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Run the service's main ExecStart process in private user and
            network namespaces with loopback enabled and no general outbound
            network access. Namespace setup must succeed before the application
            starts. This does not isolate ExecStartPre, ExecStartPost,
            ExecReload or other systemd control commands.
          '';
        };

        # Enforce the existing Gotenberg security property for every service
        # using this execution mode. A conflicting explicit false must fail.
        config.serviceConfig.NoNewPrivileges =
          lib.mkIf config.hostenv.network.isolated true;
      }));
    };
  };
}
