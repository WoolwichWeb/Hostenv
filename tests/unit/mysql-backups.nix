{ pkgs, hostenv }:
let
  lib = pkgs.lib;
  support = import ../support { inherit pkgs lib; };
  asserts = support.asserts;
  mysqlModule = hostenv.lib.hostenv.modules.mysql;

  eval = support.evalWithBase {
    modules = [
      mysqlModule
      ({ ... }: {
        hostenv = {
          userName = "mysqltest";
          stateDir = "/state";
          runtimeRoot = "/run/hostenv";
          runtimeDir = "/run/hostenv/user/mysqltest";
        };
        services.mysql = {
          enable = true;
          user = "mysqltest";
          package = pkgs.mariadb;
          backups.enable = true;
        };
      })
    ];
  };

  scripts = eval.config.services.mysql.backups.scripts;
  ok = scripts.full != null && scripts.incremental != null && scripts.restore != null;

in
{
  mysql-backup-scripts = asserts.assertTrue "mysql-backup-scripts" ok
    "mysql backup scripts should be available when backups are enabled";
}
