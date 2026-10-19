{ pkgs, makeHostenv }:
let
  lib = pkgs.lib;
  evaluate = extra: (makeHostenv [
    {
      hostenv = {
        organisation = "test";
        project = "private-network";
        root = pkgs.emptyDirectory;
        hostenvHostname = "hosting.test";
      };
      environments.main.enable = true;
    }
    extra
  ] "main").config;

  command = "${pkgs.coreutils}/bin/sleep infinity";
  reload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";

  isolated = evaluate {
    systemd.services.example = {
      hostenv.network.isolated = true;
      serviceConfig = {
        Type = "notify";
        ExecStart = command;
        ExecReload = reload;
      };
    };
  };
  ordinary = evaluate {
    systemd.services.example.serviceConfig.ExecStart = command;
  };

  isolatedUnit = isolated.systemd.units."example.service".text;
  ordinaryUnit = ordinary.systemd.units."example.service".text;

  fails = declaration: !(builtins.tryEval (
    builtins.deepSeq (evaluate {
      systemd.services.example = declaration;
    }).systemd.units."example.service".text true
  )).success;

  checks = [
    (isolated.systemd.services.example.hostenv.network.isolated)
    (isolated.systemd.services.example.serviceConfig.ExecStart == command)
    (isolated.systemd.services.example.serviceConfig.NoNewPrivileges == true)
    (lib.hasInfix
      "ExecStart=${pkgs.util-linux}/bin/unshare --user --map-current-user --keep-caps --net "
      isolatedUnit)
    (lib.hasInfix " ${command}" isolatedUnit)
    (lib.hasInfix "ExecReload=${reload}" isolatedUnit)
    (lib.hasInfix "NoNewPrivileges=true" isolatedUnit)

    (!ordinary.systemd.services.example.hostenv.network.isolated)
    (lib.hasInfix "ExecStart=${command}" ordinaryUnit)
    (!(lib.hasInfix "/bin/unshare" ordinaryUnit))

    (fails { hostenv.network.isolated = true; })
    (fails {
      hostenv.network.isolated = true;
      serviceConfig.ExecStart = "-${pkgs.coreutils}/bin/sleep infinity";
    })
    (fails {
      hostenv.network.isolated = true;
      serviceConfig.ExecStart = [ command "${pkgs.coreutils}/bin/true" ];
    })
    (fails {
      hostenv.network.isolated = true;
      serviceConfig = { ExecStart = command; NoNewPrivileges = false; };
    })
  ];
in
assert lib.assertMsg (builtins.all (value: value) checks) "Private network service contract failed";
pkgs.runCommand "private-network-contracts" { } ''
  printf '%s\n' '${toString (builtins.length checks)} private network configuration assertions passed' > "$out"
''
