{
  inputs,
  lib,
  config,
  ...
}:
let
  fp = inputs.flake-parts.lib;
  types = lib.types;

  systems = config.systems;

  # Basic Hostenv configuration: paths, project hash.
  hostenvModule =
    { lib, config, ... }:
    let
      types = lib.types;

      # Replace non-alpha characters with a hyphen
      sanitise =
        str:
        lib.strings.stringAsChars (
          c: if builtins.match "[[:alnum:]]" c != null || c == "-" then c else "-"
        ) str;

      # Collapse multiple hyphens, trim leading/trailing ones
      cleanDashes =
        str:
        let
          collapsed = builtins.replaceStrings [ "--" "---" "----" "-----" ] [ "-" "-" "-" "-" ] str;
          trimmed = lib.removeSuffix "-" (lib.removePrefix "-" collapsed);
        in
        trimmed;

      slugify =
        s:
        let
          lastSegment = lib.last (lib.splitString "/" s);
          sanitised = cleanDashes (sanitise lastSegment);
          words = lib.splitString "-" sanitised;

          buildSlug =
            maxLen:
            let
              go =
                idx: acc:
                if idx >= builtins.length words then
                  acc
                else
                  let
                    next = builtins.elemAt words idx;
                    candidate = lib.concatStringsSep "-" (acc ++ [ next ]);
                  in
                  if lib.stringLength candidate > maxLen then acc else go (idx + 1) (acc ++ [ next ]);

              resultWords = go 0 [ ];
            in
            if resultWords != [ ] then
              lib.concatStringsSep "-" resultWords
            else
              lib.substring 0 maxLen sanitised;

          slug = buildSlug 11;
        in
        lib.toLower (if slug != "" then slug else lib.concatStringsSep "-" (lib.take 1 words));

    in
    {
      options = {
        hostenvHostname = lib.mkOption {
          type = types.str;
          description = "Top-level hostname for Hostenv.";
          example = "example.com";
          default = "example.invalid";
          internal = true;
        };
        organisation = lib.mkOption {
          type = types.str;
          description = "Business account name or organisation name of the project. Should be short, lowercase, and with no special characters.";
          example = "fooinc";
          # Note on the additional removal of '-' characters:
          # This name is used when generating systemd slice names, which are
          # split by '-' characters, allowing '-'s would introduce an extra layer
          # into the systemd slice hierarchy.
          apply = v: builtins.replaceStrings [ "-" ] [ "" ] (sanitise (lib.strings.toLower v));
        };
        project = lib.mkOption {
          type = types.str;
          description = "Name of the project. Should be short, lowercase, and contain no special characters.";
          example = "coolproject";
          apply = v: builtins.replaceStrings [ "-" ] [ "" ] (sanitise (lib.strings.toLower v));
        };
        environmentName = lib.mkOption {
          type = types.str;
          description = "Name of the current environment. Usually corresponds to a git branch, but can be something else, e.g. an MR slug or number. Should be short, lowercase, and with no special characters.";
        };
        safeEnvironmentName = lib.mkOption {
          type = types.str;
          description = "Name of the current environment, shortened and with special characters removed.";
        };
        gitRef = lib.mkOption {
          type = types.str;
          description = "Git branch or tag of this environment. Defaults to the `environmentName`.";
          example = "main";
        };
        userName = lib.mkOption {
          type = types.str;
          description = "UNIX username (on server) of this environment.";
        };
        hostname = lib.mkOption {
          type = types.str;
          description = "Server hostname for this project and environment, as a fully qualified domain name (FQDN).";
          example = "hostenv-main-7c25553.hostenv.sh";
        };
        runtimeRoot = lib.mkOption {
          type = types.str;
          description = "Root directory for hostenv runtime sockets and state.";
          default = "/run/hostenv";
        };
        root = lib.mkOption {
          type = types.oneOf [
            types.str
            types.path
          ];
          description = "The application's root directory.";
        };
        runtimeDir = lib.mkOption {
          type = types.str;
          description = "Path (on server) where hostenv sockets and pid files may be found.";
          example = lib.literalExpression "${config.runtimeRoot}/user/\${config.hostenv.userName}";
        };
        upstreamRuntimeDir = lib.mkOption {
          type = types.str;
          description = "Path (on server) where upstream reverse proxy socket may be found.";
          example = lib.literalExpression "${config.runtimeRoot}/nginx/\${config.hostenv.userName}";
        };
        dataDir = lib.mkOption {
          type = types.str;
          description = "Path (on server) where data may be found at runtime.";
          example = lib.literalExpression "/home/\${config.hostenv.userName}/.local/share";
        };
        stateDir = lib.mkOption {
          type = types.str;
          description = "Path (on server) where state data may be found at runtime.";
          example = lib.literalExpression "/home/\${config.hostenv.userName}/.local/state";
        };
        cacheDir = lib.mkOption {
          type = types.str;
          description = "Path (on server) where cache data may be found at runtime.";
          example = lib.literalExpression "/home/\${config.hostenv.userName}/.cache";
        };
        backupsSecretFile = lib.mkOption {
          type = types.str;
          description = "Path (on server) where secret access key for accessing backups may be found.";
        };
        backupsEnvFile = lib.mkOption {
          type = types.str;
          description = "Path (on server) where an environment file with information related to accessing backups may be found.";
        };
        backupsRepoHost = lib.mkOption {
          type = types.nullOr types.str;
          description = "URL of backups hosting service (without the trailing slash).";
          example = "s3:https://s3.amazonaws.com";
          apply = v: if v == null then null else lib.removeSuffix "/" v;
          default = null;
        };
        projectNameHash = lib.mkOption {
          type = types.str;
          description = "Hash of organisation, project, and environment names.";
          internal = true;
        };
      };

      config =
        let
          slugHash = builtins.hashString "sha256" (
            # "\n" is so our result matches
            # `echo "org-project-environment" | sha256sum` in bash.
            # This is for historical reasons: I started by creating environments
            # manually, using hashes generated from the command-line, while forgetting
            # the sublty that echo appends "\n" to every string.
            lib.concatStringsSep "-" [
              config.organisation
              config.project
              config.environmentName
            ]
            + "\n"
          );

          shortName =
            lib.concatStringsSep "-" (
              map slugify [
                config.project
                config.environmentName
              ]
            )
            + "-"
            + lib.substring 0 7 slugHash;
        in
        {
          userName = lib.mkForce shortName;
          hostname = lib.mkForce "${shortName}.${config.hostenvHostname}";
          safeEnvironmentName = lib.mkForce (cleanDashes (sanitise config.environmentName));
          # Note: we use environmentName and not safeEnvironmentName as the latter
          # is stripped of some characters that are valid in git branch names,
          # '/' and '--' for example.
          gitRef = lib.mkDefault config.environmentName;
          runtimeDir = lib.mkForce "${config.runtimeRoot}/user/${config.userName}";
          upstreamRuntimeDir = lib.mkForce "${config.runtimeRoot}/nginx/${config.userName}";
          dataDir = lib.mkForce "/home/${config.userName}/.local/share";
          stateDir = lib.mkForce "/home/${config.userName}/.local/state";
          cacheDir = lib.mkForce "/home/${config.userName}/.cache";
          backupsSecretFile = lib.mkForce "/run/secrets/${config.userName}/backups_secret";
          backupsEnvFile = lib.mkForce "/run/secrets/${config.userName}/backups_env";
          projectNameHash = lib.mkForce slugHash;
        };
    };

  # The subset of per-environment configuration needed to choose the
  # environment. This allows us to avoid full Hostenv evaluation of all
  # environments when only one is needed.
  environmentSelectionModule =
    { lib, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this environment on hostenv";
        type = lib.mkOption {
          type = lib.types.enum [
            "development"
            "testing"
            "production"
          ];
          default = "development";
          description = ''
            Environment type, setting this to production exposes this environment
            to search engines.
            Only one environment may be production.
          '';
        };
      };
    };

  # Per-environment config.
  environmentModule =
    {
      allUsers ? { },
      topLevel ? { },
      forceNull ? "__HOSTENV_INTERNAL_DO_NOT_CHANGE_SEMAPHORE__",
      hostenvModule,
    }:
    {
      lib,
      config,
      name,
      ...
    }:
    let
      types = lib.types;

      # Given an attrset of hostnames, determine which one should be canonical.
      # Throws an error if the user set multiple hostnames to be canonical, or
      # if the user set their canonical hostname to redirect somewhere else.
      resolveCanonicalHost =
        virtualHosts:
        let
          # Virtualhosts the user explicitly marked as 'canonical', which means
          # they are the preferred public hostname for the environment.
          #
          # If no hostname is set as canonical, we can infer it from custom
          # hostnames that serve the application and have Let's Encrypt enabled.
          # Only one hostname may be canonical, but that condition is handled
          # below (by throwing).
          explicit = builtins.attrNames (lib.filterAttrs (_: vhost: vhost.canonical or false) virtualHosts);

          eligible = lib.filterAttrs (
            host: vhost:
            host != config.hostenv.hostname
            && (vhost.globalRedirect or null) == null
            && (vhost.enableLetsEncrypt or true)
          ) virtualHosts;

          eligibleNames = builtins.attrNames eligible;

          # Hostnames from the eligible list above that other hostnames
          # redirect to.
          #
          # A redirect to an eligible host is a stronger signal than merely
          # being one of several hostnames that can serve the application.
          redirectTargets = lib.unique (
            lib.filter (target: target != null && builtins.hasAttr target eligible) (
              lib.mapAttrsToList (_: vhost: vhost.globalRedirect or null) virtualHosts
            )
          );
        in
        if builtins.length explicit > 1 then
          throw ''
            Only one virtual host may be canonical for environment '${name}'.
            Found: ${lib.concatStringsSep ", " explicit}
          ''

        else if explicit != [ ] then
          let
            canonical = builtins.head explicit;
            redirect = virtualHosts.${canonical}.globalRedirect or null;
          in
          if redirect != null && redirect != forceNull then
            throw ''
              Virtual host '${canonical}' in environment '${name}' cannot be
              both canonical and redirect to '${redirect}'.
            ''
          else
            canonical

        else if builtins.length redirectTargets == 1 then
          builtins.head redirectTargets

        else if eligibleNames != [ ] then
          # If the canonical hostname cannot be inferred, just grab the
          # first one. Note that attribute names are sorted, so this will
          # always be the first eligible *after the list is sorted into
          # alphabetical order*.
          builtins.head eligibleNames

        else
          # The base case: only the generated environment URL is available,
          # e.g. some-environment-abc1234.example.com
          config.hostenv.hostname;

      user = {
        options = {

          email = lib.mkOption {
            type = types.str;
            description = "A valid email address for the user.";
          };

          publicKeys = lib.mkOption {
            type = types.listOf types.singleLineStr;
            description = ''
              A list of verbatim OpenSSH public keys that should be added to the
              user's authorized keys.
            '';
          };
        };
      };
    in
    {
      # Import the small subset of environment options defined above in
      # our full environment option set.
      imports = [ environmentSelectionModule ];

      options = {
        users = lib.mkOption {
          type = types.attrsOf (types.submodule user);
          default = allUsers;
        };

        requiredSecretFiles = lib.mkOption {
          type = types.listOf (types.strMatching "[A-Za-z0-9_]+");
          default = [ ];
          description = ''
            Secret files this environment requires from its hosting provider.

            Each name is resolved by the provider from its SOPS configuration
            and projected to `/run/secrets/<environment-user>/<name>`. Projects
            can request names only; paths, ownership, and modes remain under
            provider control.
          '';
        };

        virtualHosts =
          let
            envConfig = config;
          in
          lib.mkOption {
            type = types.attrsOf (
              types.submodule (
                { config, options, ... }: {
                  options = {

                    locations = lib.mkOption {
                      type = types.attrsOf (
                        types.submodule {
                          options = {
                            return = lib.mkOption {
                              type =
                                with types;
                                nullOr (oneOf [
                                  str
                                  int
                                ]);
                              default = null;
                              example = "301 http://example.com$request_uri";
                              description = ''
                                Adds a return directive, for e.g. redirections.
                              '';
                            };
                          };
                        }
                      );
                      default = { };
                    };

                    enableLetsEncrypt = lib.mkOption {
                      default = true;
                      type = types.bool;
                      description = ''
                        Enable Let's Encrypt for this host.
                      '';
                    };

                    allowIndexing = lib.mkOption {
                      default = if envConfig.type == "production" then true else false;
                      type = types.bool;
                      description = ''
                        Advise search engines whether they are allowed to crawl
                        this site (or not).

                        Defaults to `true` on production environments, and `false`
                        on all other environment types.
                      '';
                    };

                    canonical = lib.mkOption {
                      type = types.bool;
                      default = false;
                      description = ''
                        Whether this virtual host is the canonical public hostname
                        for the environment.

                        Hostenv normally infers the canonical hostname. Set this when
                        an environment serves several hostnames and the intended
                        canonical hostname would otherwise be ambiguous.
                      '';
                    };

                    globalRedirect = lib.mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      example = "newserver.example.org";
                      description = ''
                        If set, all requests for this host are redirected to the given
                        hostname (the HTTP status code defaults to 301, configurable
                        with `redirectCode`).
                      '';
                      apply =
                        let
                          hostName = envConfig.hostenv.hostname or "";
                          thisHost = config._module.args.name;
                          thisPrio = options.globalRedirect.highestPrio;
                        in
                        value:
                        if thisHost == hostName && thisPrio < lib.modules.defaultOverridePriority && value == null then
                          forceNull
                        else
                          value;
                    };

                    redirectCode = lib.mkOption {
                      default = 301;
                      type = types.int;
                      description = ''
                        HTTP status code to return when redirecting requests to a
                        different host.
                      '';
                    };

                    hsts = lib.mkOption {
                      default = true;
                      type = types.bool;
                      description = ''
                        Include an HSTS header for this host.
                      '';
                    };

                    security = lib.mkOption {
                      type = types.submodule (
                        { ... }: {
                          options = {
                            csp = lib.mkOption {
                              type = types.nullOr types.singleLineStr;
                              default = null;
                              description = ''
                                Content-Security-Policy value for this host. Set to null to disable.
                              '';
                              apply =
                                value:
                                if value != null && lib.strings.hasInfix "\"" value then
                                  throw "virtualHosts.<host>.security.csp may not contain double quotes."
                                else
                                  value;
                            };

                            cspMode = lib.mkOption {
                              type = types.enum [
                                "enforce"
                                "report-only"
                              ];
                              default = "enforce";
                              description = ''
                                Whether to emit CSP as enforce or report-only.
                              '';
                            };

                            cspReportTo = lib.mkOption {
                              type = types.nullOr (types.strMatching "^[A-Za-z0-9._-]+$");
                              default = null;
                              description = ''
                                Optional CSP report-to group name to append to the policy.
                              '';
                            };

                            reportTo = lib.mkOption {
                              type = types.nullOr types.singleLineStr;
                              default = null;
                              description = ''
                                Optional Report-To header value (JSON) to emit when set.
                              '';
                              apply =
                                value:
                                if value != null && lib.strings.hasInfix "'" value then
                                  throw "virtualHosts.<host>.security.reportTo may not contain single quotes."
                                else
                                  value;
                            };

                            referrerPolicy = lib.mkOption {
                              type = types.nullOr (
                                types.enum [
                                  "no-referrer"
                                  "no-referrer-when-downgrade"
                                  "same-origin"
                                  "origin"
                                  "strict-origin"
                                  "origin-when-cross-origin"
                                  "strict-origin-when-cross-origin"
                                  "unsafe-url"
                                ]
                              );
                              default = "strict-origin-when-cross-origin";
                              description = ''
                                Referrer-Policy header value.
                              '';
                            };

                            xFrameOptions = lib.mkOption {
                              type = types.nullOr (
                                types.enum [
                                  "SAMEORIGIN"
                                  "DENY"
                                ]
                              );
                              default = "SAMEORIGIN";
                              description = ''
                                X-Frame-Options header value. Set to null to disable.
                              '';
                            };

                            xContentTypeOptions = lib.mkOption {
                              type = types.bool;
                              default = true;
                              description = ''
                                Whether to emit X-Content-Type-Options: nosniff.
                              '';
                            };

                            hsts = lib.mkOption {
                              type = types.bool;
                              default = true;
                              description = ''
                                Whether to emit HSTS (only on HTTPS/forceSSL hosts).
                              '';
                            };
                          };
                        }
                      );
                      default = { };
                      description = ''
                        Security header configuration for this host.
                      '';
                    };
                  };
                }
              )
            );
            default = { };
            apply =
              virtualHosts:
              let
                hostname = config.hostenv.hostname;
                canonicalHost = resolveCanonicalHost virtualHosts;
                generatedVHost = virtualHosts.${hostname};
                setGeneratedRedirect =
                  target:
                  virtualHosts
                  // {
                    ${hostname} = generatedVHost // {
                      globalRedirect = target;
                    };
                  };
              in
              if generatedVHost.globalRedirect == forceNull then
                setGeneratedRedirect null
              else if generatedVHost.globalRedirect != null then
                virtualHosts
              else if canonicalHost != hostname then
                setGeneratedRedirect canonicalHost
              else
                virtualHosts;
            description = ''
              Optional virtual host configuration. Enabling a framework provides a
              sensible default.
            '';
          };

        canonicalHost = lib.mkOption {
          type = types.str;
          readOnly = true;
          internal = true;
          description = ''
            Resolved canonical public hostname for this environment.

            Internal modules should consume this value instead of independently
            inferring a canonical hostname from virtualHosts.
          '';
        };

        deploymentVerification = lib.mkOption {
          type = types.submodule (
            { ... }: {
              options = {
                enable = lib.mkOption {
                  type = types.bool;
                  default = true;
                  description = ''
                    Whether deployment verification checks are enabled for this environment.
                  '';
                };

                enforce = lib.mkOption {
                  type = types.bool;
                  default = true;
                  description = ''
                    Whether failed deployment verification checks fail the deployment.
                  '';
                };

                checks = lib.mkOption {
                  type = types.listOf (
                    types.submodule (
                      { ... }: {
                        options = {
                          name = lib.mkOption {
                            type = types.str;
                            default = "verification-check";
                            description = "Human-readable name for this check.";
                          };

                          type = lib.mkOption {
                            type = types.enum [ "httpHostHeaderCurl" ];
                            default = "httpHostHeaderCurl";
                            description = "Verification check implementation to run.";
                          };

                          request = lib.mkOption {
                            type = types.submodule (
                              { ... }: {
                                options = {
                                  virtualHost = lib.mkOption {
                                    type = types.str;
                                    description = "Virtual host sent in the HTTP Host header.";
                                  };

                                  path = lib.mkOption {
                                    type = types.str;
                                    default = "/";
                                    description = "Request path used during verification.";
                                  };

                                  method = lib.mkOption {
                                    type = types.str;
                                    default = "GET";
                                    description = "HTTP method used during verification.";
                                  };

                                  targetHostSource = lib.mkOption {
                                    type = types.enum [ "nodeConnectionHost" ];
                                    default = "nodeConnectionHost";
                                    description = "Source of the node host used for direct connection.";
                                  };

                                  followRedirects = lib.mkOption {
                                    type = types.bool;
                                    default = false;
                                    description = "Whether redirects are followed by curl.";
                                  };

                                  maxRedirects = lib.mkOption {
                                    type = types.int;
                                    default = 5;
                                    description = "Maximum redirects to follow when followRedirects is enabled.";
                                  };

                                  timeoutSeconds = lib.mkOption {
                                    type = types.int;
                                    default = 15;
                                    description = "Maximum request duration in seconds.";
                                  };

                                  tlsMode = lib.mkOption {
                                    type = types.enum [
                                      "strict"
                                      "insecure"
                                    ];
                                    default = "strict";
                                    description = "TLS verification mode for HTTPS requests.";
                                  };
                                };
                              }
                            );
                            default = { };
                            description = "Request definition for this check.";
                          };

                          constraints = lib.mkOption {
                            type = types.listOf (
                              types.submodule (
                                { ... }: {
                                  options = {
                                    rule = lib.mkOption {
                                      type = types.enum [
                                        "allowNonZeroExitStatus"
                                        "skipStdoutRegexOnRedirect"
                                        "stdoutRegexMustMatch"
                                        "stderrRegexMustNotMatch"
                                        "minHttpStatus"
                                        "maxHttpStatus"
                                      ];
                                      description = "Constraint rule to evaluate for the check.";
                                    };

                                    value = lib.mkOption {
                                      type = types.oneOf [
                                        types.bool
                                        types.int
                                        types.str
                                      ];
                                      description = "Constraint value for the selected rule.";
                                    };
                                  };
                                }
                              )
                            );
                            default = [ ];
                            description = "Constraint list evaluated against the check output.";
                          };
                        };
                      }
                    )
                  );
                  default = [ ];
                  description = ''
                    Checks run after successful environment deployments.
                  '';
                };
              };
            }
          );
          default = { };
          description = ''
            Per-environment deployment verification configuration.
          '';
        };

        hostenv = lib.mkOption {
          type = types.submoduleWith {
            modules = [
              hostenvModule
              {
                config.organisation = lib.mkDefault (topLevel.organisation or "");
                config.project = lib.mkDefault (topLevel.project or "");
                config.hostenvHostname = lib.mkDefault (topLevel.hostenvHostname or "example.invalid");
                config.backupsRepoHost = lib.mkDefault (topLevel.backupsRepoHost or null);
                config.environmentName = name;
                config.root = lib.mkDefault (topLevel.root or ".");
              }
            ];
          };
          default = { };
          description = "Per-environment hostenv metadata.";
        };

      };

      config = {
        virtualHosts.${config.hostenv.hostname} = lib.mkDefault { };
        canonicalHost = resolveCanonicalHost config.virtualHosts;
      };
    };

  mkHostenvFunctions =
    system:
    let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays =
          let
            pogOver =
              if inputs ? pog && inputs.pog ? overlays && inputs.pog.overlays ? default then
                inputs.pog.overlays.default
              else
                throw ''
                  The Hostenv CLI cannot be built because the Pog input does not provide overlays.default. This is an internal Hostenv configuration error.

                  Report it at:
                  https://gitlab.com/woolwichweb/hostenv/-/boards#/
                '';
          in
          [ pogOver ];
      };

      # Evaluate only the configuration required to discover project
      # environments and choose a default environment.
      #
      # Unlike evalHostenv, this deliberately does not load the Hostenv runtime
      # modules and does not define hostenv.environmentName.
      evalEnvironmentSelection =
        modules:
        pkgs.lib.evalModules {
          modules = [
            { _module.args = { inherit inputs pkgs; }; }
            ({ lib, ... }: {
              # We deliberately ignore unknown options, only evaluating
              # what is necessary to discover environments and select the default.
              config._module.check = false;

              options = {
                defaultEnvironment = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };

                environments = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (
                    lib.types.submoduleWith {
                      modules = [
                        environmentSelectionModule
                        { _module.check = false; }
                      ];
                    }
                  );
                };
              };
            })
          ]
          ++ modules;
        };

      evalHostenv =
        modules: selectedEnvironmentName:
        pkgs.lib.evalModules {
          modules = [
            { _module.args = { inherit inputs pkgs; }; }
            ({ ... }: {
              hostenv.environmentName = selectedEnvironmentName;
            })
            {
              systemd.globalEnvironment.TZDIR = "${pkgs.tzdata}/share/zoneinfo";
            }
          ]
          ++ lib.attrValues config.flake.modules.hostenv
          ++ modules;
        };

      resolveDefaultEnvironment =
        selectionConfig:
        let
          enabledNames = builtins.attrNames (
            lib.filterAttrs (_: env: env.enable) selectionConfig.environments
          );

          productionNames = builtins.attrNames (
            lib.filterAttrs (_: env: env.enable && env.type == "production") selectionConfig.environments
          );
        in
        # No enabled environments is a valid desired state. In particular,
        # a stale explicit default must not keep a deleted environment alive.
        if enabledNames == [ ] then
          null
        else if selectionConfig.defaultEnvironment != null then
          selectionConfig.defaultEnvironment
        else if productionNames != [ ] then
          builtins.head productionNames
        else if builtins.length enabledNames > 0 then
          if builtins.elem "main" enabledNames then "main" else builtins.head enabledNames
        else
          null;

      discoverProject =
        modules:
        let
          selectionEval = evalEnvironmentSelection modules;
        in
        {
          environments = selectionEval.config.environments;
          defaultEnvironment = resolveDefaultEnvironment selectionEval.config;
        };

      makeHostenv =
        modules: environmentName:
        let
          project = discoverProject modules;
        in
        if !builtins.isString environmentName then
          throw "Environment name must be a string."
        else if !(builtins.hasAttr environmentName project.environments) then
          throw "Environment '${environmentName}' is not defined by the project."
        else
          evalHostenv (
            modules
            ++ [
              ({ lib, ... }: {
                defaultEnvironment = lib.mkForce project.defaultEnvironment;
              })
            ]
          ) environmentName;
    in
    {
      inherit discoverProject makeHostenv;
    };

  hostenvFunctions = lib.genAttrs systems mkHostenvFunctions;

in
{
  options.flake.makeHostenv = lib.mkOption {
    type = lib.types.attrsOf (lib.types.functionTo (lib.types.functionTo lib.types.unspecified));
    readOnly = true;
    description = "Evaluate a specific declared project environment.";
  };

  options.perSystem = fp.mkPerSystemOption (
    { ... }: {
      options.hostenv.makeHostenv = lib.mkOption {
        type = lib.types.functionTo (lib.types.functionTo lib.types.unspecified);
        readOnly = true;
        description = "Evaluate a specific declared project environment.";
      };
    }
  );

  config = {
    flake.lib.hostenv.module = hostenvModule;
    flake.lib.hostenv.environmentModule = environmentModule;
    flake.lib.hostenv.discoverProject = lib.mapAttrs (
      _: functions: functions.discoverProject
    ) hostenvFunctions;

    # TODO: do not create unknown flake outputs, use lib instead
    flake.modules.hostenv.core = { ... }: {
      options.hostenv = lib.mkOption {
        type = types.submodule hostenvModule;
        description = "Hostenv configuration for the current environment.";
      };
    };

    # TODO: do not create unknown flake outputs, use lib instead
    flake.makeHostenv = lib.mapAttrs (_: functions: functions.makeHostenv) hostenvFunctions;

    perSystem = { system, ... }: {
      hostenv.makeHostenv = config.flake.makeHostenv.${system};
    };
  };
}
