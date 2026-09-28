{ config, ... }:
let
  libHostenv = config.flake.lib.hostenv;
in
{
  flake.modules.hostenv.drupalCommon =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      cfg = config.services.drupal;
      mysqlPrograms = libHostenv.mysql.mkPrograms {
        inherit lib pkgs;
        package = config.services.mysql.package;
      };
      env = config.environments.${config.hostenv.environmentName};
      mkDefaultAttrs = lib.mapAttrs (_: lib.mkDefault);

      drupalGeneratorRegex = ''<meta[[:space:]]+name="Generator"[[:space:]]+content="Drupal [0-9]'';
      mkDrupalDeploymentVerification =
        envCfg:
        let
          drupalVerificationConstraints = [
            {
              rule = "allowNonZeroExitStatus";
              value = false;
            }
            {
              rule = "minHttpStatus";
              value = 200;
            }
            {
              rule = "maxHttpStatus";
              value = 299;
            }
            {
              rule = "stdoutRegexMustMatch";
              value = drupalGeneratorRegex;
            }
          ];
        in
        {
          enable = true;
          enforce = true;
          checks = [
            {
              name = "drupal-homepage";
              type = "httpHostHeaderCurl";
              request = {
                virtualHost = envCfg.canonicalHost;
                path = "/user/login";
                method = "GET";
                targetHostSource = "nodeConnectionHost";
                followRedirects = true;
                maxRedirects = 5;
                timeoutSeconds = 15;
                # Destination health verification may run before public DNS has
                # moved, while nixpkgs is intentionally serving its baseline
                # self-signed ACME certificate. Certificate trust is checked
                # separately after migration DNS cutover.
                tlsMode = "insecure";
              };
              constraints = drupalVerificationConstraints;
            }
          ];
        };
      migrateBackupName = "drupal-migrate";

    in
    {
      config = lib.mkIf cfg.enable {
        services.drupal.phpOptions = lib.mkBefore ''
          upload_max_filesize = ${cfg.maxRequestSize}
          post_max_size = ${cfg.maxRequestSize}
        '';

        assertions =
          (lib.optional cfg.backups.enable {
            assertion = config.services.mysql.backups.enable;
            message = "services.drupal.backups.enable requires services.mysql.backups.enable = true";
          })
          ++ (lib.optional
            (cfg.backups.enable && builtins.hasAttr migrateBackupName config.services.restic.backups)
            {
              assertion = lib.elem migrateBackupName (
                config.services.restic.backups.${migrateBackupName}.tags or [ ]
              );
              message = "services.restic.backups.drupal-migrate.tags must include \"drupal-migrate\" so migrations can locate snapshots";
            }
          );

        environments.${config.hostenv.environmentName}.deploymentVerification = lib.mkDefault (
          mkDrupalDeploymentVerification env
        );

        services.mysql.backups = lib.mkIf cfg.backups.enable {
          enable = lib.mkDefault true;
        };

        services.restic.backups = lib.mkIf cfg.backups.enable {
          drupal = {
            backupPrepareCommand = "${config.services.mysql.backups.scripts.full}/bin/mysql-backup-full";
            paths = [
              "${config.services.mysql.backups.backupDir}"
              "${cfg.filesDir}"
              "${cfg.privateFilesDir}"
            ];
            passwordFile = config.hostenv.backupsSecretFile;
            environmentFile = cfg.backups.restic.environmentFile;
            initialize = true;
            wantsUnits = [ "mysql.service" ];
            pruneOpts = [
              "--keep-daily 10"
              "--keep-weekly 5"
              "--keep-monthly 12"
              "--keep-yearly 75"
            ];
          };
          "${migrateBackupName}" = {
            timerConfig = null;
            backupPrepareCommand = "${config.services.mysql.backups.scripts.incremental}/bin/mysql-backup-incremental";
            paths = [
              "${config.services.mysql.backups.backupDir}"
              "${cfg.filesDir}"
              "${cfg.privateFilesDir}"
            ];
            passwordFile = config.hostenv.backupsSecretFile;
            environmentFile = cfg.backups.restic.environmentFile;
            initialize = true;
            createWrapper = lib.mkForce true;
            wantsUnits = [ "mysql.service" ];
            tags = [
              migrateBackupName
              "migrate"
            ];
          };
        };

        services.nginx.clientMaxBodySize = cfg.maxRequestSize;
        # Note: check drupal.nix and drupal6.nix for more version-specific
        # configuration, and each project's root directory.
        services.nginx.virtualHosts = {
          "${cfg.codebase.name}" = {
            serverName = lib.mkDefault "_";
            default = lib.mkDefault true;
            forceSSL = lib.mkDefault false;

            # Set up nginx for Drupal.
            locations."~ \\.php$|^/update.php" = {
              extraConfig = ''
                fastcgi_pass unix:${config.hostenv.runtimeDir}/${cfg.codebase.name}.sock;
                fastcgi_index index.php;

                fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
                # Ensure the php file exists. Mitigates CVE-2019-11043
                try_files $fastcgi_script_name =404;
                fastcgi_intercept_errors on;
              '';

              fastcgiParams = mkDefaultAttrs {
                # Block httpoxy attacks. See https://httpoxy.org/.
                HTTP_PROXY = "";
                SCRIPT_FILENAME = "$document_root$fastcgi_script_name";
                PATH_INFO = "$fastcgi_path_info";
                QUERY_STRING = "$query_string";
              };
            };
            locations."= /favicon.ico" = {
              extraConfig = ''
                log_not_found off;
                access_log off;
              '';
            };
            locations."= /robots.txt" = {
              extraConfig = ''
                allow all;
                log_not_found off;
                access_log off;
              '';
            };
            locations."~ \\..*/.*\\.php$" = {
              priority = lib.mkDefault 400;
              return = lib.mkDefault 403;
            };
            locations."~ ^/sites/.*/private/" = {
              priority = lib.mkDefault 405;
              return = lib.mkDefault 403;
            };
            locations."~ ^/sites/[^/]+/files/.*\\.php$" = {
              priority = lib.mkDefault 410;
              extraConfig = ''
                deny all;
              '';
            };
            locations."~ /vendor/.*\\.php$" = {
              priority = lib.mkDefault 420;
              return = lib.mkDefault 404;
              extraConfig = ''
                deny all;
              '';
            };
            locations."~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|avif|wasm)$" = {
              extraConfig = ''
                try_files $uri @rewrite;
                expires max;
                log_not_found off;
              '';
            };
            locations."= /build-ref.txt" = lib.mkIf (config.buildReference != null) {
              return = lib.mkDefault "200 '${config.buildReference}'";
            };

            listen = lib.mkDefault [ { addr = "unix:${config.hostenv.upstreamRuntimeDir}/in.sock"; } ];
          };
        };

        hostenv.cli.commands = {
          drush = {
            script = helpers: ''
              echo >&2
              echo "$hostenv_emoji  Running drush on '$hostenv_env_name' " >&2

              case "$force" in
                1)
                  drush_global_options="--no-interaction"
                  ;;
                *)
                  drush_global_options=""
                  ;;
              esac

              remote_drush=(drush)
              if [ -n "$drush_global_options" ]; then
                remote_drush+=("$drush_global_options")
              fi

              hostenv_ssh_exec "''${remote_drush[@]}" "$@"
            '';
            description = "Run Drush on the remote Drupal";
            executable = "drush";
            group = "Drupal";
            parsing = "passthrough";
            arguments = [
              {
                name = "arguments";
                description = "Arguments passed to Drush";
                variadic = true;
                completion = [ ];
              }
            ];
          };
        };

        activate = lib.optionalString cfg.backups.enable (
          lib.mkBefore ''
            # HOSTENV_RESTORE_DRUPAL_BEGIN
            restore_marker_dir="${config.hostenv.stateDir}/hostenv/restored"
            restore_marker="$restore_marker_dir/drupal"
            restore_plan="${config.hostenv.runtimeDir}/restore/plan.json"
            db_initialized=0
            restore_key="${migrateBackupName}"
            mysql_runtime_dir="${config.services.mysql.runtimeDir}"

            export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

            if [ -f "$restore_marker" ]; then
              db_initialized=1
            else
              mysql_sock="$mysql_runtime_dir/mysql.sock"
              if [ ! -S "$mysql_sock" ]; then
                if ${config.systemd.package}/bin/systemctl --user start mysql.service; then
                  for _ in $(seq 1 30); do
                    [ -S "$mysql_sock" ] && break
                    sleep 1
                  done
                fi
              fi

              if [ -S "$mysql_sock" ]; then
                table_count="$(${mysqlPrograms.client} -N -u ${config.hostenv.userName} \
                  --socket="$mysql_sock" \
                  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${cfg.databaseName}';" 2>/dev/null || echo 0)"
                if [ "''${table_count:-0}" -gt 0 ]; then
                  db_initialized=1
                fi
              fi
            fi

            if [ "$db_initialized" -eq 0 ] && [ ! -f "$restore_marker" ]; then
              if [ ! -f "$restore_plan" ]; then
                echo "hostenv: restore plan not found; skipping Drupal restore"
              else
                echo "hostenv: attempting Drupal restore"
                restore_snapshot="$(${pkgs.jq}/bin/jq -r '.snapshots["'"$restore_key"'"] // empty' "$restore_plan")"
                if [ -z "$restore_snapshot" ]; then
                  echo "hostenv: restore plan missing snapshot id for $restore_key" >&2
                  exit 1
                fi

                restore_tmp="$(mktemp -d)"
                restic_migrate="${
                  config.services.restic.wrapperScripts.${migrateBackupName}
                }/bin/restic-${migrateBackupName}"

                ${config.systemd.package}/bin/systemctl --user stop nginx.service || true
                ${config.systemd.package}/bin/systemctl --user stop phpfpm.target || true
                ${config.systemd.package}/bin/systemctl --user stop mysql.service || true

                if ! "$restic_migrate" restore "$restore_snapshot" --target "$restore_tmp"; then
                  echo "hostenv: restic restore failed" >&2
                  rm -rf "$restore_tmp"
                  exit 1
                fi

                restore_state_dir="$restore_tmp/${lib.removePrefix "/" config.services.mysql.backups.backupDir}"
                if ! ${config.services.mysql.backups.scripts.restore}/bin/mysql-backup-restore \
                  "$restore_state_dir" \
                  "${config.services.mysql.dataDir}"; then
                  echo "hostenv: mysql restore failed" >&2
                  rm -rf "$restore_tmp"
                  exit 1
                fi

                restore_files_dir="$restore_tmp/${lib.removePrefix "/" cfg.filesDir}"
                if [ -d "$restore_files_dir" ]; then
                  rm -rf "${cfg.filesDir}"
                  mkdir -p "${cfg.filesDir}"
                  if ! cp -a "$restore_files_dir/." "${cfg.filesDir}/"; then
                    echo "hostenv: failed to restore Drupal files directory" >&2
                    rm -rf "$restore_tmp"
                    exit 1
                  fi
                fi

                restore_private_dir="$restore_tmp/${lib.removePrefix "/" cfg.privateFilesDir}"
                if [ -d "$restore_private_dir" ]; then
                  rm -rf "${cfg.privateFilesDir}"
                  mkdir -p "${cfg.privateFilesDir}"
                  if ! cp -a "$restore_private_dir/." "${cfg.privateFilesDir}/"; then
                    echo "hostenv: failed to restore Drupal private files directory" >&2
                    rm -rf "$restore_tmp"
                    exit 1
                  fi
                fi

                ${config.systemd.package}/bin/systemctl --user start mysql.service || true
                for _ in $(seq 1 30); do
                  [ -S "$mysql_runtime_dir/mysql.sock" ] && break
                  sleep 1
                done
                if [ ! -S "$mysql_runtime_dir/mysql.sock" ]; then
                  echo "hostenv: mysql did not start after restore" >&2
                  rm -rf "$restore_tmp"
                  exit 1
                fi
                ${config.systemd.package}/bin/systemctl --user start phpfpm.target || true
                ${config.systemd.package}/bin/systemctl --user start nginx.service || true

                mkdir -p "$restore_marker_dir"
                touch "$restore_marker"
                rm -rf "$restore_tmp"
              fi
            fi
            if [ -f "$restore_plan" ]; then
              plan_tmp="$(mktemp)"
              if ${pkgs.jq}/bin/jq -e '(.snapshots // {}) | has("'"$restore_key"'")' "$restore_plan" >/dev/null; then
                ${pkgs.jq}/bin/jq 'del(.snapshots["'"$restore_key"'"])' "$restore_plan" > "$plan_tmp"
                if ${pkgs.jq}/bin/jq -e '(.snapshots // {}) | length == 0' "$plan_tmp" >/dev/null; then
                  rm -f "$restore_plan"
                else
                  mv "$plan_tmp" "$restore_plan"
                fi
              fi
              rm -f "$plan_tmp"
            fi
            # HOSTENV_RESTORE_DRUPAL_END
          ''
        );

        services.phpfpm.phpPackage = lib.mkDefault cfg.phpPackage;
        services.phpfpm.phpVersion = lib.mkDefault cfg.phpVersion;
        services.phpfpm.extensions = lib.mkDefault cfg.phpExtensions;
        services.phpfpm.disableExtensions = lib.mkDefault cfg.phpDisableExtensions;

        services.phpfpm.pools."${cfg.codebase.name}" = {
          phpOptions = cfg.phpOptions;
          extensions = cfg.phpExtensions;
          disableExtensions = cfg.phpDisableExtensions;

          settings = {
            "pm" = lib.mkDefault "dynamic";
            "pm.max_children" = lib.mkDefault 16;
            "pm.min_spare_servers" = lib.mkDefault 4;
            "pm.max_spare_servers" = lib.mkDefault 8;
            "pm.start_servers" = lib.mkDefault 4;
            "pm.max_requests" = lib.mkDefault 500;
            "php_admin_value[error_log]" = "stderr";
            "php_admin_flag[log_errors]" = true;
            "catch_workers_output" = true;
          };
        };

        # @todo: add support for PostgreSQL and/or sqlite.
        services.mysql = {
          enable = lib.mkDefault true;
          package = lib.mkDefault pkgs.mariadb;
          user = config.hostenv.userName;
          dataDir = "${config.hostenv.dataDir}/mysql";

          initialDatabases = [
            { name = cfg.databaseName; }
          ];
          ensureDatabases = [ cfg.databaseName ];

          ensureUsers = [
            {
              name = config.hostenv.userName;
              ensurePermissions = {
                "${cfg.databaseName}.*" = "ALL PRIVILEGES";
              };
            }
            {
              name = "backup";
              ensurePermissions = {
                "*.*" = "SELECT, LOCK TABLES";
              };
            }
          ];

          # Replication enables the binary logging, which gets us
          # point-in-time restore in case anything goes wrong. However,
          # replication to another host is not setup yet.
          replication = lib.mkDefault {
            # Note on MariaDB 11.4+, there is a replication bug that can
            # result in MariaDB filling all available disk space.
            # We work around this in:
            # flake.modules.hostenv.mysql.settings.mysqld
            # See that module for details.
            role = "master";
            masterUser = "replication_primary";
            # While we skip-networking and only listen on a socket,
            # this isn't a concern.
            masterPassword = "";
            # @todo:
            slaveHost = "localhost";
          };

          # @todo: sensible defaults that scale according to available resources.
          settings = {
            mysqld = {
              max_connections = lib.mkDefault 1000;
              table_cache = lib.mkDefault 800;
              skip-networking = lib.mkDefault true;
              max_allowed_packet = lib.mkDefault "256M";
              tmp_table_size = lib.mkDefault "32M";
              max_heap_table_size = lib.mkDefault "32M";
              query_cache_size = lib.mkDefault "128M";
              query_cache_limit = lib.mkDefault "8M";
              # This is recommended by Drupal, so make it read-only (unless
              # or until there's a good reason to allow users to change it).
              transaction_isolation = "READ-COMMITTED";

              innodb_buffer_pool_size = lib.mkDefault "10G";
              innodb_buffer_pool_size_max = lib.mkDefault "10G";
              innodb_log_buffer_size = lib.mkDefault "16M";
              innodb_log_file_size = lib.mkDefault "128M";
              innodb_flush_method = lib.mkDefault "O_DIRECT";
              innodb_stats_on_metadata = lib.mkDefault false;
            };
            mysqldump = {
              quick = true;
              max_allowed_packet = lib.mkDefault "128M";
            };
          };

        };
      };
    };
}
