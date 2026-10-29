{ pkgs, env }:

let
  lib = pkgs.lib;
  cfg = env.config;
  defaultPackages = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    cfg.systemd.package
  ];
  unitNames = [
    "mysql"
    "postgresql"
    "phpfpm-smoke"
    "nginx"
  ];
  hasPackages = path: packages:
    let paths = map toString path;
    in lib.all (package: lib.elem (toString package) paths) packages;
  missingDefaults =
    lib.filter (unit: !(hasPackages cfg.systemd.services.${unit}.path defaultPackages)) unitNames;
  mysqlPath = cfg.systemd.services.mysql.path;
in

assert lib.assertMsg (hasPackages cfg.systemd.defaultPath defaultPackages)
  "Hostenv's systemd.defaultPath is missing common service utilities";
assert lib.assertMsg (missingDefaults == [ ])
  "Hostenv services are missing systemd.defaultPath: ${lib.concatStringsSep ", " missingDefaults}";
assert lib.assertMsg (hasPackages mysqlPath [ pkgs.nettools ])
  "The MySQL service lost its additional nettools package";

pkgs.runCommand "systemd-service-path" {
  servicePath = lib.makeBinPath mysqlPath;
} ''
  export PATH="$servicePath"
  for command in mkdir hostname find grep sed systemctl; do
    command -v "$command" >/dev/null
  done
  mkdir -p "$TMPDIR/path-check"
  test -d "$TMPDIR/path-check"
  touch "$out"
''
