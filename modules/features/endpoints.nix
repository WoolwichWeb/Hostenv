{ config, ... }:
let
  packagesFor = config.flake.lib.hostenv.packagesFor;
in
{
  flake.modules.hostenv.endpoints =
    { config, lib, pkgs, ... }:
    let
      runtimeDir = config.hostenv.runtimeDir;
      # Service and endpoint names also become Unix socket path components.
      # Their naming contract is stricter than systemd's unit-name rules.
      safeName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null;

      socketPath = service: endpoint:
        let
          path = if endpoint == "default" then
            "${runtimeDir}/${service}.sock"
          else
            "${runtimeDir}/${service}/${endpoint}.sock";
        in
        if !(safeName service && safeName endpoint) then
          throw "Endpoint ${service}.${endpoint}: service and endpoint names must be safe path components; templates are not supported."
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

      # Only existing declarations are examined here. Helpers are emitted as
      # concrete units, not added to systemd.services while iterating that same
      # option, which would introduce a module-evaluation recursion.
      existingUnits =
        map (name: "${name}.service") (builtins.attrNames config.systemd.services)
        ++ map (name: "${name}.socket") (builtins.attrNames config.systemd.sockets);
      generatedNames = lib.concatMap (endpoint: [ endpoint.socketUnit endpoint.proxyUnit ]) entries;
      paths = map (endpoint: endpoint.socket) entries;
      pathsConflict = a: b: a == b || lib.hasPrefix "${a}/" b || lib.hasPrefix "${b}/" a;
      errors =
        lib.concatMap (endpoint:
          let owner = config.systemd.services.${endpoint.service};
          in lib.optional (owner.name != endpoint.owner)
            "Endpoint ${endpoint.service}.${endpoint.name}: the owning unit name must not be overridden."
          ++ lib.optional (!(lib.elem (owner.serviceConfig.Type or "simple") [ "simple" "exec" "notify" "notify-reload" ]))
            "Endpoint ${endpoint.service}.${endpoint.name}: only foreground simple, exec and notifying services are supported."
          ++ lib.optional (lib.any (path: pathsConflict endpoint.socket path) config.networking.reservedSocketPaths)
            "Endpoint ${endpoint.service}.${endpoint.name}: ${endpoint.socket} conflicts with a native socket."
        ) entries
        ++ lib.optional (builtins.length generatedNames != builtins.length (lib.unique generatedNames))
          "Hostenv endpoints generated conflicting unit names."
        ++ lib.optional (lib.any (name: lib.elem name existingUnits) generatedNames)
          "A generated endpoint unit conflicts with an explicitly declared systemd unit."
        ++ lib.optional (lib.any (path: builtins.length (lib.filter (other: pathsConflict path other) paths) != 1) paths)
          "Hostenv endpoints have conflicting socket paths or file/directory names.";
      plan = if errors == [ ] then entries else throw (lib.concatStringsSep "\n" errors);

      runtime = "${(packagesFor pkgs).hostenv-runtime}/bin/hostenv-system endpoint";
      makeUnits = endpoint:
        let
          manifest = pkgs.writeText "hostenv-endpoint-${endpointId endpoint.service endpoint.name}.json" (builtins.toJSON {
            inherit (endpoint) owner socket port descriptor;
            runtime_dir = runtimeDir;
            systemctl = "${config.systemd.package}/bin/systemctl";
            nsenter = "${pkgs.util-linux}/bin/nsenter";
            setpriv = "${pkgs.util-linux}/bin/setpriv";
            proxy = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd";
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
                  Export named private TCP listeners through environment-private
                  Unix sockets. The owning service must establish its private
                  user and network namespaces through its service integration.
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
                      description = "Generated environment-private Unix socket path.";
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
        networking.reservedSocketPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          internal = true;
          description = "Native listener paths registered by service integrations for collision checks.";
        };
        networking.endpointPlan = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          readOnly = true;
          internal = true;
          default = plan;
          description = "Resolved non-secret endpoint paths, ports and helper identities.";
        };
      };
      config.systemd.units = lib.listToAttrs (lib.concatMap makeUnits plan);
    };
}
