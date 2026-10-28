{ pkgs, service }:
pkgs.writeShellScriptBin "hostenv-provider-service-dev" ''
  set -euo pipefail
  export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.postgresql pkgs.socat ]}:"$PATH"

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

  ${service}/bin/hostenv-provider-service "$@"
''
