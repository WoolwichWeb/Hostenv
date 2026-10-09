{ pkgs, makeHostenv }:
let
  lib = pkgs.lib;
  support = import ../support { inherit pkgs lib; };
  asserts = support.asserts;

  env = makeHostenv [
    ({ ... }: {
      hostenv = {
        organisation = "org";
        project = "proj";
        hostenvHostname = "hosting.test";
        root = "/srv/php-app";
      };
      defaultEnvironment = "main";
      environments.main = {
        enable = true;
        type = "development";
        hostenv.userName = "phpapp-main";
        hostenv.hostname = "phpapp-main.hosting.test";
        virtualHosts = { };
      };
      services.php-app = {
        enable = true;
        backups.enable = true;
      };
    })
  ] "main";

  backups = env.config.services.restic.backups;
  phpErrorLog =
    env.config.services.phpfpm.pools.${env.config.services.php-app.codebase.name}.settings."php_admin_value[error_log]";
  hasMigrate = backups ? "php-app-migrate" && (backups."php-app-migrate".timerConfig or "") == null;
  hasMarker = lib.strings.hasInfix "HOSTENV_RESTORE_PHP_APP_BEGIN" env.config.activate;
  hasRestorePlanPath = lib.strings.hasInfix "${env.config.hostenv.runtimeDir}/restore/plan.json" env.config.activate;
  hasPlanCleanup = lib.strings.hasInfix "del(.snapshots[" env.config.activate
    && lib.strings.hasInfix "restore_key=\"php-app-migrate\"" env.config.activate;

in
{
  php-app-error-log-syslog = asserts.assertTrue "php-app-error-log-syslog" (phpErrorLog == "syslog")
    "php-app should send PHP errors to syslog";
  php-app-migrate-backup = asserts.assertTrue "php-app-migrate-backup" hasMigrate
    "php-app should define a migrate restic backup without a timer";
  php-app-restore-marker = asserts.assertTrue "php-app-restore-marker" hasMarker
    "php-app activation should include restore marker";
  php-app-restore-plan-path = asserts.assertTrue "php-app-restore-plan-path" hasRestorePlanPath
    "php-app activation should read restore plan from runtimeDir/restore/plan.json";
  php-app-restore-plan-cleanup = asserts.assertTrue "php-app-restore-plan-cleanup" hasPlanCleanup
    "php-app activation should remove php-app-migrate from restore plan after restoring";
}
