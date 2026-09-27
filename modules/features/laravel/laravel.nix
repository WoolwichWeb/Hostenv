{ config, ... }:
let
  libHostenv = config.flake.lib.hostenv;
in
{
  flake.modules.hostenv.laravel =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      cfg = config.services.laravel;
      mysqlPrograms = libHostenv.mysql.mkPrograms {
        inherit lib pkgs;
        package = config.services.mysql.package;
      };
      env = config.environments.${config.hostenv.environmentName};
      secretFile = "/run/secrets/${config.hostenv.userName}/laravel_env";
      migrateBackupName = "laravel-migrate";
      laravelPhpPool = config.services.phpfpm.pools.${cfg.codebase.name};

      canonicalUri =
        (if env.virtualHosts.${env.canonicalHost}.enableLetsEncrypt then "https://" else "http://")
        + env.canonicalHost;

      dotenvEscape =
        value: "\"${builtins.replaceStrings [ "\\" "\"" "$" ] [ "\\\\" "\\\"" "\\$" ] value}\"";
      generatedEnvironment = {
        APP_ENV = env.type;
        APP_DEBUG = if env.type == "production" then "false" else "true";
        APP_URL = canonicalUri;
        LOG_CHANNEL = "stderr";
        DB_CONNECTION = "mysql";
        DB_HOST = "localhost";
        DB_PORT = "3306";
        DB_SOCKET = "${config.hostenv.runtimeDir}/mysql.sock";
        DB_DATABASE = cfg.databaseName;
        DB_USERNAME = config.hostenv.userName;
        DB_PASSWORD = "";
      }
      // lib.optionalAttrs cfg.redis.enable {
        REDIS_CLIENT = "phpredis";
        REDIS_HOST = config.services.redis.socket;
        REDIS_PORT = "0";
      }
      // cfg.environmentVariables;
      generatedEnvFile = pkgs.writeText "laravel.env" (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: value: "${name}=${dotenvEscape value}") generatedEnvironment
        )
        + "\n"
      );

      cleanProjectSource = lib.cleanSourceWith {
        src = config.hostenv.root;
        filter =
          path: _type:
          let
            fileName = baseNameOf path;
          in
          fileName != ".env" && !(lib.hasPrefix ".env." fileName);
      };

      composerProject = laravelPhpPool.effectivePhpCliPackage.buildComposerProject2 (finalAttrs: {
        pname = cfg.codebase.name;
        version = cfg.codebase.version;
        src = cleanProjectSource;
        composerLock = config.hostenv.root + /composer.lock;
        vendorHash = cfg.composer.dependencyHash;
        composerNoPlugins = !cfg.composer.enablePlugins;
        composerNoScripts = !cfg.composer.enableScripts;
        composerNoDev = !cfg.composer.enableDev;
      });

      project = pkgs.stdenvNoCC.mkDerivation {
        pname = cfg.codebase.name;
        version = cfg.codebase.version;
        src = cleanProjectSource;
        dontPatchShebangs = true;

        buildPhase = ''
          runHook preBuild

          ${lib.optionalString cfg.composer.enable ''
            cp -a ${composerProject}/share/php/${cfg.codebase.name}/. .
            chmod -R u+w .
          ''}

          rm -f .env .env.local
          install -m 0444 ${generatedEnvFile} .env

          if [ -d storage ] && [ ! -L storage ]; then
            mv storage .hostenv-initial-storage
          else
            mkdir -p .hostenv-initial-storage
          fi
          rm -rf storage
          ln -s ${lib.escapeShellArg cfg.storageDir} storage

          mkdir -p bootstrap
          rm -rf bootstrap/cache
          ln -s ${lib.escapeShellArg cfg.bootstrapCacheDir} bootstrap/cache

          ${lib.optionalString (cfg.assets.package != null) ''
            mkdir -p public
            cp -a ${cfg.assets.package}/. public/
          ''}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/php/${cfg.codebase.name}
          cp -a . $out/share/php/${cfg.codebase.name}/
          runHook postInstall
        '';
      };

      rootDir = "${project}/share/php/${cfg.codebase.name}";
      artisan = pkgs.writeShellScriptBin "artisan" ''
        set -euo pipefail

        secret_file=${lib.escapeShellArg secretFile}
        if [ ! -r "$secret_file" ]; then
          echo "hostenv: Laravel requires a readable secret environment file at $secret_file" >&2
          echo "hostenv: configure the provider SOPS key 'laravel_env' for this environment, project, or organisation" >&2
          exit 1
        fi

        set -a
        # The provider contract deliberately uses the shell/systemd-compatible
        # KEY=value subset, so every value is exported without dotenv parsing.
        . "$secret_file"
        set +a

        ${lib.optionalString (config.packages != [ ]) ''
          # laravel_env may extend or replace PATH, but it must not be able to
          # hide runtime dependencies declared through top-level `packages`.
          export PATH=${lib.escapeShellArg (lib.makeBinPath config.packages)}:"$PATH"
        ''}

        cd ${lib.escapeShellArg rootDir}
        exec ${laravelPhpPool.effectivePhpCliPackage}/bin/php artisan "$@"
      '';

      composer = pkgs.buildEnv {
        name = "composer";
        paths = [ laravelPhpPool.effectivePhpCliPackage.packages.composer ];
        pathsToLink = [ "/bin" ];
      };

      mkLaravelDeploymentVerification =
        envCfg:
        {
          enable = true;
          enforce = true;
          checks = [
            {
              name = "laravel-health";
              type = "httpHostHeaderCurl";
              request = {
                virtualHost = envCfg.canonicalHost;
                path = cfg.healthCheckPath;
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
              constraints = [
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
              ];
            }
          ];
        };

      workerServices = lib.concatMapAttrs (
        workerName: worker:
        builtins.listToAttrs (
          map (
            processNumber:
            let
              args = [
                "queue:work"
              ]
              ++ lib.optional (worker.connection != null) worker.connection
              ++ lib.optional (worker.queues != [ ]) "--queue=${lib.concatStringsSep "," worker.queues}"
              ++ [
                "--sleep=${toString worker.sleep}"
                "--timeout=${toString worker.timeout}"
                "--max-time=${toString worker.maxLifetime}"
                "--no-interaction"
              ]
              ++ lib.optional (worker.tries != null) "--tries=${toString worker.tries}";
            in
            {
              name = "laravel-queue-${workerName}-${toString processNumber}";
              value = {
                description = "Laravel queue worker ${workerName} (${toString processNumber}/${toString worker.processes})";
                wantedBy = [ "laravel-queue.target" ];
                partOf = [ "laravel-queue.target" ];
                wants = [
                  "network-online.target"
                  "mysql.service"
                ]
                ++ lib.optional cfg.redis.enable "redis.service";
                after = [
                  "network-online.target"
                  "mysql.service"
                ]
                ++ lib.optional cfg.redis.enable "redis.service";
                path = config.packages;
                serviceConfig = {
                  ExecStart = "${artisan}/bin/artisan ${lib.escapeShellArgs args}";
                  EnvironmentFile = secretFile;
                  Restart = "always";
                  RestartSec = "5s";
                  KillSignal = "SIGTERM";
                  TimeoutStopSec = toString worker.stopTimeout;
                };
              };
            }
          ) (lib.range 1 worker.processes)
        )
      ) cfg.queue.workers;

      mysqlDefaults = {
        enable = lib.mkDefault true;
        package = lib.mkDefault pkgs.mariadb;
        user = config.hostenv.userName;
        dataDir = "${config.hostenv.dataDir}/mysql";
        initialDatabases = [ { name = cfg.databaseName; } ];
        ensureDatabases = [ cfg.databaseName ];

        ensureUsers = [
          {
            name = config.hostenv.userName;
            ensurePermissions."${cfg.databaseName}.*" = "ALL PRIVILEGES";
          }
          {
            name = "backup";
            ensurePermissions."*.*" = "SELECT, LOCK TABLES";
          }
        ];

        # Enable replication so we get point in time restore.
        # Note on MariaDB 11.4+, there is a replication bug that can
        # result in MariaDB filling all available disk space.
        # We work around this in:
        # flake.modules.hostenv.mysql.settings.mysqld
        # See that module for details.
        replication = lib.mkDefault {
          role = "master";
          masterUser = "replication_primary";
          masterPassword = "";
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
            transaction_isolation = "READ-COMMITTED";
            innodb_buffer_pool_size = lib.mkDefault "1G";
            innodb_buffer_pool_size_max = lib.mkDefault "1G";
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

      restoreScript = ''
        # HOSTENV_RESTORE_LARAVEL_BEGIN
        restore_marker_dir="${config.hostenv.stateDir}/hostenv/restored"
        restore_marker="$restore_marker_dir/laravel"
        restore_plan="${config.hostenv.runtimeDir}/restore/plan.json"
        restore_key="${migrateBackupName}"
        mysql_runtime_dir="${config.services.mysql.runtimeDir}"
        mysql_sock="$mysql_runtime_dir/mysql.sock"
        db_initialized=0

        export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

        if [ -f "$restore_marker" ]; then
          db_initialized=1
        else
          if [ ! -S "$mysql_sock" ]; then
            ${config.systemd.package}/bin/systemctl --user start mysql.service || true
            for _ in $(seq 1 30); do
              [ -S "$mysql_sock" ] && break
              sleep 1
            done
          fi

          if [ -S "$mysql_sock" ]; then
            table_count="$(${mysqlPrograms.client} -N -u ${lib.escapeShellArg config.hostenv.userName} \
              --socket="$mysql_sock" \
              -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${cfg.databaseName}';" 2>/dev/null || echo 0)"
            if [ "''${table_count:-0}" -gt 0 ]; then
              db_initialized=1
            fi
          fi
        fi

        if [ "$db_initialized" -eq 0 ] && [ ! -f "$restore_marker" ] && [ -f "$restore_plan" ]; then
          restore_snapshot="$(${pkgs.jq}/bin/jq -r '.snapshots["'"$restore_key"'"] // empty' "$restore_plan")"
          if [ -z "$restore_snapshot" ]; then
            echo "hostenv: restore plan missing snapshot id for $restore_key" >&2
            exit 1
          fi

          echo "hostenv: restoring Laravel database and storage"
          restore_tmp="$(mktemp -d)"
          restic_migrate="${
            config.services.restic.wrapperScripts.${migrateBackupName}
          }/bin/restic-${migrateBackupName}"

          ${config.systemd.package}/bin/systemctl --user stop laravel-queue.target || true
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
            echo "hostenv: MariaDB restore failed" >&2
            rm -rf "$restore_tmp"
            exit 1
          fi

          restore_storage_dir="$restore_tmp/${lib.removePrefix "/" cfg.storageDir}"
          if [ -d "$restore_storage_dir" ]; then
            rm -rf ${lib.escapeShellArg cfg.storageDir}
            mkdir -p ${lib.escapeShellArg cfg.storageDir}
            if ! cp -a "$restore_storage_dir/." ${lib.escapeShellArg cfg.storageDir}/; then
              echo "hostenv: Laravel storage restore failed" >&2
              rm -rf "$restore_tmp"
              exit 1
            fi
          fi

          mkdir -p "$restore_marker_dir"
          touch "$restore_marker"
          rm -rf "$restore_tmp"
        elif [ "$db_initialized" -eq 0 ] && [ ! -f "$restore_plan" ]; then
          echo "hostenv: restore plan not found; starting Laravel with an empty database"
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
        # HOSTENV_RESTORE_LARAVEL_END
      '';
    in
    {
      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = lib.hasPrefix "/" cfg.storageDir;
            message = "services.laravel.storageDir must be an absolute path";
          }
          {
            assertion = lib.hasPrefix "/" cfg.bootstrapCacheDir;
            message = "services.laravel.bootstrapCacheDir must be an absolute path";
          }
          {
            assertion = builtins.all (name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null) (
              builtins.attrNames cfg.environmentVariables
            );
            message = "services.laravel.environmentVariables names must match [A-Za-z_][A-Za-z0-9_]*";
          }
          {
            assertion = builtins.all (name: builtins.match "[A-Za-z0-9_-]+" name != null) (
              builtins.attrNames cfg.queue.workers
            );
            message = "services.laravel.queue.workers names must match [A-Za-z0-9_-]+";
          }
        ]
        ++ lib.optional cfg.composer.enable {
          assertion = builtins.pathExists (config.hostenv.root + /composer.lock);
          message = "services.laravel.composer.enable requires composer.lock in hostenv.root";
        }
        ++ lib.optional cfg.redis.enable {
          assertion = config.services.redis.enable;
          message = "services.laravel.redis.enable requires services.redis.enable = true";
        }
        ++ lib.optional cfg.backups.enable {
          assertion = config.services.mysql.backups.enable;
          message = "services.laravel.backups.enable requires services.mysql.backups.enable = true";
        }
        ++
          lib.optional
            (cfg.backups.enable && builtins.hasAttr migrateBackupName config.services.restic.backups)
            {
              assertion = lib.elem migrateBackupName (
                config.services.restic.backups.${migrateBackupName}.tags or [ ]
              );
              message = "services.restic.backups.laravel-migrate.tags must include \"laravel-migrate\"";
            };

        services.laravel.phpOptions = lib.mkBefore ''
          upload_max_filesize = ${cfg.maxRequestSize}
          post_max_size = ${cfg.maxRequestSize}
        '';

        environments.${config.hostenv.environmentName} = {
          requiredSecretFiles = [ "laravel_env" ];
          deploymentVerification = lib.mkDefault (mkLaravelDeploymentVerification env);
        };

        services.nginx = {
          clientMaxBodySize = cfg.maxRequestSize;
          virtualHosts.${cfg.codebase.name} = {
            serverName = lib.mkDefault "_";
            default = lib.mkDefault true;
            forceSSL = lib.mkDefault false;
            root = lib.mkDefault "${rootDir}/public";
            listen = lib.mkDefault [ { addr = "unix:${config.hostenv.upstreamRuntimeDir}/in.sock"; } ];

            locations."/" = {
              index = lib.mkDefault "index.php";
              tryFiles = lib.mkDefault "$uri $uri/ /index.php?$query_string";
            };

            locations."= /index.php" = {
              priority = 100;
              extraConfig = ''
                try_files $uri =404;
                fastcgi_pass unix:${config.hostenv.runtimeDir}/${cfg.codebase.name}.sock;
                fastcgi_index index.php;
                fastcgi_intercept_errors on;
              '';
              fastcgiParams = {
                HTTP_PROXY = "";
                SCRIPT_FILENAME = "$document_root$fastcgi_script_name";
                DOCUMENT_ROOT = "$document_root";
                QUERY_STRING = "$query_string";
              };
            };

            locations."~ \\.php$" = {
              priority = 200;
              return = 404;
            };

            locations."~ /\\.(?!well-known).*" = {
              priority = 210;
              return = 404;
            };

            locations."= /favicon.ico".extraConfig = ''
              log_not_found off;
              access_log off;
            '';
            locations."= /robots.txt".extraConfig = ''
              log_not_found off;
              access_log off;
            '';
            locations."= /build-ref.txt" = lib.mkIf (config.buildReference != null) {
              return = "200 '${config.buildReference}'";
            };
          };
        };

        services.phpfpm = {
          phpPackage = lib.mkDefault cfg.phpPackage;
          phpVersion = lib.mkDefault cfg.phpVersion;
          extensions = lib.mkDefault cfg.phpExtensions;
          disableExtensions = lib.mkDefault cfg.phpDisableExtensions;
          pools.${cfg.codebase.name} = {
            phpOptions = cfg.phpOptions;
            extensions = cfg.phpExtensions;
            disableExtensions = cfg.phpDisableExtensions;
            environmentFile = secretFile;
            settings = {
              pm = lib.mkDefault "dynamic";
              "pm.max_children" = lib.mkDefault 16;
              "pm.min_spare_servers" = lib.mkDefault 4;
              "pm.max_spare_servers" = lib.mkDefault 8;
              "pm.start_servers" = lib.mkDefault 4;
              "pm.max_requests" = lib.mkDefault 500;
              "php_admin_value[error_log]" = "stderr";
              "php_admin_flag[log_errors]" = true;
              catch_workers_output = true;
            };
          };
        };

        services.redis.enable = lib.mkDefault cfg.redis.enable;

        services.mysql = lib.mkMerge [
          mysqlDefaults
          (lib.mkIf cfg.backups.enable {
            backups.enable = lib.mkDefault true;
          })
        ];

        services.restic.backups = lib.mkIf cfg.backups.enable {
          laravel = {
            backupPrepareCommand = "${config.services.mysql.backups.scripts.full}/bin/mysql-backup-full";
            paths = [
              config.services.mysql.backups.backupDir
              cfg.storageDir
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
          ${migrateBackupName} = {
            timerConfig = null;
            backupPrepareCommand = "${config.services.mysql.backups.scripts.incremental}/bin/mysql-backup-incremental";
            paths = [
              config.services.mysql.backups.backupDir
              cfg.storageDir
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

        systemd.services = lib.mkMerge [
          (lib.mkIf cfg.scheduler.enable {
            "laravel-scheduler-${cfg.codebase.name}" = {
              description = "Run the Laravel scheduler";
              wants = [
                "network-online.target"
                "mysql.service"
              ]
              ++ lib.optional cfg.redis.enable "redis.service";
              after = [
                "network-online.target"
                "mysql.service"
              ]
              ++ lib.optional cfg.redis.enable "redis.service";
              path = config.packages;
              restartIfChanged = false;
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${artisan}/bin/artisan schedule:run --no-interaction";
                EnvironmentFile = secretFile;
              };
            };
          })
          workerServices
          (lib.mkIf cfg.redis.enable {
            "phpfpm-${cfg.codebase.name}" = {
              wants = [ "redis.service" ];
              after = [ "redis.service" ];
            };
          })
        ];

        systemd.timers = lib.mkIf cfg.scheduler.enable {
          "laravel-scheduler-${cfg.codebase.name}" = {
            wantedBy = [ "timers.target" ];
            timerConfig = cfg.scheduler.timerConfig;
          };
        };

        systemd.targets = lib.mkIf (cfg.queue.workers != { }) {
          laravel-queue = {
            description = "Laravel queue workers";
            wantedBy = [ "default.target" ];
          };
        };

        hostenv.cli.commands.artisan = {
          script = helpers: ''
            echo >&2
            echo "$hostenv_emoji  Running Artisan on '$hostenv_env_name'" >&2

            remote_artisan=(artisan)
            if [ "$force" = 1 ]; then
              remote_artisan+=(--no-interaction)
            fi

            hostenv_ssh_exec "''${remote_artisan[@]}" "$@"
          '';
          description = "Run Artisan on the remote Laravel environment.";
          executable = "artisan";
          group = "Laravel";
          parsing = "passthrough";
          arguments = [
            {
              name = "arguments";
              description = "Arguments passed to Artisan";
              variadic = true;
              completion = [ ];
            }
          ];
        };

        activate = lib.mkMerge [
          (lib.mkOrder 1 ''
            laravel_secret_file=${lib.escapeShellArg secretFile}
            if [ ! -r "$laravel_secret_file" ]; then
              echo "hostenv: Laravel activation requires a readable secret file at $laravel_secret_file" >&2
              echo "hostenv: configure the provider SOPS key 'laravel_env' for this environment, project, or organisation" >&2
              exit 1
            fi
          '')

          (lib.mkOrder 50 ''
            mkdir -p ${lib.escapeShellArg cfg.storageDir} ${lib.escapeShellArg cfg.bootstrapCacheDir}
            chmod -R u+rwX ${lib.escapeShellArg cfg.storageDir} ${lib.escapeShellArg cfg.bootstrapCacheDir}

            # Clear the contents of Laravel's cache directory.
            # After an update, this directory may contain links to old
            # generations of app code in the Nix store. This ensures that
            # cannot happen.
            find ${lib.escapeShellArg cfg.bootstrapCacheDir} -mindepth 1 -maxdepth 1 -print0 \
              | xargs -0 -r rm -rf --

            storage_seed_marker=${lib.escapeShellArg "${config.hostenv.stateDir}/hostenv/laravel-storage-initialized"}
            if [ ! -e "$storage_seed_marker" ]; then
              initial_storage=${lib.escapeShellArg "${rootDir}/.hostenv-initial-storage"}
              if [ -d "$initial_storage" ]; then
                cp -a "$initial_storage/." ${lib.escapeShellArg cfg.storageDir}/
              fi
              mkdir -p "$(dirname "$storage_seed_marker")"
              touch "$storage_seed_marker"
            fi
          '')

          (lib.mkIf cfg.backups.enable (lib.mkOrder 1200 restoreScript))

          (lib.mkOrder 1300 ''
            mysql_sock=${lib.escapeShellArg "${config.services.mysql.runtimeDir}/mysql.sock"}
            if [ ! -S "$mysql_sock" ]; then
              ${config.systemd.package}/bin/systemctl --user start mysql.service || true
            fi
            for _ in $(seq 1 30); do
              [ -S "$mysql_sock" ] && break
              sleep 1
            done
            if [ ! -S "$mysql_sock" ]; then
              echo "hostenv: MariaDB did not create $mysql_sock" >&2
              exit 1
            fi

            ${lib.optionalString cfg.redis.enable ''
              redis_sock=${lib.escapeShellArg config.services.redis.socket}
              # Starting an already-running service is a no-op. Starting it
              # unconditionally also repairs the case where a stale socket was
              # left behind while the service itself is inactive.
              if ! ${config.systemd.package}/bin/systemctl --user start redis.service; then
                echo "hostenv: failed to start Valkey redis.service" >&2
                exit 1
              fi
              if [ ! -S "$redis_sock" ]; then
                echo "hostenv: Valkey reported ready without creating $redis_sock" >&2
                exit 1
              fi
            ''}

            ${lib.optionalString cfg.migrations.enable ''
              ${artisan}/bin/artisan migrate --force
            ''}
            ${lib.optionalString cfg.optimize.enable ''
              ${artisan}/bin/artisan optimize
            ''}

            ${config.systemd.package}/bin/systemctl --user start phpfpm.target || true
            ${config.systemd.package}/bin/systemctl --user start nginx.service || true
            ${lib.optionalString (cfg.queue.workers != { }) ''
              ${config.systemd.package}/bin/systemctl --user restart laravel-queue.target || true
            ''}
          '')
        ];

        profile = [
          project
          artisan
          composer
        ];
      };
    };
}
