{ config, ... }:
let
  cfgTop = config;
in
{
  flake.modules.hostenv.nginx =
    { lib, config, pkgs, ... }:
    let
      inherit (lib) all;
      cfg = config.services.nginx;
      env = config.environments.${config.hostenv.environmentName};
      nginxLib = cfgTop.flake.lib.hostenv.nginx;
      topConfig = config;
      vhostOptions = { name, ... }: nginxLib.vhostOptions {
        inherit lib name pkgs;
        config = topConfig;
      };
      vhostValues = nginxLib.vhostValues {
        inherit lib config pkgs;
        inherit (cfg) virtualHosts enableRouteDebugging;
      };

      configFile =
        (if cfg.validateConfig then pkgs.writers.writeNginxConfig else pkgs.writeText) "nginx.conf"
          ''
            ${cfg.prependConfig}
    
            pid ${config.hostenv.runtimeDir}/nginx.pid;
            error_log syslog:server=unix:/dev/log debug;
            daemon off;
    
            ${cfg.config}
    
            ${lib.optionalString (cfg.eventsConfig != "" || cfg.config == "") ''
              events {
                ${cfg.eventsConfig}
              }
            ''}
    
            ${lib.optionalString (cfg.config == "") ''
              http {
                ${cfg.commonHttpConfig}
    
                ${lib.optionalString cfg.recommendedOptimisation ''
                # Recommended optimisation.
                sendfile on;
                tcp_nopush on;
                tcp_nodelay on;
                keepalive_timeout 65;
                ''}
    
                ${vhostValues}
              }
            ''}
    
            ${cfg.appendConfig}
          '';

      configPath = if cfg.enableReload then "$XDG_CONFIG_HOME/nginx.conf" else configFile;

      execCommand = "${cfg.package}/bin/nginx -e stderr -c \"${configPath}\"";
    in
    {
      options.services.nginx = {
        enable = lib.mkEnableOption "nginx Web server" // { default = cfg.virtualHosts != null; };

        package = lib.mkOption {
          default = pkgs.nginx;
          defaultText = lib.literalExpression "pkgs.nginx";
          type = lib.types.package;
          apply = p: p.override {
            modules = lib.unique (p.modules ++ cfg.additionalModules);
          };
        };

        additionalModules = lib.mkOption {
          default = [ ];
          defaultText = lib.literalExpression "[ pkgs.nginxModules.brotli ]";
          type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
          example = lib.literalExpression "[ pkgs.nginxModules.echo ]";
          description = ''
            Additional [third-party nginx modules](https://www.nginx.com/resources/wiki/modules/)
            to install. Packaged modules are available in `pkgs.nginxModules`.
          '';
        };

        virtualHosts = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf (lib.types.submodule vhostOptions));
          description = "Optional virtual host configuration. Enabling a framework provides a sensible default.";
          default = null;
        };

        defaultMimeTypes = lib.mkOption {
          type = lib.types.path;
          default = "${pkgs.mailcap}/etc/nginx/mime.types";
          defaultText = lib.literalExpression "\${pkgs.mailcap}/etc/nginx/mime.types";
          example = lib.literalExpression "\${pkgs.nginx}/conf/mime.types";
          description = ''
            Default MIME types for NGINX, as MIME types definitions from NGINX are very incomplete,
            we use by default the ones bundled in the mailcap package, used by most of the other
            Linux distributions.
          '';
        };

        recommendedOptimisation = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Enable recommended optimisation settings.
          '';
        };

        recommendedProxySettings = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Whether to enable recommended proxy settings if a vhost does not specify the option manually.
          '';
        };

        proxyTimeout = lib.mkOption {
          type = lib.types.str;
          default = "60s";
          example = "20s";
          description = ''
            Change the proxy related timeouts in recommendedProxySettings.
          '';
        };

        recommendedUwsgiSettings = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Whether to enable recommended uwsgi settings if a vhost does not specify the option manually.
          '';
        };

        uwsgiTimeout = lib.mkOption {
          type = lib.types.str;
          default = "60s";
          example = "20s";
          description = ''
            Change the uwsgi related timeouts in recommendedUwsgiSettings.
          '';
        };

        proxyResolveWhileRunning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Resolve proxyPass targets at runtime, not only at startup. Requires services.nginx.resolver.
          '';
        };

        uwsgiResolveWhileRunning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Resolve uwsgiPass targets at runtime, not only at startup. Requires services.nginx.resolver.
          '';
        };

        serverTokens = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Show nginx version in headers and error pages.";
        };

        serverNamesHashBucketSize = lib.mkOption {
          type = lib.types.int;
          default = 128;
          description = "nginx server_names_hash_bucket_size; bumped to handle long hostenv hostnames.";
        };

        fastcgiReadTimeout = lib.mkOption {
          type = lib.types.str;
          default = "300s";
          example = "120s";
          description = "FastCGI response read timeout.";
        };

        clientMaxBodySize = lib.mkOption {
          type = lib.types.str;
          default = "100m";
          description = "Set nginx global client_max_body_size.";
        };

        eventsConfig = lib.mkOption {
          type = lib.types.lines;
          default = ''
            worker_connections 1024;
          '';
          description = "The nginx events configuration.";
        };

        config = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Verbatim {file}`nginx.conf` configuration.
            This is mutually exclusive to any other config option for
            {file}`nginx.conf` except for:
            - [](#opt-services.nginx.prependConfig)
            - [](#opt-services.nginx.appendConfig)
    
            If additional verbatim config in addition to other options is needed,
            [](#opt-services.nginx.appendConfig) should be used instead.
          '';
        };

        prependConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            Configuration lines prepended to the generated Nginx
            configuration file. Can for example be used to load modules.
            {option}`prependConfig` can be specified more than once
            and its value will be concatenated (contrary to {option}`config`
            which can be set only once).
          '';
        };

        appendConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = ''
            Configuration lines appended to the generated Nginx
            configuration file. Commonly used by different modules
            providing http snippets. {option}`appendConfig`
            can be specified more than once and its value will be
            concatenated (contrary to {option}`config` which
            can be set only once).
          '';
        };

        commonHttpConfig = lib.mkOption {
          type = lib.types.lines;
          default = ''
            # Per-workspace temp paths, if this not set per-workspace every nginx
            # instance tries to write to the same directory, with permissions
            # errors being the result for all but one of them.
            client_body_temp_path ${config.hostenv.stateDir}/nginx/;
            proxy_temp_path ${config.hostenv.stateDir}/nginx/;
            fastcgi_temp_path ${config.hostenv.stateDir}/nginx/;
            scgi_temp_path ${config.hostenv.stateDir}/nginx/;
            uwsgi_temp_path ${config.hostenv.stateDir}/nginx/;
    
            # Load mime types and configure maximum size of the types hash tables.
            include ${cfg.defaultMimeTypes};
            # The following is tailoured to work with default mime types above.
            types_hash_max_size 2688;
    
            include ${cfg.package}/conf/fastcgi.conf;
            include ${cfg.package}/conf/uwsgi_params;
    
            fastcgi_buffers 16 16k;
            fastcgi_buffer_size 32k;
            fastcgi_read_timeout ${cfg.fastcgiReadTimeout};
            client_max_body_size ${cfg.clientMaxBodySize};
    
            default_type application/octet-stream;
    
            access_log syslog:server=unix:/dev/log combined;
          '';
          example = ''
            resolver 127.0.0.1 valid=5s;
    
            log_format myformat '$remote_addr - $remote_user [$time_local] '
                                '"$request" $status $body_bytes_sent '
                                '"$http_referer" "$http_user_agent"';
          '';
          description = ''
            With nginx you must provide common http context definitions before
            they are used, e.g. log_format, resolver, etc. inside of server
            or location contexts. Use this attribute to set these definitions
            at the appropriate location.
          '';
        };

        enableRouteDebugging = (lib.mkEnableOption "route debug information in HTTP headers") //
          {
            description = ''
              Emit X-Handled tracing headers to show which Nginx location handled the request; enabled by default outside production.
            '';
            default = env.type != "production";
          };

        validateConfig = lib.mkEnableOption "validation of the nginx config." // { default = true; };

        enableReload = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Reload nginx when configuration file changes (instead of restart).
            The configuration file is exposed at {file}`$XDG_CONFIG_HOME/nginx.conf`.
          '';
        };
      };

      config = lib.mkIf (cfg.enable && cfg.virtualHosts != null) {
        assertions = [
          {
            assertion = all
              (host:
                all (location: !(location.proxyPass != null && location.uwsgiPass != null)) (lib.attrValues host.locations))
              (lib.attrValues cfg.virtualHosts);
            message = ''
              Options services.nginx.service.virtualHosts.<name>.proxyPass and
              services.nginx.virtualHosts.<name>.uwsgiPass are mutually exclusive.
            '';
          }
        ];

        systemd.services.nginx = {
          description = "Nginx Web Server for ${config.hostenv.userName}";
          wantedBy = [ "default.target" ];
          after = [ "network.target" ];
          reloadIfChanged = true;
          preStart = ''
            ${execCommand} -t
          '';
          startLimitIntervalSec = 60;
          serviceConfig = {
            ExecStart = execCommand;
            ExecReload = [
              "${execCommand} -t"
              "${pkgs.coreutils}/bin/kill -HUP $MAINPID"
            ];
            # Ensure unix socket inherits group 'nginx' from the setgid upstreamRuntimeDir
            # and is created with 0660 permissions so system nginx can connect.
            UMask = "0007";
            Restart = "always";
            RestartSec = "10s";
            PassEnvironment = "XDG_CONFIG_HOME";
          };
        };

        # @todo: need a hostenv lib containing helpers to generate code like
        # the check for $XDG_CONFIG_HOME below, which is duplicated from the
        # systemd activation script.
        activate = lib.optionalString cfg.enableReload ''
          ## nginx activation script.
    
          if [ ! -n "$XDG_CONFIG_HOME" ]; then
            echo '⚠️ XDG_CONFIG_HOME is not set.' >&2
            echo 'ℹ️ Set it before enabling nginx reloads.' >&2
            exit 1
          fi
    
          mkdir -p "$XDG_CONFIG_HOME" || exit 1
    
          if [ -e "$XDG_CONFIG_HOME"/nginx.conf ]; then
            # If the file is a symlink to a directory that exists...
            if [ -L "$XDG_CONFIG_HOME"/nginx.conf ]; then
              # ...then delete it.
              rm "$XDG_CONFIG_HOME"/nginx.conf
            else
              # Otherwise the file exists, but is not a symlink.
              echo "⚠️ Could not remove '$XDG_CONFIG_HOME/nginx.conf'." >&2
              echo "ℹ️ Delete it manually, then try again." >&2
              exit 1
            fi
          fi
    
          ln -sf ${configFile} "$XDG_CONFIG_HOME"/nginx.conf || exit 1
        '';

        profile =
          let
            confInEtc = pkgs.runCommand "nginx-conf" { } ''
              mkdir -p $out/etc/nginx
              ln -s ${configFile} $out/etc/nginx/nginx.conf
            '';
          in
          [ cfg.package confInEtc ];

      };
    }
  ;
}
