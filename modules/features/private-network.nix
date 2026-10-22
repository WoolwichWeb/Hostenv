# Private network isolation for the main process of a systemd user service.
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
        # @todo: Private networking currently changes ExecStart after Nix has
        # merged the systemd service options. This is unusual: the command in
        # the generated unit differs from serviceConfig.ExecStart in the
        # evaluated configuration. In future, consider using the systemd
        # `script` option for service commands and deriving ExecStart from it,
        # as Nixpkgs does, rather than rewriting ExecStart when rendering units.
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
            Run ExecStart in private user and network namespaces, with loopback
            enabled and no route to other networks.

            Other service commands, such as ExecStartPre and ExecReload, run
            outside these namespaces.
          '';
        };

        config = lib.mkIf config.hostenv.network.isolated {
          serviceConfig.NoNewPrivileges = true;
        };
      }));
    };
  };
}
