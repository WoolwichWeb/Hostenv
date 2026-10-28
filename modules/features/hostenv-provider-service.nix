{ config, ... }:
let
  packagesFor = config.flake.lib.hostenv.packagesFor;
in
{
  flake.modules.hostenv.hostenv-provider-service =
    { lib, config, pkgs, ... }:
    let
      cfg = config.services.hostenv-provider;
      providerService = (packagesFor pkgs).hostenv-provider-service;
      serviceBin = providerService.override {
        sourceRoot = cfg.source;
        haskellDeps = cfg.haskellDeps;
      };
      ghc = serviceBin.ghc;
      proxySocket = "http://unix:${cfg.listenSocket}:/";
      configFile = pkgs.writeText "hostenv-provider-config.json" (builtins.toJSON {
        dataDir = cfg.dataDir;
        repoSource = toString cfg.repoSource;
        flakeRoot = cfg.flakeRoot;
        listenSocket = cfg.listenSocket;
        webhookSecretFile = cfg.webhookSecretFile;
        webhookSecretsDir = cfg.webhookSecretsDir;
        webhookHost = cfg.webhookHost;
        uiBasePath = cfg.uiBasePath;
        uiBaseUrl = "${cfg.uiScheme}://${cfg.uiHost}";
        dbUri = cfg.dbUri;
        gitlabOAuthSecretsFile = cfg.gitlabOAuthSecretsFile;
        gitlabHosts = cfg.gitlabHosts;
        gitCredentialsFile = cfg.gitCredentialsFile;
        gitConfigFile = cfg.gitConfigFile;
        flakeTemplate = cfg.flakeTemplate;
      });

    in
    {
      options.services.hostenv-provider = {
        enable = lib.mkEnableOption "Hostenv provider service";

        source = lib.mkOption {
          type = lib.types.path;
          default = providerService.src;
          defaultText = lib.literalExpression "hostenv-provider-service.src";
          description = "Path to the hostenv-provider-service source tree.";
        };

        haskellDeps = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = providerService.haskellDeps;
          defaultText = lib.literalExpression "hostenv-provider-service.haskellDeps";
          description = "Haskell package names required by hostenv-provider-service.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = serviceBin;
          defaultText = lib.literalExpression ''
            hostenv-provider-service.override {
              sourceRoot = config.services.hostenv-provider.source;
              haskellDeps = config.services.hostenv-provider.haskellDeps;
            }
          '';
          description = "Package providing the hostenv-provider-service executable.";
        };

        dataDir = lib.mkOption {
          type = lib.types.str;
          default = "${config.hostenv.dataDir}/hostenv-provider";
          description = "Working directory used by the provider service.";
        };

        listenSocket = lib.mkOption {
          type = lib.types.str;
          default = "${config.hostenv.runtimeDir}/hostenv-provider.sock";
          description = "Unix socket on which the provider service listens.";
        };

        webhookSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to a global webhook secret token (GitHub HMAC or GitLab token).";
        };

        webhookSecretsDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Directory containing per-project webhook secrets, named by hash or org__project.";
        };

        webhookHost = lib.mkOption {
          type = lib.types.str;
          default = config.hostenv.hostname;
          description = "Hostname that serves provider webhooks and the administration interface.";
        };

        uiBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/ui";
          description = "URL path for the administration interface.";
        };

        uiHost = lib.mkOption {
          type = lib.types.str;
          default = cfg.webhookHost;
          description = "Hostname used for GitLab sign-in redirects.";
        };

        uiScheme = lib.mkOption {
          type = lib.types.str;
          default = "https";
          description = "URL scheme used for GitLab sign-in redirects.";
        };

        dbUri = lib.mkOption {
          type = lib.types.str;
          default = "host=${config.hostenv.runtimeDir} dbname=hostenv-provider user=${config.hostenv.userName}";
          description = "PostgreSQL connection string used by the provider service.";
        };

        gitlabOAuthSecretsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to a secrets file containing the GitLab client_id and client_secret.";
        };

        gitlabHosts = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "gitlab.com" ];
          description = "GitLab hosts from which users may sign in.";
        };

        gitCredentialsFile = lib.mkOption {
          type = lib.types.str;
          default = "${cfg.dataDir}/git-credentials";
          description = "Path to the generated Git credential store.";
        };

        gitConfigFile = lib.mkOption {
          type = lib.types.str;
          default = "${cfg.dataDir}/gitconfig";
          description = "Path to the Git configuration file used by the provider service.";
        };

        flakeTemplate = lib.mkOption {
          type = lib.types.str;
          default = "flake.template.nix";
          description = "Path to the flake template (relative to flakeRoot if not absolute).";
        };

        repoSource = lib.mkOption {
          type = lib.types.oneOf [ lib.types.path lib.types.str ];
          default = config.hostenv.root;
          description = "Provider repository to copy into dataDir when the working copy is missing.";
        };

        flakeRoot = lib.mkOption {
          type = lib.types.str;
          default = ".";
          description = "Subdirectory within repoSource that contains flake.nix.";
        };
      };

      config = lib.mkIf cfg.enable {
        services.nginx.enable = lib.mkDefault true;
        services.nginx.virtualHosts = {
          "${cfg.webhookHost}" = {
            locations = lib.mkMerge [
              {
                "~ ^/webhook/" = {
                  recommendedProxySettings = true;
                  proxyPass = proxySocket;
                };
              }
              {
                "${cfg.uiBasePath}" = {
                  recommendedProxySettings = true;
                  proxyPass = proxySocket;
                };
              }
            ];
            serverName = lib.mkDefault cfg.webhookHost;
          };
        };

        systemd.services.hostenv-provider = {
          description = "Hostenv provider service";
          wantedBy = [ "default.target" ];
          after = [ "network.target" ];
          restartIfChanged = false;
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.git
            pkgs.bind
            pkgs.nix
            pkgs.openssh
            ghc
          ];
          serviceConfig = {
            ExecStart = "${cfg.package}/bin/hostenv-provider-service --config ${configFile}";
            WorkingDirectory = cfg.dataDir;
            Restart = "on-failure";
            RestartSec = "5s";
          };
        };
        profile = [ cfg.package ];
      };
    }
  ;
}
