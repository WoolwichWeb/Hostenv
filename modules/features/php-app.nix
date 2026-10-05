{ config, ... }:
let
  libHostenv = config.flake.lib.hostenv;
in
{
  flake.modules.hostenv.php-app =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      cfg = config.services.php-app;
      mysqlPrograms = libHostenv.mysql.mkPrograms {
        inherit lib pkgs;
        package = config.services.mysql.package;
      };
      migrateBackupName = "php-app-migrate";
    in
    {
      options.services.php-app = {
        enable = lib.mkEnableOption ''
          support for a simple PHP application + db.
                    Enabling this will bring up an nginx, PHP-FPM, and MySQL.
        '';

        codebase = {
          name = lib.mkOption {
            type = lib.types.str;
            description = ''
              Name of the codebase. Used to identify the service in various
              configuration, e.g. nginx, systemd services.
              May be any alphanumeric name, just ensure it only contains letters
              and numbers to avoid confusing errors when starting services.
            '';
            default = config.hostenv.userName + "-application";
            defaultText = lib.literalExpression ''
              config.hostenv.userName + "-application"
            '';
          };

          version = lib.mkOption {
            type = lib.types.str;
            default = "1.0.0-dev";
            description = "Optional. Define a version number, will be used when generating directory names and such.";
          };
        };

        backups = {
          enable = lib.mkEnableOption "default database backups stored in Restic on S3.";
          restic = {
            environmentFile = lib.mkOption {
              type = lib.types.str;
              default = "/run/secrets/${config.hostenv.userName}/backups_env";
              description = ''
                Location of file containing environment variables for Restic.

                Contains sensitive credentials that shouldn't be in the Nix store. For example, backups stored on Amazon S3 require an access key and secret access key.
              '';
            };
          };
        };
      };

      config = lib.mkIf cfg.enable {
        assertions =
          (lib.optional cfg.backups.enable {
            assertion = config.services.mysql.backups.enable;
            message = "services.php-app.backups.enable requires services.mysql.backups.enable = true";
          })
          ++ (lib.optional
            (cfg.backups.enable && builtins.hasAttr migrateBackupName config.services.restic.backups)
            {
              assertion = lib.elem migrateBackupName (
                config.services.restic.backups.${migrateBackupName}.tags or [ ]
              );
              message = "services.restic.backups.php-app-migrate.tags must include \"php-app-migrate\" so Hostenv can find migration snapshots";
            }
          );

        services.nginx.virtualHosts = {
          "${cfg.codebase.name}" = lib.mkDefault {
            serverName = "_";
            default = true;
            forceSSL = false;
            root = config.hostenv.root;

            locations."@rewrite" = {
              extraConfig = ''
                rewrite ^ /index.php;
              '';
            };

            locations."/" = {
              extraConfig = ''
                try_files $uri /index.php?$query_string;
              '';
            };

            # Set up nginx for Drupal.
            locations."~ '\.php$'" = {
              extraConfig = ''
                fastcgi_pass unix:${config.hostenv.runtimeDir}/${cfg.codebase.name}.sock;
                fastcgi_index index.php;

                fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
                # Ensure the php file exists. Mitigates CVE-2019-11043
                try_files $fastcgi_script_name =404;
                fastcgi_intercept_errors on;
              '';

              fastcgiParams = {
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
            locations."~ \..*/.*\.php$" = {
              return = 403;
            };
            locations."~ /vendor/.*\.php$" = {
              return = 404;
              extraConfig = ''
                deny all;
              '';
            };
            locations."~* \.(js|css|png|jpg|jpeg|gif|ico|svg|avif|wasm)$" = {
              extraConfig = ''
                try_files $uri @rewrite;
                expires max;
                log_not_found off;
              '';
            };

            listen = [ { addr = "unix:${config.hostenv.upstreamRuntimeDir}/in.sock"; } ];
          };
        };

        services.phpfpm.pools."${cfg.codebase.name}" = {
          phpOptions = lib.mkDefault ''
            upload_max_filesize = 1G
            post_max_size = 1G
            memory_limit = 512M
            error_log = syslog
            syslog.ident = php
            syslog.facility = user
          '';

          settings = {
            "pm" = lib.mkDefault "dynamic";
            "pm.max_children" = lib.mkDefault 16;
            "pm.min_spare_servers" = lib.mkDefault 4;
            "pm.max_spare_servers" = lib.mkDefault 8;
            "pm.start_servers" = lib.mkDefault 4;
            "pm.max_requests" = lib.mkDefault 500;
            "php_admin_value[error_log]" = "/proc/self/fd/2";
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
            { name = "app"; }
          ];

          ensureUsers = [
            {
              name = config.hostenv.userName;
              ensurePermissions = {
                "app.*" = "ALL PRIVILEGES";
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

        services.mysql.backups = lib.mkIf cfg.backups.enable {
          enable = lib.mkDefault true;
        };

        services.restic.backups = lib.mkIf cfg.backups.enable {
          php-app = {
            backupPrepareCommand = "${config.services.mysql.backups.scripts.full}/bin/mysql-backup-full";
            paths = [
              "${config.services.mysql.backups.backupDir}"
            ];
            passwordFile = config.hostenv.backupsSecretFile;
            environmentFile = cfg.backups.restic.environmentFile;
            initialize = true;
            wantsUnits = [ "mysql.service" ];
          };
          "${migrateBackupName}" = {
            timerConfig = null;
            backupPrepareCommand = "${config.services.mysql.backups.scripts.incremental}/bin/mysql-backup-incremental";
            paths = [
              "${config.services.mysql.backups.backupDir}"
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

        activate = lib.optionalString cfg.backups.enable ''
          # HOSTENV_RESTORE_PHP_APP_BEGIN
          restore_marker_dir="${config.hostenv.stateDir}/hostenv/restored"
          restore_marker="$restore_marker_dir/php-app"
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
              ${config.systemd.package}/bin/systemctl --user start mysql.service || true
              for _ in $(seq 1 30); do
                [ -S "$mysql_sock" ] && break
                sleep 1
              done
            fi

            if [ -S "$mysql_sock" ]; then
              table_count="$(${mysqlPrograms.client} -N -u ${config.hostenv.userName} \
                --socket="$mysql_sock" \
                -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='app';" 2>/dev/null || echo 0)"
              if [ "''${table_count:-0}" -gt 0 ]; then
                db_initialized=1
              fi
            fi
          fi

          if [ "$db_initialized" -eq 0 ] && [ ! -f "$restore_marker" ]; then
            if [ ! -f "$restore_plan" ]; then
              echo "No migration restore plan found; skipping the PHP application restore."
            else
              echo "Restoring the PHP application database."
              restore_snapshot="$(${pkgs.jq}/bin/jq -r '.snapshots["'"$restore_key"'"] // empty' "$restore_plan")"
              if [ -z "$restore_snapshot" ]; then
                echo "Migration restore plan has no snapshot for $restore_key." >&2
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
                echo "Restic restore failed" >&2
                rm -rf "$restore_tmp"
                exit 1
              fi

              restore_state_dir="$restore_tmp/${lib.removePrefix "/" config.services.mysql.backups.backupDir}"
              if ! ${config.services.mysql.backups.scripts.restore}/bin/mysql-backup-restore \
                "$restore_state_dir" \
                "${config.services.mysql.dataDir}"; then
                echo "MariaDB restore failed" >&2
                rm -rf "$restore_tmp"
                exit 1
              fi

              ${config.systemd.package}/bin/systemctl --user start mysql.service || true
              for _ in $(seq 1 30); do
                [ -S "$mysql_runtime_dir/mysql.sock" ] && break
                sleep 1
              done
              if [ ! -S "$mysql_runtime_dir/mysql.sock" ]; then
                echo "MariaDB did not start after the restore" >&2
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
          # HOSTENV_RESTORE_PHP_APP_END
        '';
      };
    };
}
