{ pkgs, makeHostenv }:
let
  lib = pkgs.lib;
  # Unlike lib.hasInfix, replaceStrings does not construct a regular
  # expression, which cannot contain Nix store-path string context.
  contains = needle: haystack:
    builtins.replaceStrings [ needle ] [ "" ] haystack != haystack;

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
  # A service that does not request isolation must retain its existing
  # serviceConfig defaults, even when the entire set is defined with mkDefault.
  wholeServiceDefaults = lib.mkDefault {
    Type = "oneshot";
    ExecStart = command;
  };
  ordinary = evaluate {
    systemd.services.example.serviceConfig = wholeServiceDefaults;
  };
  # When another module adds serviceConfig settings, set defaults on each
  # field so those settings can merge independently.
  isolatedWithDefaults = evaluate {
    systemd.services.example = {
      hostenv.network.isolated = true;
      serviceConfig = {
        Type = lib.mkDefault "oneshot";
        ExecStart = lib.mkDefault command;
      };
    };
  };

  isolatedUnit = isolated.systemd.units."example.service".text;
  ordinaryUnit = ordinary.systemd.units."example.service".text;
  isolatedWithDefaultsUnit = isolatedWithDefaults.systemd.units."example.service".text;

  fails = declaration: !(builtins.tryEval (
    builtins.deepSeq (evaluate {
      systemd.services.example = declaration;
    }).systemd.units."example.service".text true
  )).success;

  checks = [
    (isolated.systemd.services.example.hostenv.network.isolated)
    (isolated.systemd.services.example.serviceConfig.ExecStart == command)
    (isolated.systemd.services.example.serviceConfig.NoNewPrivileges == true)
    (contains
      "ExecStart=${pkgs.util-linux}/bin/unshare --user --map-current-user --keep-caps --net "
      isolatedUnit)
    (contains " ${command}" isolatedUnit)
    (contains "ExecReload=${reload}" isolatedUnit)
    (contains "NoNewPrivileges=true" isolatedUnit)

    (!ordinary.systemd.services.example.hostenv.network.isolated)
    (ordinary.systemd.services.example.serviceConfig.Type == "oneshot")
    (ordinary.systemd.services.example.serviceConfig.ExecStart == command)
    (contains "Type=oneshot" ordinaryUnit)
    (contains "ExecStart=${command}" ordinaryUnit)
    (!(contains "/bin/unshare" ordinaryUnit))

    (isolatedWithDefaults.systemd.services.example.hostenv.network.isolated)
    (isolatedWithDefaults.systemd.services.example.serviceConfig.ExecStart == command)
    (isolatedWithDefaults.systemd.services.example.serviceConfig.NoNewPrivileges == true)
    (contains "Type=oneshot" isolatedWithDefaultsUnit)
    (contains "NoNewPrivileges=true" isolatedWithDefaultsUnit)
    (contains
      "ExecStart=${pkgs.util-linux}/bin/unshare --user --map-current-user --keep-caps --net "
      isolatedWithDefaultsUnit)
    (contains " ${command}" isolatedWithDefaultsUnit)

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
      serviceConfig.ExecStart = "${command} ; ${pkgs.coreutils}/bin/true";
    })
    (fails {
      hostenv.network.isolated = true;
      serviceConfig = { ExecStart = command; NoNewPrivileges = false; };
    })
    (fails {
      hostenv.network.isolated = true;
      serviceConfig = {
        ExecStart = command;
        NoNewPrivileges = lib.mkForce false;
      };
    })
  ];
in
assert lib.assertMsg (builtins.all (value: value) checks) "Private network service contract failed";
pkgs.runCommand "private-network-contracts" { } ''
  printf '%s\n' '${toString (builtins.length checks)} private network configuration assertions passed' > "$out"
''
