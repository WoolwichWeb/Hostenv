{ pkgs, hostenv }:
let
  lib = pkgs.lib;
  asserts = (import ../support { inherit pkgs lib; }).asserts;
  mysqlLib = hostenv.lib.hostenv.mysql;

  mariadbPrograms = mysqlLib.mkPrograms {
    inherit lib pkgs;
    package = pkgs.mariadb;
  };
  mysqlPrograms = mysqlLib.mkPrograms {
    inherit lib pkgs;
    package = pkgs.mysql84;
  };

  mariadbCanonical =
    mariadbPrograms.isMariaDB
    && mariadbPrograms.client == lib.getExe' pkgs.mariadb "mariadb"
    && mariadbPrograms.dump == lib.getExe' pkgs.mariadb "mariadb-dump"
    && mariadbPrograms.server == lib.getExe' pkgs.mariadb "mariadbd"
    && mariadbPrograms.installDb == lib.getExe' pkgs.mariadb "mariadb-install-db";

  mysqlCanonical =
    !mysqlPrograms.isMariaDB
    && mysqlPrograms.client == lib.getExe' pkgs.mysql84 "mysql"
    && mysqlPrograms.dump == lib.getExe' pkgs.mysql84 "mysqldump"
    && mysqlPrograms.server == lib.getExe' pkgs.mysql84 "mysqld"
    && mysqlPrograms.installDb == null;
in
{
  mysql-programs-use-canonical-executables =
    asserts.assertTrue "mysql-programs-use-canonical-executables" (mariadbCanonical && mysqlCanonical)
      "MySQL program resolution should use canonical MariaDB names without changing Oracle MySQL names";
}
