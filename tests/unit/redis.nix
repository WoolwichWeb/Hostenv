{ pkgs, hostenv }:
let
  lib = pkgs.lib;
  support = import ../support { inherit pkgs lib; };
  asserts = support.asserts;
  redisModule = hostenv.lib.hostenv.modules.redis;

  eval = support.evalWithBase {
    modules = [
      redisModule
      ({ ... }: {
        hostenv = {
          dataDir = "/home/redistest/.local/share";
          runtimeDir = "/run/hostenv/user/redistest";
        };
        services.redis = {
          enable = true;
          # Hostenv's socket-only directives must win over conflicting extras.
          extraConfig = ''
            port 6379
            tls-port 6380
            rdma-port 6390
            cluster-enabled yes
            cluster-port 16379
          '';
        };
      })
    ];
  };

  cfg = eval.config.services.redis;
  service = eval.config.systemd.services.redis;

  contractChecks = [
    {
      name = "services.redis.package";
      expected = toString pkgs.valkey;
      actual = toString cfg.package;
      passed = cfg.package == pkgs.valkey;
    }
    {
      name = "services.redis.dataDir";
      expected = "/home/redistest/.local/share/redis";
      actual = cfg.dataDir;
      passed = cfg.dataDir == "/home/redistest/.local/share/redis";
    }
    {
      name = "services.redis.socket";
      expected = "/run/hostenv/user/redistest/redis.sock";
      actual = cfg.socket;
      passed = cfg.socket == "/run/hostenv/user/redistest/redis.sock";
    }
    {
      name = "services.redis.appendOnly";
      expected = "true";
      actual = lib.boolToString cfg.appendOnly;
      passed = cfg.appendOnly;
    }
    {
      name = "systemd.services.redis.wantedBy";
      expected = builtins.toJSON [ "default.target" ];
      actual = builtins.toJSON service.wantedBy;
      passed = service.wantedBy == [ "default.target" ];
    }
    {
      name = "systemd.services.redis.serviceConfig.Type";
      expected = "notify";
      actual = service.serviceConfig.Type;
      passed = service.serviceConfig.Type == "notify";
    }
    {
      name = "systemd.services.redis.serviceConfig.Restart";
      expected = "on-failure";
      actual = service.serviceConfig.Restart;
      passed = service.serviceConfig.Restart == "on-failure";
    }
    {
      name = "systemd.services.redis.serviceConfig.TimeoutStartSec";
      expected = "infinity";
      actual = service.serviceConfig.TimeoutStartSec;
      passed = service.serviceConfig.TimeoutStartSec == "infinity";
    }
    {
      name = "systemd.services.redis.serviceConfig.TimeoutStopSec";
      expected = "infinity";
      actual = service.serviceConfig.TimeoutStopSec;
      passed = service.serviceConfig.TimeoutStopSec == "infinity";
    }
    {
      name = "systemd.services.redis.serviceConfig.UMask";
      expected = "0077";
      actual = service.serviceConfig.UMask;
      passed = service.serviceConfig.UMask == "0077";
    }
    {
      name = "systemd.services.redis.script";
      expected = "contains /bin/valkey-server";
      actual = "does not contain /bin/valkey-server";
      passed = lib.hasInfix "/bin/valkey-server" service.script;
    }
    {
      name = "systemd.services.redis.preStart";
      expected = "contains ${cfg.socket}";
      actual = "does not contain ${cfg.socket}";
      passed = lib.hasInfix cfg.socket service.preStart;
    }
    {
      name = "systemd.services.redis.postStart";
      expected = "contains ${cfg.socket}";
      actual = "does not contain ${cfg.socket}";
      passed = lib.hasInfix cfg.socket service.postStart;
    }
    {
      name = "systemd.services.redis.postStop";
      expected = "contains ${cfg.socket}";
      actual = "does not contain ${cfg.socket}";
      passed = lib.hasInfix cfg.socket service.postStop;
    }
    {
      name = "profile";
      expected = "contains ${cfg.package}";
      actual = "does not contain ${cfg.package}";
      passed = lib.elem cfg.package eval.config.profile;
    }
  ];

  failedContracts = builtins.filter (check: !check.passed) contractChecks;
  contractFailure =
    "Redis service contract failed:\n"
    + lib.concatMapStringsSep "\n" (check: ''
      - ${check.name}
        expected: ${check.expected}
        actual:   ${check.actual}
    '') failedContracts;
in
{
  redis-service-contract = asserts.assertTrue "redis-service-contract" (
    failedContracts == [ ]
  ) contractFailure;

  redis-generated-config =
    pkgs.runCommand "redis-generated-config" { nativeBuildInputs = [ pkgs.gnugrep ]; }
      ''
        set -euo pipefail

        config_file=${lib.escapeShellArg cfg.configFile}

        fail_config() {
          message="$1"
          printf 'Redis generated config contract failed: %s\n' "$message" >&2
          printf 'Generated config: %s\n' "$config_file" >&2
          ${pkgs.coreutils}/bin/nl -ba "$config_file" >&2
          printf 'Failure summary: %s (config: %s)\n' "$message" "$config_file" >&2
          exit 1
        }

        expect_line() {
          expected="$1"
          if ! grep -Fxq -- "$expected" "$config_file"; then
            fail_config "expected line not found: $expected"
          fi
        }

        expect_last_directive() {
          directive="$1"
          expected="$2"
          actual="$(grep "^$directive " "$config_file" | tail -n 1 || true)"
          if [ "$actual" != "$expected" ]; then
            fail_config "last $directive directive should be '$expected', got '$actual'"
          fi
        }

        expect_line 'port 6379'
        expect_line 'port 0'
        expect_last_directive port 'port 0'
        expect_line 'tls-port 6380'
        expect_line 'tls-port 0'
        expect_last_directive tls-port 'tls-port 0'
        expect_line 'rdma-port 6390'
        expect_line 'rdma-port 0'
        expect_last_directive rdma-port 'rdma-port 0'
        expect_line 'cluster-enabled yes'
        expect_line 'cluster-enabled no'
        expect_last_directive cluster-enabled 'cluster-enabled no'
        expect_line 'unixsocket "${cfg.socket}"'
        expect_line 'unixsocketperm 0700'
        expect_line 'dir "${cfg.dataDir}"'
        expect_line 'appendonly yes'
        expect_line 'daemonize no'
        expect_line 'supervised systemd'
        expect_line 'logfile ""'

        runtime_dir="$(mktemp -d)"
        runtime_config="$runtime_dir/valkey.conf"
        runtime_socket="$runtime_dir/redis.sock"
        sed \
          -e "s|^unixsocket .*|unixsocket \"$runtime_socket\"|" \
          -e "s|^dir .*|dir \"$runtime_dir\"|" \
          -e 's|^supervised systemd$|supervised no|' \
          -e '/^rdma-port 6390$/d' \
          ${cfg.configFile} > "$runtime_config"

        ${cfg.package}/bin/valkey-server "$runtime_config" > "$runtime_dir/valkey.log" 2>&1 &
        server_pid=$!
        trap 'kill "$server_pid" 2>/dev/null || true' EXIT

        for _ in $(seq 1 50); do
          [ -S "$runtime_socket" ] && break
          sleep 0.1
        done

        if [ ! -S "$runtime_socket" ]; then
          cat "$runtime_dir/valkey.log" >&2
          echo "Valkey did not create its Unix socket" >&2
          exit 1
        fi

        fail_runtime() {
          printf 'Redis runtime contract failed: %s\n' "$1" >&2
          printf 'Valkey log:\n' >&2
          cat "$runtime_dir/valkey.log" >&2
          exit 1
        }

        if ! ping_output="$(${cfg.package}/bin/valkey-cli -s "$runtime_socket" ping 2>&1)"; then
          fail_runtime "valkey-cli ping failed: $ping_output"
        fi
        if [ "$ping_output" != PONG ]; then
          fail_runtime "valkey-cli ping should return PONG, got '$ping_output'"
        fi
        for port in 6379 6380 16379; do
          if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            echo "Valkey unexpectedly opened TCP port $port" >&2
            exit 1
          fi
        done
        if ! shutdown_output="$(${cfg.package}/bin/valkey-cli -s "$runtime_socket" shutdown nosave 2>&1)"; then
          fail_runtime "valkey-cli shutdown failed: $shutdown_output"
        fi
        if ! wait "$server_pid"; then
          fail_runtime "Valkey exited unsuccessfully after shutdown"
        fi
        trap - EXIT

        echo ok > "$out"
      '';
}
