{ ... }:
{
  flake.modules.hostenv.drupalOptions =
    {
      lib,
      config,
      pkgs,
      ...
    }:
    let
      cfg = config.services.drupal;
      env = config.environments.${config.hostenv.environmentName};
      utils = import (pkgs.path + "/nixos/lib/utils.nix") { inherit pkgs lib config; };
      # Type for a valid systemd unit option. Needed for correctly passing "timerConfig" to "systemd.timers"
      inherit (utils.systemdUtils.unitOptions) unitOption;
    in
    {
      options.services.drupal = {
        enable = lib.mkEnableOption ''
          support for Drupal in this project.
                    Enabling this will bring up all the services required for a Drupal
                    project, with some opinionated decisions about PHP setup and which database
                    to use (MariaDB).
        '';

        majorVersion = lib.mkOption {
          type = lib.types.enum [
            6
            7
            8
            9
            10
            11
          ];
          default = 10;
          description = ''
            Major Drupal version for this project.

            Version 6 is implemented by the dedicated Drupal 6 compatibility
            module. Versions 7 and newer continue to use the existing Drupal module.
          '';
        };

        composer = {

          enable =
            lib.mkEnableOption ''
              composer integration in this Drupal project.

                          If enabled, `dump-autoload` and `drupal:scaffold` will be run during
                          the build phase.

                          By default, this will be enabled if a 'composer.json' file is found in
                          the project root, and that file is in version control.
            ''
            // {
              default = lib.pathExists (config.hostenv.root + /composer.lock);
            };

          dependencyHash = lib.mkOption {
            type = lib.types.str;
            description = "Hash of composer dependencies. Update this when Nix complains about a hash mismatch.";
            default = lib.fakeHash;
          };

          enablePlugins =
            lib.mkEnableOption "composer plugins when running commands like `composer install`"
            // {
              default = true;
            };
          enableScripts =
            lib.mkEnableOption "composer scripts when running commands like `composer install`"
            // {
              default = true;
            };
          enableDev = lib.mkEnableOption "dev dependencies in composer";
        };

        maxRequestSize = lib.mkOption {
          type = lib.types.str;
          description = ''
            Maximum allowed size of a client request made to Drupal.

            Used for PHP and nginx settings: `upload_max_filesize` and
            `post_max_size` (PHP) and `client_max_body_size` (nginx).

            Note: while these settings mean different things, it is still very
            convenient to set them all at once. Just pad this value enough to
            account for client body size always being slightly larger than file
            upload size, as the former includes headers while the latter does not.
          '';
          default = "1G";
        };

        databaseName = lib.mkOption {
          type = lib.types.str;
          default = "drupal";
          description = "Name of the Drupal database (used in default settings and restore guard).";
        };

        enableRouteDebugging = (lib.mkEnableOption "route debug information in HTTP headers") // {
          description = ''
            Emit X-Handled tracing headers to show which Nginx location handled the request; enabled by default outside production.
          '';
          default = env.type != "production";
        };

        phpPackage = lib.mkOption {
          type = lib.types.package;
          default = pkgs.php;
          defaultText = "pkgs.php";
        };

        phpVersion = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "The PHP version to use. If not set, will default to the latest version.";
        };

        phpExtensions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "apcu"
            "pdo"
            "pdo_mysql"
            "redis"
          ];
          description = ''
            PHP extensions to enable for Drupal.
          '';
        };

        phpDisableExtensions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            PHP extensions to disable for Drupal.
          '';
        };

        phpOptions = lib.mkOption {
          type = lib.types.lines;
          default = "";
          example = ''
            date.timezone = "CET"
          '';
          description = ''
            Additional options appended to the PHP configuration file {file}`php.ini`.
          '';
        };

        codebase = {
          name = lib.mkOption {
            type = lib.types.str;
            description = ''
              Name of the codebase. Used to identify the service in various
              configuration, e.g. nginx, systemd services.
              May be any alphanumeric name, just ensure it only contains letters
              and numbers to avoid confusing errors when starting services.
            '';
            default = config.hostenv.project;
          };

          version =
            let
              lockFile = config.hostenv.root + /composer.lock;
              # If there is a composer.lock file present, we use its hash as
              # the version; this ensures the FOD is rebuilt when the composer
              # dependencies change.
              calculatedVersion =
                if builtins.pathExists lockFile then
                  builtins.substring 0 7 (builtins.hashFile "sha256" lockFile)
                else
                  config.hostenv.safeEnvironmentName;
            in
            lib.mkOption {
              type = lib.types.str;
              default = "dev-${calculatedVersion}";
              description = "Optional. Define a version. Must be a valid version according to composer.";
            };
        };

        filesDir = lib.mkOption {
          type = lib.types.str;
          description = "Location of Drupal files directory.";
          default = config.hostenv.dataDir + "/files";
          defaultText = lib.literalExpression ''
            config.hostenv.dataDir + "/files"
          '';
        };

        privateFilesDir = lib.mkOption {
          type = lib.types.str;
          description = "Location of Drupal private files directory (must be an absolute path).";
          default = config.hostenv.dataDir + "/private_files";
          defaultText = lib.literalExpression ''
            config.hostenv.dataDir + "/private_files"
          '';
        };

        backups = {
          enable = lib.mkEnableOption "default Drupal backups stored in Restic on S3.";
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

        cron = {
          enable = (lib.mkEnableOption "running Drupal's cron.") // {
            default = true;
          };
          timerConfig = lib.mkOption {
            type = lib.types.attrsOf unitOption;
            default = {
              OnCalendar = "hourly";
              RandomizedDelaySec = "120";
              Persistent = true;
            };
            description = ''
              When to run cron. See {manpage}`systemd.timer(5)` for details.
              If `services.drupal.cron.enable` is false, this has
              no effect.
            '';
            example = {
              OnCalendar = "*:0/15";
              RandomizedDelaySec = "60";
              Persistent = true;
            };
          };
        };

        settings = {
          # Drupal settings included in {file}`settings.php`.

          databases = lib.mkOption {
            type = lib.types.lines;
            defaultText = lib.literalExpression ''
              // Socket authentication is used here, so there is no password.
              $databases['default']['default'] = [
                'database' => '${config.services.drupal.databaseName}',
                'username' => '${config.hostenv.userName}',
                'password' => ''',
                'unix_socket' => '${config.hostenv.runtimeDir}/mysql.sock',
                'driver' => 'mysql',
                'prefix' => ''',
              ];
            '';
            description = "Drupal {file}`settings.php` code that defines database connections.";
          };

          trustedHostPatterns = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = (
              builtins.map (hostname: "^${builtins.replaceStrings [ "." ] [ "\\." ] hostname}$") (
                builtins.attrNames env.virtualHosts
              )
            );
            defaultText = lib.literalExpression ''
              let
                env = config.environments.''${config.hostenv.environmentName};
              in
              (builtins.map
                (hostname: "^''${builtins.replaceStrings ["."] ["\\."] hostname}$")
                (builtins.attrNames env.virtualHosts)
              ))
            '';
            description = "List of strings hostenv uses to build `$settings['trusted_host_patterns']`.";
            example = lib.literalExpression ''
              [
                "^www\.example\.com$"
                "^example\.com$"
              ]
            '';
          };

          errorReporting = lib.mkOption {
            type = lib.types.str;
            default =
              if env.type == "production" || env.type == "testing" then
                "E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED & ~E_NOTICE"
              else
                "E_ALL";
          };

          extraSettings = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = lib.literalExpression ''
              $settings['update_free_access'] = true;
            '';
            description = "Additional settings added to Drupal {file}`settings.php`.";
          };

        };
      };
    };
}
