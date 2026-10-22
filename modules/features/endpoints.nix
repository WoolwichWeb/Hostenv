# Expose private TCP listeners through Unix sockets.
#
# Services declare named endpoints under `systemd.services.<name>.endpoints`.
# For each endpoint, Hostenv generates a systemd socket unit and a forwarding
# service that connects to the declared TCP port inside the owning service's
# private network namespace.
{ config, ... }:
let
  packagesFor = config.flake.lib.hostenv.packagesFor;
in
{
  flake.modules.hostenv.endpoints =
    { config, lib, pkgs, ... }:
    let
      # Service and endpoint names also become Unix socket path components.
      # Their naming contract is stricter than systemd's unit-name rules.
      safeName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null;

      # Full path to the socket file, ensuring the file name is valid and not
      # too long.
      socketPath = service: endpoint:
        let
          path = if endpoint == "default" then
            "${config.hostenv.runtimeDir}/${service}.sock"
          else
            "${config.hostenv.runtimeDir}/${service}/${endpoint}.sock";
        in
        if !(safeName service && safeName endpoint) then
          throw "Endpoint ${service}.${endpoint}: service and endpoint names must be safe path components; templates are not supported."
        # Note that Nix's stringLength function counts UTF-8 bytes not the
        # number of characters in a string. The 108 byte Unix socket path
        # must also fit its terminating NUL.
        else if builtins.stringLength path >= 108 then
          throw "Endpoint ${service}.${endpoint}: its Unix socket path exceeds 107 bytes: ${path}"
        else path;

      endpointId = service: endpoint:
        builtins.substring 0 32 (builtins.hashString "sha256" (builtins.toJSON [ service endpoint ]));

      entries = lib.concatLists (lib.mapAttrsToList (service: unit:
        lib.optionals unit.enable (lib.mapAttrsToList (name: endpoint: {
          inherit service name;
          inherit (endpoint) port socket socketUnit proxyUnit;
          owner = "${service}.service";
          descriptor = "hostenv-${endpointId service name}";
        }) unit.endpoints)
      ) config.systemd.services);

      # Collect declared service and socket unit names so that generated
      # endpoint units cannot reuse them. Generate the endpoint units under
      # systemd.units to avoid defining systemd.services in terms of itself.
      existingUnits =
        map (name: "${name}.service") (builtins.attrNames config.systemd.services)
        ++ map (name: "${name}.socket") (builtins.attrNames config.systemd.sockets);
      generatedNames = lib.concatMap (endpoint: [ endpoint.socketUnit endpoint.proxyUnit ]) entries;
      paths = map (endpoint: endpoint.socket) entries;
      pathsConflict = a: b: a == b || lib.hasPrefix "${a}/" b || lib.hasPrefix "${b}/" a;

      # This makes a best effort attempt at checking filesystem listener
      # paths declared by enabled systemd socket units, to find any that
      # conflict. Note this cannot track paths opened directly by applications
      listenPaths = value: lib.filter
        (path: builtins.isString path && lib.hasPrefix "/" path)
        (lib.toList value);
      systemdSocketPaths = lib.concatLists (lib.mapAttrsToList (_: unit:
        lib.optionals unit.enable (lib.concatMap listenPaths [
          (unit.socketConfig.ListenStream or [ ])
          (unit.socketConfig.ListenDatagram or [ ])
          (unit.socketConfig.ListenSequentialPacket or [ ])
          (unit.socketConfig.ListenFIFO or [ ])
          unit.listenStreams
          unit.listenDatagrams
        ])
      ) config.systemd.sockets);

      errors =
        lib.concatMap (endpoint:
          let owner = config.systemd.services.${endpoint.service};
          in lib.optional (owner.name != endpoint.owner)
            "Endpoint ${endpoint.service}.${endpoint.name}: the owning unit name must not be overridden."
          ++ lib.optional (!(lib.elem (owner.serviceConfig.Type or "simple") [ "simple" "exec" "notify" "notify-reload" ]))
            "Endpoint ${endpoint.service}.${endpoint.name}: only foreground simple, exec and notifying services are supported."
          ++ lib.optional (lib.any (path: pathsConflict endpoint.socket path) systemdSocketPaths)
            "Endpoint ${endpoint.service}.${endpoint.name}: ${endpoint.socket} conflicts with a declared systemd socket."
        ) entries
        ++ lib.optional (builtins.length generatedNames != builtins.length (lib.unique generatedNames))
          "Hostenv endpoints generated conflicting unit names."
        ++ lib.optional (lib.any (name: lib.elem name existingUnits) generatedNames)
          "A generated endpoint unit conflicts with an explicitly declared systemd unit."
        ++ lib.optional (lib.any (path: builtins.length (lib.filter (other: pathsConflict path other) paths) != 1) paths)
          "Hostenv endpoints have conflicting socket paths or file/directory names.";
      plan = if errors == [ ] then entries else throw (lib.concatStringsSep "\n" errors);

      # The Haskell helper checks socket paths and manages forwarding into
      # the owning service's private network namespace.
      runtime = "${(packagesFor pkgs).hostenv-runtime}/bin/hostenv-system endpoint";

      makeUnits = endpoint:
        let
          manifest = pkgs.writeText "hostenv-endpoint-${endpointId endpoint.service endpoint.name}.json" (builtins.toJSON {
            inherit (endpoint) owner socket port descriptor;
            runtime_dir = config.hostenv.runtimeDir;
          });
        in
        [
          (lib.nameValuePair endpoint.socketUnit {
            wantedBy = [ "sockets.target" ];
            text = ''
              [Unit]
              Description=Private socket for ${endpoint.service}.${endpoint.name}

              [Socket]
              ListenStream=${endpoint.socket}
              FileDescriptorName=${endpoint.descriptor}
              Service=${endpoint.proxyUnit}
              SocketMode=0600
              DirectoryMode=0700
              RemoveOnStop=true
              ExecStartPre=${runtime} prepare ${manifest}
            '';
          })
          (lib.nameValuePair endpoint.proxyUnit {
            # Starting the monitor before the owner is intentional. Type=exec
            # lets the owner start while the monitor waits for its readiness.
            # The inverse stop order lets the owner drain before its proxy.
            text = ''
              [Unit]
              Description=Export ${endpoint.service}.${endpoint.name} through its private socket
              Requires=${endpoint.owner}
              Before=${endpoint.owner}
              PartOf=${endpoint.owner}
              BindsTo=${endpoint.socketUnit}
              After=${endpoint.socketUnit}

              [Service]
              Type=exec
              Environment="PATH=${lib.makeBinPath [ config.systemd.package pkgs.util-linux ]}:${config.systemd.package}/lib/systemd"
              ExecStart=${runtime} serve ${manifest}
              # Give the monitor SIGTERM first so it can stop and reap the
              # proxy. With control-group, both receive SIGTERM at once and
              # an intentional shutdown can be reported as exit status 143.
              # Mixed mode still escalates to the whole cgroup if necessary.
              KillMode=mixed
              TimeoutStopSec=10s
              Restart=on-failure
              RestartSec=2s
            '';
          })
        ];
    in
    {
      options = {
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule ({ name, ... }:
            let service = name;
            in {
              options.endpoints = lib.mkOption {
                default = { };
                description = ''
                  Expose TCP listeners in this service's private network
                  namespace through Unix sockets. Set each endpoint's port
                  to a listener reachable on 127.0.0.1.
                '';
                type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
                  options = {
                    port = lib.mkOption {
                      type = lib.types.ints.between 1 65535;
                      description = "Private loopback TCP port to export.";
                    };
                    socket = lib.mkOption {
                      type = lib.types.str;
                      readOnly = true;
                      default = socketPath service name;
                      defaultText = lib.literalExpression ''
                        if name == "default" then
                          "''${config.hostenv.runtimeDir}/''${service}.sock"
                        else
                          "''${config.hostenv.runtimeDir}/''${service}/''${name}.sock"
                      '';
                      description = "Path to the Unix socket for this endpoint.";
                    };
                    socketUnit = lib.mkOption {
                      type = lib.types.str;
                      readOnly = true;
                      internal = true;
                      default = if name == "default" then "${service}.socket"
                        else "hostenv-endpoint-${endpointId service name}.socket";
                      description = "Generated socket unit for this endpoint.";
                    };
                    proxyUnit = lib.mkOption {
                      type = lib.types.str;
                      readOnly = true;
                      internal = true;
                      default = "hostenv-endpoint-${endpointId service name}.service";
                      description = "Generated forwarding service for this endpoint.";
                    };
                  };
                }));
              };
            }
          ));
        };
      };
      config.systemd.units = lib.listToAttrs (lib.concatMap makeUnits plan);
    };
}
