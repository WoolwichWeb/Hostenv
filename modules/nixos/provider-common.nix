{ config, ... }:
let
  libHostenv = config.flake.lib.hostenv;
in
{
  flake.modules.nixos.provider-common =
    { config, lib, pkgs, ... }:
    let
      deployPublicKeys = config.provider.deployPublicKeys or [ ];
      deployCfg = config.provider.deploy;
      cacheCfg = config.provider.cache;
      deployUser = config.provider.deployUser or "deploy";
      serviceResolutionCfg = config.provider.serviceResolution;
      deployHasSettings =
        deployCfg.enable
        || deployCfg.providerApiBaseUrl != null
        || deployCfg.nodeAuthTokenFile != null
        || deployCfg.nodeName != null
        || deployCfg.reconnectSeconds != 5;
    in
    {
      options.provider = {
        deployPublicKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "SSH public keys for the deploy user (provider-level).";
        };
        deployUser = lib.mkOption {
          type = lib.types.str;
          default = "deploy";
          description = "SSH/sudo user used by deploy-rs and provider tooling.";
        };
        nixSigning.trustedPublicKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Public signing keys trusted by nix-daemon on provider nodes.";
        };

        serviceResolution = libHostenv.mkServiceResolutionOption { inherit lib; };

        deploy = {
          enable = lib.mkEnableOption "reserved provider-deploy node agent wiring";

          # @todo: change these back to disallow nulls once provider-service
          # node agent wiring lands and validation no longer needs placeholders.
          providerApiBaseUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Reserved base URL for provider deploy APIs.";
          };

          nodeAuthTokenFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Reserved bearer token file used by provider-deploy.";
          };

          nodeName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Reserved logical node identity used by provider-deploy.";
          };

          reconnectSeconds = lib.mkOption {
            type = lib.types.int;
            default = 5;
            description = "Reserved backoff delay between provider-deploy reconnects.";
          };
        };

        cache = {
          enable = lib.mkEnableOption "provider binary cache client configuration";

          # @todo: change these back to disallow nulls once provider cache
          # wiring lands and validation no longer needs placeholders.
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Provider cache URL used as highest-priority substituter.";
          };

          publicKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Public cache signing key appended to trusted-public-keys.";
          };

          authPasswordFile = lib.mkOption {
            type = lib.types.str;
            default = "/run/secrets/hostenv/cache_auth_password";
            description = "Path to cache auth password secret used to derive netrc at runtime.";
          };

          netrcFile = lib.mkOption {
            type = lib.types.str;
            default = "/run/hostenv/provider-cache.netrc";
            description = "Runtime netrc file path used for cache authentication.";
          };
        };
      };

      config = {
        sops.defaultSopsFormat = lib.mkDefault "yaml";
        sops.age.sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];

        nix = {
          # Currently disabled `nix.settings.auto-optimise-store` as it seems to fail with remote builders
          # TODO re-enable when fixed https://github.com/NixOS/nix/issues/7273
          settings.auto-optimise-store = lib.mkDefault false;

          gc = {
            automatic = lib.mkDefault true;
            randomizedDelaySec = lib.mkDefault "14m";
            options = lib.mkDefault "--delete-older-than 10d";
          };

          # TODO: SOPS secrets.access_tokens may not be needed after OAuth
          # work is complete. For now this is necessary to allow access to
          # private repos from nodes performing remote builds, but should be
          # re-evaluated in future.
          extraOptions = lib.mkDefault ''
            experimental-features = nix-command flakes
            !include ${config.sops.secrets.access_tokens.path}
          '';

          settings.trusted-public-keys =
            let
              # Include the cache's public key if needed.
              cacheKey =
                if cacheCfg.enable && cacheCfg.publicKey != null && cacheCfg.publicKey != ""
                then [ cacheCfg.publicKey ]
                else [ ];
            in
            lib.mkAfter (lib.unique
              (config.provider.nixSigning.trustedPublicKeys ++ cacheKey)
            );

          settings.require-signed-binaries = lib.mkIf cacheCfg.enable true;
          # Keep NixOS defaults such as cache.nixos.org as fallbacks while
          # preferring the provider cache.
          settings.substituters =
            lib.mkIf (cacheCfg.enable && cacheCfg.url != null && cacheCfg.url != "")
              (lib.mkBefore [ cacheCfg.url ]);
          settings.netrc-file =
            lib.mkIf (cacheCfg.enable && cacheCfg.netrcFile != null && cacheCfg.netrcFile != "")
              cacheCfg.netrcFile;
          # Allow deploy-rs uploads from the provider host without disabling
          # signature checks globally on the node.
          settings.trusted-users = lib.mkAfter [ deployUser ];
        };

        services.openssh = {
          enable = lib.mkDefault true;
          settings.PasswordAuthentication = lib.mkDefault false;
          settings.KbdInteractiveAuthentication = lib.mkDefault false;
        };

        security.sudo.extraRules = [{
          groups = [ "wheel" ];
          commands = [{
            command = "ALL";
            options = [ "NOPASSWD" ];
          }];
        }];

        users.groups.keys.name = lib.mkDefault "keys";
        users.mutableUsers = lib.mkDefault false;
        users.users.${deployUser} = {
          isNormalUser = lib.mkDefault true;
          extraGroups = lib.mkDefault [ "wheel" "keys" ];
          openssh.authorizedKeys.keys = lib.mkDefault deployPublicKeys;
        };

        assertions = [
          {
            assertion = !deployHasSettings;
            message = "provider.deploy is not supported yet. Leave provider.deploy at its default settings.";
          }
          {
            assertion = serviceResolutionCfg == null;
            message = "provider.serviceResolution is not supported yet. Leave provider.serviceResolution unset.";
          }
          {
            assertion = (!cacheCfg.enable) || (cacheCfg.url != null && cacheCfg.url != "");
            message = "provider.cache.url must be configured when provider.cache.enable is true.";
          }
          {
            assertion = (!cacheCfg.enable) || (cacheCfg.publicKey != null && cacheCfg.publicKey != "");
            message = "provider.cache.publicKey must be configured when provider.cache.enable is true.";
          }
          {
            assertion = (!cacheCfg.enable) || (cacheCfg.authPasswordFile != null && cacheCfg.authPasswordFile != "");
            message = "provider.cache.authPasswordFile must be configured when provider.cache.enable is true.";
          }
          {
            assertion = (!cacheCfg.enable) || (cacheCfg.netrcFile != null && cacheCfg.netrcFile != "");
            message = "provider.cache.netrcFile must be configured when provider.cache.enable is true.";
          }
        ];

        sops.secrets = lib.mkMerge [
          {
            # GitLab/GitHub tokens for private flake inputs are still needed by
            # node-side builds until provider-service can fetch sources.
            access_tokens = lib.mkDefault {
              mode = "0440";
              group = config.users.groups.keys.name;
            };
          }
          (lib.mkIf cacheCfg.enable {
            hostenv-provider-cache-auth-password = {
              key = "cache_auth_password";
              path = cacheCfg.authPasswordFile;
              owner = "root";
              group = "root";
              mode = "0400";
            };
          })
        ];

        systemd.services.hostenv-provider-cache-netrc = lib.mkIf
          (
            cacheCfg.enable
            && cacheCfg.url != null
            && cacheCfg.url != ""
            && cacheCfg.authPasswordFile != null
            && cacheCfg.authPasswordFile != ""
            && cacheCfg.netrcFile != null
            && cacheCfg.netrcFile != ""
          )
          {
            description = "Render provider cache netrc from password secret";
            wantedBy = [ "multi-user.target" ];
            before = [ "provider-deploy.service" "nix-daemon.service" ];
            script = ''
              set -euo pipefail
              umask 077
              password="$(tr -d '\n\r' < "${cacheCfg.authPasswordFile}")"
              cache_host="${cacheCfg.url}"
              cache_host="''${cache_host#https://}"
              cache_host="''${cache_host#http://}"
              cache_host="''${cache_host%%/*}"
              case "$cache_host" in
                \[*\]:*) cache_host="''${cache_host%%]:*}]" ;;
                *:*) cache_host="''${cache_host%%:*}" ;;
              esac
              mkdir -p "$(dirname "${cacheCfg.netrcFile}")"
              printf '%s\n' \
                "machine $cache_host" \
                "login cache" \
                "password $password" \
                > "${cacheCfg.netrcFile}"
              chown root:root "${cacheCfg.netrcFile}"
              chmod 0400 "${cacheCfg.netrcFile}"
            '';
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
          };

        networking.firewall.enable = lib.mkDefault true;
        # Do not use mkDefault here: list options only merge within the
        # strongest priority class, and sshd's non-default openFirewall rule
        # would otherwise collapse this list down to [ 22 ].
        networking.firewall.allowedTCPPorts = [ 80 443 22 ];

        environment.sessionVariables = {
          XDG_CACHE_HOME = lib.mkDefault "$HOME/.cache";
          XDG_CONFIG_HOME = lib.mkDefault "$HOME/.config";
          XDG_DATA_HOME = lib.mkDefault "$HOME/.local/share";
          XDG_STATE_HOME = lib.mkDefault "$HOME/.local/state";
        };
      };
    }
  ;
}
