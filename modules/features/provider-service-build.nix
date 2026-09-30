{ inputs, lib, config, ... }:
let
  fp = inputs.flake-parts.lib;
  cfgTop = config;
  providerEnabled = config.provider.enable or false;
in
{
  options.perSystem = fp.mkPerSystemOption ({ config, pkgs, ... }:
    let
      providerService = cfgTop.flake.lib.provider.service;
      packageNames = providerService.haskellDeps;
      serviceSrc = providerService.src;
      ghc =
        (pkgs.haskellPackages.ghcWithPackages.override {
          installDocumentation = config.documentation.haskell.dependencies.enable;
        })
          (p: map (name: p.${name}) packageNames);
      servicePkg = pkgs.writeShellScriptBin "hostenv-provider-service" ''
        exec ${ghc}/bin/runghc -i${serviceSrc} ${serviceSrc}/Main.hs "$@"
      '';

      # Quick hacky way to try out the provider service using a browser on local.
      servicePkgDev = pkgs.writeShellScriptBin "hostenv-provider-service-dev" ''
        set -euo pipefail

        base="''${HOSTENV_PROVIDER_DEV_DIR:-/tmp/hostenv-provider-dev}"
        pgdata="$base/pgdata"
        listen_socket="$base/hostenv-provider.sock"
        mkdir -p "$base"

        if [ ! -s "$pgdata/PG_VERSION" ]; then
          initdb -D "$pgdata" -A trust >/dev/null
        fi

        pg_ctl -D "$pgdata" -o "-k $base" -l "$base/postgres.log" start >/dev/null
        cleanup() {
          if [ -n "''${socat_pid:-}" ]; then
            kill "$socat_pid" >/dev/null 2>&1 || true
          fi
          pg_ctl -D "$pgdata" stop >/dev/null || true
        }
        trap cleanup EXIT

        createdb -h "$base" hostenv-provider >/dev/null 2>&1 || true

        secrets="$base/gitlab_oauth"
        if [ ! -f "$secrets" ]; then
          printf "client_id=dev\nclient_secret=dev\n" > "$secrets"
        fi

        if [ -n "''${HOSTENV_PROVIDER_HTTP_PORT:-}" ]; then
          socat TCP-LISTEN:"$HOSTENV_PROVIDER_HTTP_PORT",fork,reuseaddr UNIX-CONNECT:"$listen_socket" &
          socat_pid=$!
          echo "Proxying http://localhost:$HOSTENV_PROVIDER_HTTP_PORT to Unix socket $listen_socket" >&2
        fi

        # The lack of parameters here is temporary, and will be resolved once
        # provider-service is complete.
        ${servicePkg}/bin/hostenv-provider-service "$@"
      '';
    in
    {
      config = lib.mkIf providerEnabled {
        packages.hostenv-provider-service = servicePkg;
        apps.hostenv-provider-service = {
          type = "app";
          program = "${servicePkg}/bin/hostenv-provider-service";
          meta.description = "Hostenv provider service development app";
        };
        hostenv.haskell.devPackages = packageNames;
        devshells.default.devshell.packages = [ servicePkg servicePkgDev ];
      };
    });
}
