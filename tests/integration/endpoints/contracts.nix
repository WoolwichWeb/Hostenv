{ pkgs, makeHostenv }:
let
  lib = pkgs.lib;
  # Compare generated units without interpreting Nix store paths as regexes.
  contains = needle: haystack:
    builtins.replaceStrings [ needle ] [ "" ] haystack != haystack;
  evaluate = extra: (makeHostenv [
    {
      hostenv = {
        organisation = "test";
        project = "endpoints";
        root = pkgs.emptyDirectory;
        hostenvHostname = "hosting.test";
      };
      environments.main.enable = true;
    }
    extra
  ] "main").config;
  owner = {
    serviceConfig = {
      Type = "notify";
      ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";
      Restart = "always";
    };
  };
  single = evaluate {
    systemd.services.example = owner // { endpoints.default.port = 3000; };
  };
  multiple = evaluate {
    systemd.services.example = owner // {
      endpoints = { default.port = 3000; api.port = 3001; admin.port = 3002; };
    };
    systemd.services.other = owner // { endpoints.api.port = 4000; };
  };
  named = evaluate {
    systemd.services.example = owner // { endpoints.api.port = 3001; };
  };
  disabled = evaluate {
    systemd.services.example = owner // { enable = false; endpoints.default.port = 3000; };
  };
  # Evaluate only the relevant generated socket unit. Forcing every systemd
  # unit traverses unrelated definitions and may recurse. Reading the generated
  # text still forces endpoint validation without exposing an internal plan.
  socketUnitText = cfg: service: endpoint:
    let name = cfg.systemd.services.${service}.endpoints.${endpoint}.socketUnit;
    in cfg.systemd.units.${name}.text;
  unitEvaluates = cfg: service: endpoint:
    (builtins.tryEval (builtins.deepSeq (socketUnitText cfg service endpoint) true)).success;
  failsWith = service: endpoint: extra: !(unitEvaluates (evaluate extra) service endpoint);
  fails = failsWith "example" "default";
  ep = multiple.systemd.services.example.endpoints;
  runtime = multiple.hostenv.runtimeDir;
  samePort = evaluate {
    systemd.services.example = owner // { endpoints = { api.port = 3000; alias.port = 3000; }; };
  };
  exactRoot = "/" + lib.concatStrings (lib.replicate 99 "r");
  checks = [
    (unitEvaluates single "example" "default")
    # Declaring endpoints must not silently change the owner's network policy.
    (!single.systemd.services.example.hostenv.network.isolated)
    (!(lib.hasInfix "/bin/unshare" single.systemd.units."example.service".text))
    (single.systemd.services.example.endpoints.default.socket == "${runtime}/example.sock")
    (ep.default.socket == single.systemd.services.example.endpoints.default.socket)
    (ep.api.socket == named.systemd.services.example.endpoints.api.socket)
    (ep.api.socket == "${runtime}/example/api.sock")
    (ep.admin.socket == "${runtime}/example/admin.sock")
    (multiple.systemd.services.other.endpoints.api.socket == "${runtime}/other/api.sock")
    (!(disabled.systemd.units ? "example.socket"))
    (samePort.systemd.services.example.endpoints.api.socketUnit
      != samePort.systemd.services.example.endpoints.alias.socketUnit)
    (builtins.hasAttr samePort.systemd.services.example.endpoints.api.socketUnit samePort.systemd.units)
    (builtins.hasAttr samePort.systemd.services.example.endpoints.alias.socketUnit samePort.systemd.units)
    (builtins.all (key:
      multiple.systemd.services.example.serviceConfig.${key} == owner.serviceConfig.${key}
    ) (builtins.attrNames owner.serviceConfig))
    (lib.hasInfix "Type=notify" multiple.systemd.units."example.service".text)
    (!(lib.hasInfix "Endpoint=" multiple.systemd.units."example.service".text))
    (lib.hasInfix "SocketMode=0600" multiple.systemd.units.${ep.api.socketUnit}.text)
    (lib.hasInfix "KillMode=mixed" multiple.systemd.units.${ep.api.proxyUnit}.text)
    (contains
      "Environment=\"PATH=${lib.makeBinPath [ multiple.systemd.package pkgs.util-linux ]}:${multiple.systemd.package}/lib/systemd\""
      multiple.systemd.units.${ep.api.proxyUnit}.text)
    (lib.hasInfix "FileDescriptorName=hostenv-" multiple.systemd.units.${ep.api.socketUnit}.text)
    (ep.default.socketUnit == "example.socket")
    (ep.api.proxyUnit != ep.admin.proxyUnit)
    (fails { systemd.services.example = owner // { endpoints.default.port = 0; }; })
    (fails { systemd.services.example = owner // { endpoints.default.port = 65536; }; })
    (failsWith "example" "../bad" { systemd.services.example = owner // { endpoints."../bad".port = 3000; }; })
    (failsWith "example@%i" "default" {
      systemd.services."example@%i" = owner // { endpoints.default.port = 3000; };
    })
    (fails { systemd.services.example = owner // { endpoints.default = { port = 3000; protocol = "http"; }; }; })
    (fails { systemd.services.example = owner // { endpoints.default = { port = 3000; socket = "/tmp/override"; }; }; })
    # Detect conflicts with actual systemd socket declarations, not a
    # separately maintained list of paths.
    (fails {
      systemd.services.example = owner // { endpoints.default.port = 3000; };
      systemd.sockets.existing.listenStreams = [ "${runtime}/example.sock" ];
    })
    (failsWith "example" "api" {
      systemd.services.example = owner // { endpoints.api.port = 3000; };
      systemd.sockets.existing.socketConfig.ListenStream = "${runtime}/example";
    })
    (fails {
      systemd.services.example = owner // { endpoints.default.port = 3000; };
      systemd.sockets.existing.listenDatagrams = [ "${runtime}/example.sock" ];
    })
    (unitEvaluates (evaluate {
      systemd.services.example = owner // { endpoints.default.port = 3000; };
      systemd.sockets.existing.listenStreams = [ "${runtime}/unrelated.sock" ];
    }) "example" "default")
    (fails {
      systemd.services.example = owner // { endpoints.default.port = 3000; };
      systemd.sockets.example.listenStreams = [ "/run/other.sock" ];
    })
    (fails {
      systemd.services.example = owner // { endpoints.default.port = 3000; };
      systemd.services."example.sock" = owner // { endpoints.api.port = 3001; };
    })
    (fails {
      systemd.services.example = owner // { endpoints.default.port = 3000; name = "different.service"; };
    })
    (fails {
      systemd.services.example = { serviceConfig.Type = "oneshot"; endpoints.default.port = 3000; };
    })
    (fails {
      hostenv.runtimeRoot = exactRoot;
      systemd.services.example = owner // { endpoints.default.port = 3000; };
    })
  ];
in
assert lib.assertMsg (builtins.all (value: value) checks) "Endpoint configuration contract failed";
pkgs.runCommand "endpoint-contracts" { } ''
  printf '%s\n' '${toString (builtins.length checks)} endpoint configuration assertions passed' > "$out"
''
