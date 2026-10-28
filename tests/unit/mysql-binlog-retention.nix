{ pkgs, hostenv }:
let
  lib = pkgs.lib;
  support = import ../support { inherit pkgs lib; };
  asserts = support.asserts;
  mysqlModule = hostenv.lib.hostenv.modules.mysql;

  eval =
    package:
    support.evalWithBase {
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
            inherit package;
            replication = {
              role = "master";
              serverId = 1;
              masterHost = "primary.invalid";
              slaveHost = "replica.invalid";
              masterUser = "replication";
              masterPassword = "";
            };
          };
        })
      ];
    };

  mariadbSettings = (eval pkgs.mariadb).config.services.mysql.settings.mysqld;
  mysqlSettings = (eval pkgs.mysql84).config.services.mysql.settings.mysqld;
in
{
  mysql-mariadb-binlog-expiry-does-not-wait-for-replica =
    asserts.assertTrue
      "mysql-mariadb-binlog-expiry-does-not-wait-for-replica"
      (
        mariadbSettings.expire_logs_days == "5"
        && mariadbSettings.binlog_expire_logs_seconds == "432000"
        && mariadbSettings.slave_connections_needed_for_purge == 0
      )
      "MariaDB replication/PITR mode should purge expired binlogs without requiring a replica connection";

  mysql-oracle-does-not-set-mariadb-purge-option =
    asserts.assertTrue
      "mysql-oracle-does-not-set-mariadb-purge-option"
      (!(mysqlSettings ? slave_connections_needed_for_purge))
      "Oracle MySQL should not receive MariaDB-only slave_connections_needed_for_purge";
}
