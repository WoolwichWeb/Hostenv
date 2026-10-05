# Portions of this file are derived from the Nixpkgs/NixOS project,
# originally licensed under the MIT License.
#
# Original source:
# https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/services/web-servers/phpfpm/default.nix
#
# See LICENSES/MIT-nixpkgs.

{ ... }:
{
  flake.modules.hostenv.phpfpm =
    { config, lib, pkgs, inputs, ... }:
    
    let
      cfg = config.services.phpfpm;
      env = config.environments.${config.hostenv.environmentName};
    
      phps = inputs.phps or { };
    
      mkPackageWithConfig = package: cfg_: package.buildEnv {
        extensions = { all, enabled }:
          let
            missing = builtins.filter (name: !(builtins.hasAttr name all)) cfg_.extensions;
            selected = map (name: all.${name}) cfg_.extensions;
            isWanted = drv: !lib.elem drv.extensionName cfg_.disableExtensions;
          in
          if missing != [ ] then
            throw ''
              PHP ${package.version or "unknown"} on ${pkgs.stdenv.hostPlatform.system} does not provide requested extensions: ${lib.concatStringsSep ", " missing}
            ''
          else
            lib.unique (builtins.filter isWanted (enabled ++ selected));
        extraConfig = cfg_.phpOptions;
      };
    
      mkPackageWithExtensionsOnly = package: cfg_: mkPackageWithConfig package (cfg_ // { extraConfig = ""; });
    
      toStr = value:
        if true == value then "yes"
        else if false == value then "no"
        else toString value;
    
      fpmCfgFile = pool: poolOpts: pkgs.writeText "phpfpm-${pool}.conf" ''
        [global]
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "${n} = ${toStr v}") cfg.settings)}
    
        [${pool}]
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "${n} = ${toStr v}") poolOpts.settings)}
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "env[${n}] = ${toStr v}") poolOpts.phpEnv)}
      '';
    
      phpIni = poolOpts: pkgs.runCommand "php.ini"
        {
          inherit (poolOpts) phpPackage phpOptions;
          preferLocalBuild = true;
          passAsFile = [ "phpOptions" ];
        } ''
        cat ${poolOpts.phpPackage}/etc/php.ini $phpOptionsPath > $out
      '';
    
      version = cfg_: builtins.replaceStrings [ "." ] [ "" ] cfg_.phpVersion;
      phpVersionError = cfg_:
        if phps == { }
        then
          ''
    
    
            If nix-phps supports this PHP version, add
            'phps.url = "github:fossar/nix-phps";'
            to the inputs in flake.nix, then try again.
          ''
        else
          "";
      phpsPackage = cfg_: phps.packages.${pkgs.stdenv.system}."php${version cfg_}" or (throw ("PHP version ${cfg_.phpVersion} is not available." + phpVersionError cfg_));
      nixpkgsPackageExists = cfg_: (builtins.tryEval (toString pkgs."php${version cfg_}")).success;
      customPhpPackage = cfg_: if ((builtins.hasAttr "php${version cfg_}" pkgs) && nixpkgsPackageExists cfg_) then pkgs."php${version cfg_}" else phpsPackage cfg_;
    
      poolOpts = { name, ... }:
        let
          poolCfg = cfg.pools.${name};
        in
        {
          options = {
            socket = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              description = ''
                Path to the unix socket file on which to accept FastCGI requests.
    
                Defaults to `${config.hostenv.runtimeDir}/<pool>.sock`. User-level nginx should
                proxy FastCGI to this socket; the system-level nginx talks to the user-level
                nginx via `${config.hostenv.upstreamRuntimeDir}/in.sock`.
              '';
              example = "${config.hostenv.runtimeDir}/pool.sock";
            };
    
            phpVersion = lib.mkOption {
              type = lib.types.str;
              default = cfg.phpVersion;
              defaultText = "services.phpfpm.phpVersion";
              description = "The PHP version to use.";
            };
    
            phpPackage = lib.mkOption {
              type = lib.types.package;
              default = cfg.phpPackage;
              defaultText = lib.literalExpression "services.phpfpm.phpPackage";
              description = ''
                Allows you to [override the default used package](https://nixos.org/manual/nixpkgs/stable/#ssec-php-user-guide)
                to adjust the settings or add more extensions.
    
                If you pass a package with `extraConfig`, those settings will still
                appear in the pool's base `php.ini` (which we merge), but the
                recommended approach is to keep packages extension-only and set
                the pool INI in `phpOptions`.
              '';
              example = lib.literalExpression ''
                pkgs.php.buildEnv {
                  extensions = { all, enabled }: with all; enabled ++ [ apcu ];
                };
              '';
            };
    
            effectivePhpPackage = lib.mkOption {
              type = lib.types.package;
              readOnly = true;
              internal = true;
              description = ''
                Computed pool PHP with extensions layered in.
              '';
            };
    
            effectivePhpCliPackage = lib.mkOption {
              type = lib.types.package;
              readOnly = true;
              internal = true;
              description = ''
                Computed pool PHP with extensions and CLI configuration layered in.
              '';
            };
    
            phpOptions = lib.mkOption {
              type = lib.types.lines;
              description = ''
                "Options appended to the PHP configuration file {file}`php.ini` used for this PHP-FPM pool."
              '';
            };
    
            phpEnv = lib.mkOption {
              type = with lib.types; attrsOf str;
              default = { };
              description = ''
                Environment variables used for this PHP-FPM pool.
              '';
              example = lib.literalExpression ''
                {
                  HOSTNAME = "$HOSTNAME";
                  TMP = "/tmp";
                  TMPDIR = "/tmp";
                  TEMP = "/tmp";
                }
              '';
            };
    
            environmentFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Optional systemd-compatible environment file loaded by the
                PHP-FPM service. When set, PHP-FPM inherits those variables and
                passes them through to workers instead of clearing the process
                environment.
              '';
            };

            settings = lib.mkOption {
              type = with lib.types; attrsOf (oneOf [ str int bool ]);
              default = { };
              description = ''
                PHP-FPM pool directives. Refer to the "List of pool directives" section of
                <https://www.php.net/manual/en/install.fpm.configuration.php>
                for details. Note that settings names must be enclosed in quotes (e.g.
                `"pm.max_children"` instead of `pm.max_children`).
              '';
              example = lib.literalExpression ''
                {
                  "pm" = "dynamic";
                  "pm.max_children" = 75;
                  "pm.start_servers" = 10;
                  "pm.min_spare_servers" = 5;
                  "pm.max_spare_servers" = 20;
                  "pm.max_requests" = 500;
                }
              '';
            };
    
            extensions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = cfg.extensions;
              defaultText = lib.literalExpression "services.phpfpm.extensions";
              description = ''
                PHP extensions to enable for this pool.
              '';
            };
    
            disableExtensions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = cfg.disableExtensions;
              defaultText = lib.literalExpression "services.phpfpm.disableExtensions";
              description = ''
                PHP extensions to disable for this pool.
              '';
            };
    
          };
    
          config = {
            # The pool PHP package with only extensions layered in.
            # PHP options are applied by the systemd unit.
            effectivePhpPackage = lib.mkMerge [
              # Default: use the base package.
              (lib.mkDefault (
                mkPackageWithExtensionsOnly poolCfg.phpPackage poolCfg
              ))
    
              # If the pool sets a phpVersion, use `customPhpPackage` to grab the
              # desired version.
              (lib.mkIf (poolCfg.phpVersion != "") (lib.mkForce (
                let
                  base = customPhpPackage poolCfg;
                in
                mkPackageWithExtensionsOnly base poolCfg
              )))
            ];
    
            # The pool PHP package with the pool's PHP version, extensions,
            # pool php.ini, and CLI-only php.ini settings. Framework wrappers
            # such as Drush use this so CLI tools match the PHP-FPM runtime for
            # the pool while still receiving CLI-specific overrides.
            effectivePhpCliPackage =
              let
                cliPoolCfg = cfg.cli // {
                  extensions = poolCfg.extensions;
                  disableExtensions = poolCfg.disableExtensions;
                  phpOptions = lib.concatStringsSep "\n" [
                    poolCfg.phpOptions
                    cfg.cli.phpOptions
                  ];
                };
              in
              lib.mkMerge [
                (lib.mkIf (poolCfg.phpVersion != "") (lib.mkForce (
                  let
                    base = customPhpPackage poolCfg;
                  in
                  mkPackageWithConfig base cliPoolCfg
                )))

                (lib.mkIf (poolCfg.phpVersion == "") (lib.mkForce (
                  mkPackageWithConfig poolCfg.phpPackage cliPoolCfg
                )))
              ];
    
            # Hostenv convention: pool socket lives in the user runtime dir; user-level nginx
            # proxies FastCGI to it.
            socket = "${config.hostenv.runtimeDir}/${name}.sock";
            phpOptions = lib.mkBefore cfg.phpOptions;

            # Refer to a distinct master-process variable rather than `$PATH`
            # itself. PHP-FPM does not reliably preserve a PATH that recursively
            # refers to the variable it is defining.
            phpEnv = lib.mkIf (config.packages != [ ]) {
              PATH = lib.mkDefault "$HOSTENV_PHPFPM_PATH";
            };

            settings = lib.mapAttrs (_n: lib.mkDefault) ({
              listen = poolCfg.socket;
            } // lib.optionalAttrs (poolCfg.environmentFile != null || config.packages != [ ]) {
              # Project packages are added to the master process PATH by its
              # start wrapper. Keep that environment in the worker processes.
              clear_env = false;
            });
          };
        };
    in
    {
      options = {
        services.phpfpm = {
    
          enable = lib.mkEnableOption "php-fpm server (note: will enable automatically if any pools are defined)" // { default = cfg.pools != { }; };
    
          phpVersion = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "The PHP version to use.";
          };
    
          settings = lib.mkOption {
            type = with lib.types; attrsOf (oneOf [ str int bool ]);
            default = { };
            description = ''
              PHP-FPM global directives. Refer to the "List of global php-fpm.conf directives" section of
              <https://www.php.net/manual/en/install.fpm.configuration.php>
              for details. Note that settings names must be enclosed in quotes (e.g.
              `"pm.max_children"` instead of `pm.max_children`).
              You need not specify the options `error_log` or
              `daemonize` here, since they are generated by hostenv.
            '';
          };
    
          extensions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              PHP extensions to enable.
            '';
          };
    
          disableExtensions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              PHP extensions to disable.
            '';
          };
    
          phpPackage = lib.mkOption {
            type = lib.types.package;
            default = pkgs.php;
            defaultText = lib.literalExpression "pkgs.php";
          };
    
          phpOptions = lib.mkOption {
            type = lib.types.lines;
            default = "";
            example =
              ''
                date.timezone = "CET"
              '';
            description = ''
              Options appended to the PHP configuration file {file}`php.ini`.
            '';
          };
    
          pools = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule poolOpts);
            default = { };
            example = lib.literalExpression ''
              {
                mypool = {
                  phpPackage = pkgs.php;
                  settings = {
                    "pm" = "dynamic";
                    "pm.max_children" = 75;
                    "pm.start_servers" = 10;
                    "pm.min_spare_servers" = 5;
                    "pm.max_spare_servers" = 20;
                    "pm.max_requests" = 500;
                  };
                }
              }'';
            description = ''
              PHP-FPM pools. If no pools are defined, the PHP-FPM
              service is disabled.
            '';
          };
    
          cli = {
            phpVersion = lib.mkOption {
              type = lib.types.str;
              default = cfg.phpVersion;
              description = "PHP version for the CLI php on PATH.";
            };
    
            extensions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = cfg.extensions;
              description = "Extensions enabled in CLI php.";
            };
    
            disableExtensions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = cfg.disableExtensions;
              description = "Extensions disabled in CLI php.";
            };
    
            phpOptions = lib.mkOption {
              type = lib.types.lines;
              default = (
                if env.type == "production" || env.type == "testing"
                then ''
                  error_reporting = E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED & ~E_NOTICE
                ''
                else ''
                  error_reporting = E_ALL
                ''
              ) + ''
                memory_limit = -1
              '';
              description = "Additional php.ini for the CLI (not used by FPM pools).";
            };
    
            phpPackage = lib.mkOption {
              type = lib.types.package;
              default = cfg.phpPackage;
              description = "The package that provides the CLI /bin/php put onto PATH.";
            };
          };
    
        };
      };
    
      config = lib.mkIf (cfg.enable && cfg.pools != { }) {
    
        # @todo: add a warning if the user specifies a phpPackage and a phpVersion.
        services.phpfpm.phpPackage = lib.mkIf
          (cfg.phpVersion != "")
          (lib.mkForce (customPhpPackage cfg));
    
        services.phpfpm.cli.phpPackage = lib.mkMerge [
          (lib.mkDefault (
            mkPackageWithConfig cfg.phpPackage cfg.cli
          ))
          (lib.mkIf (cfg.cli.phpVersion != "") (lib.mkForce (
            let
              pkg = customPhpPackage cfg.cli;
            in
            mkPackageWithConfig pkg cfg.cli
          )))
        ];
    
        services.phpfpm.settings = {
          # Send PHP-FPM's main log to the service's standard error. systemd records
          # standard error in the user journal, so PHP-FPM errors and worker output
          # captured by catch_workers_output are available through journalctl --user.
          error_log = lib.mkDefault "/proc/self/fd/2";
          daemonize = lib.mkDefault false;
        };
    
        services.phpfpm.phpOptions = lib.mkDefault (
          (if env.type == "production" || env.type == "testing"
          then ''
            error_reporting = E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED & ~E_NOTICE
            display_errors = Off
            display_startup_errors = Off
            log_errors = On
          ''
          else ''
            error_reporting = E_ALL
          ''
          )
          + ''
            error_log = syslog
            syslog.ident = php
            syslog.facility = user
            memory_limit = 1024M
            max_execution_time = 300
            apc.enabled = 1
            apc.shm_size = 128M
          ''
        );
    
        systemd.slices.app-phpfpm = {
          description = "PHP FastCGI Process Manager Slice";
        };
    
        systemd.targets.phpfpm = {
          description = "PHP FastCGI Process manager pools target";
          wantedBy = [ "default.target" ];
        };
    
        systemd.services = lib.mapAttrs'
          (pool: poolOpts:
            lib.nameValuePair "phpfpm-${pool}" {
              description = "PHP FastCGI Process Manager service for pool ${pool}";
              after = [ "network.target" ];
              wantedBy = [ "phpfpm.target" ];
              partOf = [ "phpfpm.target" ];
              path = config.packages;
              serviceConfig =
                let
                  cfgFile = fpmCfgFile pool poolOpts;
                  iniFile = phpIni poolOpts;
                  start = pkgs.writeShellScript "phpfpm-${pool}-start" ''
                    ${lib.optionalString (config.packages != [ ]) ''
                      # EnvironmentFile may replace PATH. Add project runtime
                      # packages after systemd has loaded that file so neither
                      # source of executables is lost.
                      export PATH=${lib.escapeShellArg (lib.makeBinPath config.packages)}:"$PATH"
                      export HOSTENV_PHPFPM_PATH="$PATH"
                    ''}
                    exec "$@"
                  '';
                in
                ({
                  Slice = "app-phpfpm.slice";
                  Type = "notify";
                  ExecStart = "${start} ${poolOpts.effectivePhpPackage}/bin/php-fpm -y ${cfgFile} -c ${iniFile}";
                  ExecReload = "${pkgs.coreutils}/bin/kill -USR2 $MAINPID";
                  Restart = "always";
                } // lib.optionalAttrs (poolOpts.environmentFile != null) {
                  EnvironmentFile = poolOpts.environmentFile;
                });
            }
          )
          cfg.pools;
    
        profile =
          let
            mkPoolCnf = pool: poolOpts: pkgs.runCommand "${pool}.conf" { } ''
              mkdir -p $out/etc/php-fpm.d
              ln -s ${fpmCfgFile pool poolOpts} $out/etc/php-fpm.d/${pool}.conf
            '';
            mkPoolIni = pool: poolOpts: pkgs.runCommand "${pool}.ini" { } ''
              mkdir -p $out/etc/php-fpm.d
              ln -s ${phpIni poolOpts} $out/etc/php-fpm.d/${pool}.ini
            '';
            mkPoolPhp = pool: poolOpts: pkgs.runCommand "${pool}-php" { } ''
              mkdir -p $out/etc/php-fpm.d
              ln -s ${poolOpts.effectivePhpPackage} $out/etc/php-fpm.d/${pool}-php
            '';
            mkPoolPhpCli = pool: poolOpts: pkgs.writeShellScriptBin "php@${pool}" ''
              exec ${poolOpts.effectivePhpCliPackage}/bin/php "$@"
            '';
            pools = lib.flatten (lib.mapAttrsToList
              (pool: poolOpts:
                [ (mkPoolCnf pool poolOpts) (mkPoolIni pool poolOpts) (mkPoolPhp pool poolOpts) (mkPoolPhpCli pool poolOpts) ]
              )
              cfg.pools);
          in
          pools ++ [ cfg.cli.phpPackage ];
      };
    }
  ;
}
