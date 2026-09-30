{ config, ... }:
let
  libHostenv = config.flake.lib.hostenv;
in
{
  flake.modules.hostenv.drupal =
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
      canonicalUri =
        (if env.virtualHosts.${env.canonicalHost}.enableLetsEncrypt then "https://" else "http://")
        + env.canonicalHost;

      hostenvSettingsFile = pkgs.writeText "settings.hostenv.php" ''
        <?php

        // config.services.drupal.settings.privateFilesDir
        $settings['file_private_path'] = "${cfg.privateFilesDir}";

        // config.services.drupal.settings.errorReporting
        error_reporting(${cfg.settings.errorReporting});

        // config.services.drupal.settings.trustedHostPatterns
        $settings['trusted_host_patterns'] = array_merge(
          $settings['trusted_host_patterns'] ?? [], [
          ${builtins.concatStringsSep "\n" (
            builtins.map (pattern: "'${pattern}',") cfg.settings.trustedHostPatterns
          )}
        ]);

        // config.services.drupal.settings.databases
        ${cfg.settings.databases}

        // config.services.drupal.settings.extraSettings
        ${cfg.settings.extraSettings}
      '';

      composerPackage = pkgs.stdenvNoCC.mkDerivation {
        # Only change this derivation's name if there is a good reason.
        # It's named this to make it possible to find which git branch needs its
        # FOD hash updated when there's a mismatch. Otherwise - because
        # it will happen during a system deployment - Nix doesn't say which
        # user profile failed to build.
        name = config.hostenv.safeEnvironmentName + "-scaffold";
        version = cfg.codebase.version;
        dontPatchShebangs = true;
        buildInputs = [ drupalPhpPool.effectivePhpCliPackage.packages.composer ];

        src = (
          drupalPhpPool.effectivePhpCliPackage.buildComposerProject2 (finalAttrs: {
            pname = cfg.codebase.name;
            version = cfg.codebase.version;
            src = lib.cleanSourceWith {
              src = config.hostenv.root;
              filter = path: type: baseNameOf path == "composer.json" || baseNameOf path == "composer.lock";
            };
            composerLock = config.hostenv.root + /composer.lock;
            vendorHash = cfg.composer.dependencyHash;
            composerNoPlugins = !cfg.composer.enablePlugins;
            composerNoScripts = !cfg.composer.enableScripts;
            composerNoDev = !cfg.composer.enableDev;
          })
        );

        buildPhase = ''
          pushd share/php/${cfg.codebase.name}
          # Scaffold Drupal files, like 'web/{index.php,autoload.php}' etc.
          composer drupal:scaffold
          popd
        '';

        installPhase = ''
          mkdir -p $out
          cp -r . $out/
        '';
      };

      project = pkgs.stdenvNoCC.mkDerivation {
        pname = cfg.codebase.name;
        version = cfg.codebase.version;
        src = config.hostenv.root;
        dontPatchShebangs = true;

        buildPhase =
          let
            settingsPhp = ''
              // HOSTENV_SETTINGS_INCLUDE_BEGIN
              if (isset($app_root) && isset($site_path)) {
                $sitesDir = $app_root . '/' . $site_path;
              } else {
                $sitesDir = __DIR__;
              }

              if (file_exists('${hostenvSettingsFile}')) {
                include '${hostenvSettingsFile}';
              } else {
                throw new Exception('Drupal settings file not found: "${hostenvSettingsFile}"');
              }
              // HOSTENV_SETTINGS_INCLUDE_END
            '';
            settingsPhpSnippet = pkgs.writeText "settings.hostenv.include.php" settingsPhp;
          in
          ''
            ${lib.optionalString cfg.composer.enable ''
              cp -r ${composerPackage}/share/php/${cfg.codebase.name}/. .
            ''}

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
                printf '%s\n' '<?php' > "$settings_path"
              fi
            fi

            if ! grep -q 'HOSTENV_SETTINGS_INCLUDE_BEGIN' "$settings_path"; then
              cat ${settingsPhpSnippet} >> "$settings_path"
            fi

            [ -d "$WEBROOT"sites/default/files ] && mv "$WEBROOT"sites/default/files ./project_files

            rm -f "$WEBROOT"sites/default/files
            ln -s "${cfg.filesDir}" "$WEBROOT"sites/default/files
            ln -s "${hostenvSettingsFile}" "$WEBROOT"sites/default/hostenv.settings.php
          '';

        installPhase = ''
          # This standardises on web accessible files being in `/web`, allowing
          # unofficial support for Drupal 7.
          if [ -d web ]; then
            mkdir -p $out/share/php/${cfg.codebase.name}
            cp -r . $out/share/php/${cfg.codebase.name}/
          else
            mkdir -p $out/share/php/${cfg.codebase.name}/web
            cp -r . $out/share/php/${cfg.codebase.name}/web/
          fi
        '';

      };

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

          exec -a drush ${rootDir}/vendor/bin/drush "''${args[@]}" "$@"
        '';
    in
    {

      config = lib.mkIf (cfg.enable && cfg.majorVersion != 6) {

        services.drupal.settings.databases = lib.mkMerge [

          # Guard that ensures the database server is accessible.
          (lib.mkBefore ''
            if (!file_exists('${config.hostenv.runtimeDir}/mysql.sock')) {
              throw new Exception('MariaDB socket not found at \'${config.hostenv.runtimeDir}/mysql.sock\'.');
            }
          '')

          # Default database connection.
          (lib.mkOrder 1000 ''
            // Socket authentication is used here, so there is no password.
            $databases['default']['default'] = [
              'database' => '${cfg.databaseName}',
              'username' => '${config.hostenv.userName}',
              'password' => ''',
              'unix_socket' => '${config.hostenv.runtimeDir}/mysql.sock',
              'driver' => 'mysql',
              'prefix' => ''',
            ];
          '')

        ];

        systemd.services = lib.mkIf cfg.cron.enable {
          "cron-${cfg.codebase.name}" = {
            wants = lib.mkDefault [ "network-online.target" ];
            after = lib.mkDefault [ "network-online.target" ];
            restartIfChanged = lib.mkDefault false;
            path = [ pkgs.bash ] ++ config.packages;
            serviceConfig = lib.mkDefault {
              Type = "oneshot";
              ExecStart = "${drush}/bin/drush core:cron";
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

            locations."/" = {
              extraConfig = ''
                try_files $uri /index.php?$query_string;
              '';
            };
            locations."@rewrite" = {
              extraConfig = ''
                rewrite ^ /index.php;
              '';
            };
            locations."~ ^/sites/.*/files/styles/" = {
              extraConfig = ''
                try_files $uri @rewrite;
              '';
            };
            locations."~ ^(/[a-z\\-]+)?/system/files/" = {
              extraConfig = ''
                try_files $uri /index.php?$query_string;
              '';
            };
          };
        };

        hostenv.cli.commands = {
          cex = {
            script = helpers: ''
                # remote drush cex with temp dir + rsync back
                dest="/tmp/hostenv-$hostenv_user-cex"
                remote_command="$(hostenv_quote_remote_command bash -s -- "$dest" "$@")"
                cleanup_command="$(hostenv_quote_remote_command rm -rf -- "$dest")"
                if ssh -q "$hostenv_user"@"$hostenv_host" "$remote_command" <<'RS'; then
              set -euo pipefail
              dest="$1"; shift
              [ -d "$dest" ] && rm -rf -- "$dest"
              mkdir -p -- "$dest"
              chmod o-rw -- "$dest"
              drush --quiet cex --destination="$dest" "$@"
              RS
                  rsync -az --delete "$hostenv_user@$hostenv_host:$dest/" ../config/sync/
                  ssh -q "$hostenv_user"@"$hostenv_host" "$cleanup_command" || true
                  green "🗂️  Configuration exported from '$hostenv_env_name'"
                else
                  ssh -q "$hostenv_user"@"$hostenv_host" "$cleanup_command" || true
                  die "Drupal configuration export failed." 1
                fi
            '';
            description = "Export Drupal configuration from the selected environment into local 'config/sync/'.";
            group = "Drupal";
            parsing = "passthrough";
            arguments = [
              {
                name = "arguments";
                description = "Arguments to pass to 'drush cex'";
                variadic = true;
                completion = [ ];
              }
            ];
          };
        };

        activate = ''
          # Activate the Drupal application
          mkdir -p "${cfg.filesDir}"
          mkdir -p "${cfg.privateFilesDir}"
          chmod -R u+rw "${cfg.filesDir}"
          chmod -R u+rw "${cfg.privateFilesDir}"

          projectFiles="${toString project}/share/php/${cfg.codebase.name}/project_files"
          if [ ! -z "$projectFiles" ] && [  -d "$projectFiles" ]; then
            cp -r -- "$projectFiles"/* ${cfg.filesDir}/
          fi

          find "${cfg.filesDir}/" -type d -name '__MACOSX' -print0 | xargs -0 rm -rf
          find "${cfg.filesDir}/" -type f -name '.DS_Store' -delete

          if ${mysqlPrograms.client} --batch --skip-column-names \
            --socket="${config.hostenv.runtimeDir}/mysql.sock" \
            -u "${config.hostenv.userName}" \
            -e "SELECT 1 FROM information_schema.tables WHERE table_schema='${cfg.databaseName}' AND table_name='key_value' LIMIT 1;" 2>/dev/null \
            | grep -qx "1"; then
            ${drush}/bin/drush updatedb --cache-clear --yes
          else
            echo "Drupal database is not initialised; skipping 'drush updatedb'" >&2
          fi
        '';

        profile =
          let
            composer = pkgs.buildEnv {
              name = "composer";
              paths = [ drupalPhpPool.effectivePhpCliPackage.packages.composer ];
              pathsToLink = [ "/bin" ];
            };
          in
          [
            project
            drush
            composer
          ];
      };
    };
}
