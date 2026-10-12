{ pkgs, makeHostenv }:

let
  drupalRoot = import ./integration/drupal/source.nix { inherit pkgs; };
  laravelSources = import ./integration/laravel/source.nix { inherit pkgs; };
  laravelSecretSource = pkgs.runCommand "laravel-secret-source" { } ''
    mkdir -p "$out/public" "$out/storage" "$out/bootstrap/cache"
    printf '%s\n' '<?php echo "ok";' > "$out/public/index.php"
    printf '%s\n' '#!/usr/bin/env php' '<?php' > "$out/artisan"
    printf '%s\n' 'APP_KEY=hostenv-secret-must-not-enter-project-output' > "$out/.env"
    printf '%s\n' 'APP_KEY=hostenv-local-secret-must-not-enter-project-output' > "$out/.env.local"
  '';

  drupal6Revision = "7e1e3f37a5d82521f61a4544927bf71142cd4e23";
  drupal6Source = pkgs.fetchFromGitHub {
    owner = "WoolwichWeb";
    repo = "d6lts";
    rev = drupal6Revision;
    hash = "sha256-H+3KSsm7FsSGDUp0RXCBzDfC0ah2LWD9RZd5R4wUnvo=";
  };

  mkDrupal6TestSource = { pname, webRoot ? false }:
    pkgs.stdenv.mkDerivation {
      inherit pname;
      version = "6.x-${builtins.substring 0 8 drupal6Revision}";
      src = drupal6Source;

      installPhase =
        if webRoot then ''
          mkdir -p $out/web
          cp -r . $out/web/
          mkdir -p $out/web/sites/default/files
          printf '%s\n' web-root-layout-seed > $out/web/sites/default/files/web-root-layout-seed.txt
        '' else ''
          mkdir -p $out
          cp -r . $out/
          mkdir -p $out/sites/default/files
          printf '%s\n' root-layout-seed > $out/sites/default/files/root-layout-seed.txt
        '';
    };

  baseModules = [
    ({ ... }: {
      hostenv = {
        organisation = "test";
        project = "test-project";
        root = drupalRoot;
        hostenvHostname = "hosting.test";
      };
    })
    ./integration/drupal/hostenv.nix
  ];

  mkLaravelEnvironment = { major, source, dependencyHash, environmentName ? "main", extraModule ? { } }:
    makeHostenv [
      ({ ... }: {
        hostenv = {
          organisation = "test";
          project = "laravel${toString major}";
          root = source;
          hostenvHostname = "hosting.test";
        };
        services.laravel = {
          codebase.name = "laravel${toString major}";
          composer.dependencyHash = dependencyHash;
        };
      })
      ./integration/laravel/hostenv.nix
      extraModule
    ]
      environmentName;
in
{
  drupalDev = makeHostenv baseModules "dev";

  drupalProduction = makeHostenv baseModules "main";

  drupal7 =
    let
      drupal7src = pkgs.stdenv.mkDerivation {
        pname = "drupal7-test-source";
        version = "7.103";

        src = pkgs.fetchurl {
          url = "https://ftp.drupal.org/files/projects/drupal-7.103.tar.gz";
          sha256 = "sha256-PYoM7tJzsHhyLbXYOX461xEl2dQ4+Y9RWX3EYmrOSfU=";
        };

        installPhase = ''
          mkdir -p $out
          cp -r . $out/
        '';
      };
    in
    makeHostenv [
      ({ ... }: {
        hostenv = {
          organisation = "test";
          project = "test-project";
          root = drupal7src;
          hostenvHostname = "hosting.test";
        };
      })
      ./integration/drupal7/hostenv.nix
    ] "main";

  drupal6 =
    let
      drupal6src = mkDrupal6TestSource {
        pname = "drupal6-test-source";
      };
    in
    makeHostenv [
      ({ ... }: {
        hostenv = {
          organisation = "test";
          project = "test-project";
          root = drupal6src;
          hostenvHostname = "hosting.test";
        };
      })
      ./integration/drupal6/hostenv.nix
    ] "main";

  drupal6WebRoot =
    let
      drupal6src = mkDrupal6TestSource {
        pname = "drupal6-web-root-test-source";
        webRoot = true;
      };
    in
    makeHostenv [
      ({ ... }: {
        hostenv = {
          organisation = "test";
          project = "test-project";
          root = drupal6src;
          hostenvHostname = "hosting.test";
        };
      })
      ./integration/drupal6/hostenv.nix
    ] "main";

  laravel10 = mkLaravelEnvironment {
    major = 10;
    source = laravelSources.laravel10;
    dependencyHash = "sha256-ZlFQXrsLyvUwSOAVJk/lbYNXqEqIJd4BX3nYi6xTj4w=";
  };

  laravel11 = mkLaravelEnvironment {
    major = 11;
    source = laravelSources.laravel11;
    dependencyHash = "sha256-nShTGWFXHpyioJExTpnS/EhVGMpB5ikaJjvGGl3zFDU=";
  };

  laravel12 = mkLaravelEnvironment {
    major = 12;
    source = laravelSources.laravel12;
    dependencyHash = "sha256-djftix9X6LjZaAROnZEgwXUxZ9UoszBevDDE6w6noIU=";
    extraModule = { ... }: {
      services.laravel = {
        healthCheckPath = "/up";
        optimize.enable = true;
        queue.workers = {
          priority = {
            connection = "database";
            queues = [ "high" "default" ];
            processes = 2;
            sleep = 2;
            timeout = 75;
            maxLifetime = 1800;
            tries = 5;
            stopTimeout = 120;
          };
          external = {
            connection = "sqs";
            processes = 1;
          };
        };
      };
    };
  };

  laravelDev = mkLaravelEnvironment {
    major = 12;
    source = laravelSources.laravel12;
    dependencyHash = "sha256-djftix9X6LjZaAROnZEgwXUxZ9UoszBevDDE6w6noIU=";
    environmentName = "dev";
  };

  gotenbergA = makeHostenv [
    ({ ... }: {
      hostenv = {
        organisation = "test";
        project = "gotenberg-a";
        root = pkgs.emptyDirectory;
        hostenvHostname = "hosting.test";
      };
      services.gotenberg.enable = true;
      environments.main.enable = true;
    })
  ] "main";

  gotenbergB = makeHostenv [
    ({ ... }: {
      hostenv = {
        organisation = "test";
        project = "gotenberg-b";
        root = pkgs.emptyDirectory;
        hostenvHostname = "hosting.test";
      };
      services.gotenberg.enable = true;
      environments.main.enable = true;
    })
  ] "main";

  # A service that cannot obtain a private namespace must refuse to start,
  # rather than expose its TCP listener on the host network.
  gotenbergWithoutNetworkNamespace = makeHostenv [
    ({ lib, ... }: {
      hostenv = {
        organisation = "test";
        project = "gotenberg-unisolated";
        root = pkgs.emptyDirectory;
        hostenvHostname = "hosting.test";
      };
      services.gotenberg.enable = true;
      # Deny clone/unshare at service runtime to exercise failed isolation.
      systemd.services.gotenberg.serviceConfig.RestrictNamespaces = true;
      environments.main.enable = true;
    })
  ] "main";

  laravelSecretExclusion = makeHostenv [
    ({ ... }: {
      hostenv = {
        organisation = "test";
        project = "laravelsecret";
        root = laravelSecretSource;
        hostenvHostname = "hosting.test";
      };
      services.laravel = {
        enable = true;
        composer.enable = false;
        migrations.enable = false;
        scheduler.enable = false;
      };
      environments.main = {
        enable = true;
        type = "production";
      };
    })
  ] "main";
}
