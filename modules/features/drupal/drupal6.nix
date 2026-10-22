{ config, ... }:
let
  libHostenv = config.flake.lib.hostenv;
in
{
  flake.modules.hostenv.drupal6 =
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

      # Note on PHP packaging: the PHP version or package is chosen by the
      # user through the `services.drupal.phpVersion/phpPackage` options, this
      # is fed to the Drupal PHP pool options.
      #
      # The `phpfpm` service builds the PHP package for the Drupal pool (building
      # the package is tricky, as the desired PHP package may be set using a
      # version string) and the let binding below gets that package.
      #
      # This final PHP package is then used in various places in the code, so
      # the same version of PHP is used everywhere.
      drupalPhpPool = config.services.phpfpm.pools."${cfg.codebase.name}";

      phpSingleQuoted = value: "'${builtins.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] value}'";

      canonicalUri =
        (if env.virtualHosts.${env.canonicalHost}.enableLetsEncrypt then "https://" else "http://")
        + env.canonicalHost;

      mysqlSocket = "${config.hostenv.runtimeDir}/mysql.sock";

      hostenvSettingsFile = pkgs.writeText "settings.hostenv.drupal6.php" ''
        <?php

        // config.services.drupal.databaseName
        if (!file_exists(${phpSingleQuoted mysqlSocket})) {
          throw new Exception('MariaDB socket not found at ${mysqlSocket}.');
        }
        $db_url = ${phpSingleQuoted "mysqli://${config.hostenv.userName}@localhost/${cfg.databaseName}"};
        $db_prefix = ${phpSingleQuoted cfg.drupal6.databasePrefix};

        // config.services.drupal.drupal6.fileDirectoryPath
        $conf['file_directory_path'] = ${phpSingleQuoted cfg.drupal6.fileDirectoryPath};

        // config.services.drupal.drupal6.temporaryDirectory
        $conf['file_temporary_path'] = ${phpSingleQuoted cfg.drupal6.temporaryDirectory};

        // config.services.drupal.settings.errorReporting
        error_reporting(${cfg.settings.errorReporting});

        // config.services.drupal.settings.extraSettings
        ${cfg.settings.extraSettings}
      '';

      settingsPhp = ''
        // HOSTENV_SETTINGS_INCLUDE_BEGIN
        if (file_exists('${hostenvSettingsFile}')) {
          include '${hostenvSettingsFile}';
        } else {
          throw new Exception('Drupal settings file not found: "${hostenvSettingsFile}"');
        }
        // HOSTENV_SETTINGS_INCLUDE_END
      '';
      settingsPhpSnippet = pkgs.writeText "settings.hostenv.drupal6.include.php" settingsPhp;

      project = pkgs.stdenvNoCC.mkDerivation {
        pname = cfg.codebase.name;
        version = cfg.codebase.version;
        src = config.hostenv.root;
        dontPatchShebangs = true;

        buildPhase = ''
          if [ -d web ]; then
            export WEBROOT="web/"
          else
            export WEBROOT=""
          fi

          settings_path="$WEBROOT"sites/default/settings.php
          default_settings_path="$WEBROOT"sites/default/default.settings.php

          if [ ! -f "$settings_path" ]; then
            if [ -f "$default_settings_path" ]; then
              cp "$default_settings_path" "$settings_path"
            else
              mkdir -p "$(dirname "$settings_path")"
              printf '%s\n' '<?php' > "$settings_path"
            fi
          fi

          # Drupal 6 era settings.php files commonly ended with a closing tag.
          # Strip a trailing close tag before appending PHP code.
          sed -i '$ s/[[:space:]]*?>[[:space:]]*$//' "$settings_path"

          if ! grep -q 'HOSTENV_SETTINGS_INCLUDE_BEGIN' "$settings_path"; then
            cat ${settingsPhpSnippet} >> "$settings_path"
          fi

          [ -d "$WEBROOT"sites/default/files ] && mv "$WEBROOT"sites/default/files ./project_files

          rm -f "$WEBROOT"sites/default/files
          ln -s "${cfg.filesDir}" "$WEBROOT"sites/default/files
          ln -sf "${hostenvSettingsFile}" "$WEBROOT"sites/default/hostenv.settings.php
        '';

        installPhase = ''
          if [ -d web ]; then
            mkdir -p $out/share/php/${cfg.codebase.name}
            cp -r . $out/share/php/${cfg.codebase.name}/
          else
            mkdir -p $out/share/php/${cfg.codebase.name}/web
            cp -r . $out/share/php/${cfg.codebase.name}/web/
          fi
        '';
      };

      legacyDrushPackage =
        if cfg.drupal6.drushPackage != null then
          cfg.drupal6.drushPackage
        else
          builtins.throw "services.drupal.majorVersion = 6 requires services.drupal.drupal6.drushPackage because this nixpkgs version does not provide pkgs.drush8 or pkgs.drush.";

      drush =
        let
          rootDir = "${toString project}/share/php/${cfg.codebase.name}";
          webRoot = "${rootDir}/web";
        in
        pkgs.writeShellScriptBin "drush" ''
          set -euo pipefail

          # Only add --uri if caller didn't specify one.
          add_uri=true
          for arg in "$@"; do
            case "$arg" in
              --uri=*|-l|--uri) add_uri=false; break;;
            esac
          done

          args=("--root=${webRoot}")
          if $add_uri; then
            args+=("--uri=${canonicalUri}")
          fi

          export PATH=${
            lib.makeBinPath [
              drupalPhpPool.effectivePhpCliPackage
              legacyDrushPackage
            ]
          }:$PATH
          drush_bin=${legacyDrushPackage}/bin/drush
          if ${pkgs.coreutils}/bin/head -n 1 "$drush_bin" | ${pkgs.gnugrep}/bin/grep -Eq 'php|env php'; then
            exec -a drush ${drupalPhpPool.effectivePhpCliPackage}/bin/php "$drush_bin" "''${args[@]}" "$@"
          fi
          exec -a drush "$drush_bin" "''${args[@]}" "$@"
        '';
    in
    {
      options.services.drupal.drupal6 = {
        databasePrefix = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Drupal 6 database table prefix written to `$db_prefix`.";
        };

        fileDirectoryPath = lib.mkOption {
          type = lib.types.str;
          default = "sites/default/files";
          description = "Drupal 6 public files path written to `$conf['file_directory_path']`.";
        };

        temporaryDirectory = lib.mkOption {
          type = lib.types.str;
          default = config.hostenv.dataDir + "/tmp";
          defaultText = lib.literalExpression ''
            config.hostenv.dataDir + "/tmp"
          '';
          description = "Drupal 6 temporary files path written to `$conf['file_temporary_path']`.";
        };

        drushPackage = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default =
            if pkgs ? drush8 then
              pkgs.drush8
            else if pkgs ? drush then
              pkgs.drush
            else
              null;
          defaultText = lib.literalExpression ''
            if pkgs ? drush8 then pkgs.drush8 else if pkgs ? drush then pkgs.drush else null
          '';
          description = ''
            Drush package used for Drupal 6 sites. It should provide a Drupal 6
            compatible `bin/drush`; hostenv puts the Drupal PHP CLI package first
            on PATH before executing it.
          '';
        };
      };

      config = lib.mkIf (cfg.enable && cfg.majorVersion == 6) {
        warnings = [
          "services.drupal.majorVersion = 6 enables legacy Drupal 6 support. Drupal 6 is end-of-life and needs compensating security controls."
        ];

        assertions =
          (lib.optional cfg.composer.enable {
            assertion = false;
            message = "services.drupal.majorVersion = 6 requires services.drupal.composer.enable = false";
          })
          ++ (lib.optional (cfg.drupal6.drushPackage == null) {
            assertion = false;
            message = "services.drupal.majorVersion = 6 requires services.drupal.drupal6.drushPackage to provide a Drupal 6 compatible Drush";
          })
          ++ (lib.optional (!(lib.hasPrefix "/" cfg.drupal6.temporaryDirectory)) {
            assertion = false;
            message = "services.drupal.drupal6.temporaryDirectory must be an absolute path";
          });

        services.drupal = {
          composer.enable = lib.mkDefault false;
          phpExtensions = lib.mkDefault [
            "curl"
            "gd"
            "mbstring"
            "mysqli"
            "pdo"
            "pdo_mysql"
          ];
          # MySQL default socket with the connection string of `localhost`
          # makes the mysqli connector connect using the default socket.
          phpOptions = lib.mkAfter ''
            mysqli.default_socket = ${mysqlSocket}
            pdo_mysql.default_socket = ${mysqlSocket}
          '';
        };

        systemd.services = lib.mkIf cfg.cron.enable {
          "cron-${cfg.codebase.name}" = {
            wants = lib.mkDefault [ "network-online.target" ];
            after = lib.mkDefault [ "network-online.target" ];
            restartIfChanged = lib.mkDefault false;
            path = [ pkgs.bash ] ++ config.packages;
            serviceConfig = {
              Type = lib.mkDefault "oneshot";
              ExecStart = lib.mkDefault "${drush}/bin/drush cron -y";
            };
          };
        };
        systemd.timers = lib.mkIf cfg.cron.enable {
          "cron-${cfg.codebase.name}" = {
            wantedBy = [ "timers.target" ];
            timerConfig = cfg.cron.timerConfig;
          };
        };

        services.nginx.virtualHosts = {
          "${cfg.codebase.name}" = {
            root = lib.mkDefault "${project}/share/php/${cfg.codebase.name}/web";

            locations."~ ^/sites/.*/settings\\.php$" = {
              priority = 100;
              return = 403;
            };
            locations."~ ^/scripts/" = {
              priority = 110;
              return = 403;
            };
            locations."~* \\.(engine|inc|info|install|make|module|profile|po|sh|sql|theme|tpl(\\.php)?|xtmpl)$" =
              {
                priority = 120;
                return = 403;
              };
            locations."~* ^/(CHANGELOG|COPYRIGHT|INSTALL|LICENSE|MAINTAINERS|UPGRADE).*\\.txt$" = {
              priority = 130;
              return = 403;
            };
            locations."/" = {
              extraConfig = ''
                try_files $uri @rewrite;
              '';
            };
            locations."@rewrite" = {
              extraConfig = ''
                rewrite ^/(.*)$ /index.php?q=$1 last;
              '';
            };
            locations."~ \\.php$|^/update.php" = {
              priority = 500;
            };
          };
        };

        services.mysql = {
          settings = {
            mysqld = {
              sql_mode = lib.mkDefault "NO_ENGINE_SUBSTITUTION";
            };
          };
        };

        activate = ''
          # Activate the Drupal 6 application
          mkdir -p "${cfg.filesDir}"
          mkdir -p "${cfg.privateFilesDir}"
          mkdir -p "${cfg.drupal6.temporaryDirectory}"
          chmod -R u+rw "${cfg.filesDir}"
          chmod -R u+rw "${cfg.privateFilesDir}"
          chmod -R u+rw "${cfg.drupal6.temporaryDirectory}"

          for projectFiles in \
            "${toString project}/share/php/${cfg.codebase.name}/project_files" \
            "${toString project}/share/php/${cfg.codebase.name}/web/project_files"
          do
            if [ -d "$projectFiles" ]; then
              cp -r -- "$projectFiles"/. "${cfg.filesDir}/"
              break
            fi
          done

          find "${cfg.filesDir}/" -type d -name '__MACOSX' -print0 | xargs -0 rm -rf
          find "${cfg.filesDir}/" -type f -name '.DS_Store' -delete

          if ${mysqlPrograms.client} --batch --skip-column-names \
            --socket="${config.hostenv.runtimeDir}/mysql.sock" \
            -u "${config.hostenv.userName}" \
            -e "SELECT 1 FROM information_schema.tables WHERE table_schema='${cfg.databaseName}' AND table_name='system' LIMIT 1;" 2>/dev/null \
            | grep -qx "1"; then
            ${drush}/bin/drush updatedb -y
          else
            echo "Drupal 6 database is not initialised; skipping 'drush updatedb'" >&2
          fi
        '';

        profile = [
          project
          drush
        ];
      };
    };
}
