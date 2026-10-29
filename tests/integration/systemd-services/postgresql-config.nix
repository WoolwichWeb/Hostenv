{ pkgs, env }:

let
  cfg = env.config.services.postgresql;
in
assert pkgs.lib.assertMsg (cfg.settings.unix_socket_permissions == "0770")
  "PostgreSQL socket permissions must be represented as an octal string";
pkgs.runCommand "postgresql-socket-permissions" { } ''
  grep -Fxq "unix_socket_permissions = '0770'" ${cfg.configFile}
  touch "$out"
''
