{ ... }:
{
  flake.modules.hostenv.gotenberg =
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.gotenberg;
      fonts = pkgs.makeFontsConf {
        fontDirectories = [
          pkgs.liberation_ttf_v2
          pkgs.carlito
          pkgs.caladea
          pkgs.dejavu_fonts
          pkgs.noto-fonts
          pkgs.noto-fonts-color-emoji
          pkgs.noto-fonts-cjk-sans
          pkgs.noto-fonts-cjk-serif
        ] ++ cfg.extraFontPackages;
      };
    in
    {
      options.services.gotenberg = {
        enable = lib.mkEnableOption "Gotenberg PDF conversion over a private Unix socket";
        package = lib.mkPackageOption pkgs "gotenberg" { };
        chromium.package = lib.mkPackageOption pkgs "chromium" { };
        libreoffice.package = lib.mkPackageOption pkgs "libreoffice" { };
        extraFontPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Additional fonts available to Gotenberg.";
        };
        socket = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          internal = true;
          default = "${config.hostenv.runtimeDir}/gotenberg.sock";
          description = "Unix socket for Gotenberg's HTTP API.";
        };
      };

      config = lib.mkIf cfg.enable {
        systemd.sockets.gotenberg = {
          description = "Gotenberg HTTP Unix socket";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = cfg.socket;
            SocketMode = "0600";
            RemoveOnStop = true;
          };
        };

        # Normally, Gotenberg and its socket proxy could run as separate
        # systemd services sharing a private network namespace. However,
        # JoinsNamespaceOf= does not reliably work for user services
        # (systemd/systemd#29429). Therefore, we start both processes in
        # one service, allowing them to share the namespace.
        systemd.services.gotenberg =
          let
            start = pkgs.writeShellApplication {
              name = "gotenberg-start";
              runtimeInputs = [
                pkgs.curl
                pkgs.coreutils
              ];
              text = ''
                # Gotenberg cannot serve requests unless systemd passed the
                # listening Unix socket. Diagnose missing socket activation
                # before spawning either long-lived process.
                if [ "''${LISTEN_FDS:-0}" != 1 ] || [ ! -S /proc/self/fd/3 ]; then
                  echo "Gotenberg: expected one inherited systemd socket on fd 3." >&2
                  exit 1
                fi

                # Start Gotenberg in the background, without inheriting the systemd
                # socket-activation variables or listening socket (file descriptor 3).
                #
                # Gotenberg listens on TCP port 3000 inside its private network
                # namespace. systemd-socket-proxyd receives requests through the
                # Unix socket and forwards them to that TCP port. Therefore
                # Gotenberg does not need to know about the Unix socket.
                (
                  unset LISTEN_FDS LISTEN_PID LISTEN_PIDFDID LISTEN_FDNAMES NOTIFY_SOCKET
                  exec ${lib.getExe cfg.package} \
                    --api-bind-ip=127.0.0.1 \
                    --api-port=3000 \
                    --api-disable-download-from
                ) 3<&- &
                gotenberg_pid=$!
                proxy_pid=

                # Called by the EXIT trap below, not by a direct function call.
                # shellcheck disable=SC2329
                cleanup() {
                  trap - EXIT
                  if [ -n "$proxy_pid" ]; then
                    kill "$proxy_pid" 2>/dev/null || true
                  fi
                  kill "$gotenberg_pid" 2>/dev/null || true
                  if [ -n "$proxy_pid" ]; then
                    wait "$proxy_pid" 2>/dev/null || true
                  fi
                  wait "$gotenberg_pid" 2>/dev/null || true
                }
                trap cleanup EXIT
                trap 'exit 0' TERM INT

                # Accept connections only after the backend is ready.
                ready=0
                for _ in {1..60}; do
                  if ! kill -0 "$gotenberg_pid" 2>/dev/null; then
                    echo "Gotenberg exited before its HTTP API was ready." >&2
                    exit 1
                  fi
                  if curl --fail --silent --max-time 2 http://127.0.0.1:3000/health >/dev/null 2>&1; then
                    ready=1
                    break
                  fi
                  sleep 1
                done
                if [ "$ready" -ne 1 ]; then
                  echo "Gotenberg did not become healthy." >&2
                  exit 1
                fi

                # sd_listen_fds() verifies both LISTEN_PID and (since systemd
                # 259) LISTEN_PIDFDID. The latter identifies systemd's original
                # service process, not our child. Clear that stale identity and
                # set the PID of the proxy before passing along fd 3.
                (
                  unset LISTEN_PIDFDID
                  export LISTEN_PID="$BASHPID"
                  exec ${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:3000
                ) &
                proxy_pid=$!

                # If either child exits, stop both and let systemd restart the
                # entire service (and therefore recreate its network namespace).
                if wait -n "$gotenberg_pid" "$proxy_pid"; then
                  echo "Gotenberg or its socket proxy exited unexpectedly." >&2
                  exit 1
                else
                  exit "$?"
                fi
              '';
            };

            # Enable loopback inside the private network namespace, then drop
            # the capabilities needed to configure it.
            isolate = pkgs.writeShellApplication {
              name = "gotenberg-isolate";
              runtimeInputs = [
                pkgs.iproute2
                pkgs.util-linux
              ];
              text = ''
                ip link set lo up
                exec setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all ${lib.getExe start}
              '';
            };
          in
          {
            description = "Gotenberg PDF conversion";
            path = [ cfg.package ];
            requires = [ "gotenberg.socket" ];
            after = [ "gotenberg.socket" ];
            serviceConfig = {
              Type = "notify";
              NotifyAccess = "all";
              # If PrivateNetwork= fails to establish a network namespace for a
              # user service, systemd may continue starting it without isolation.
              # That would expose Gotenberg's TCP listener on the host's loopback
              # interface. Use unshare instead, so Gotenberg cannot start unless
              # its private network namespace has been created successfully.
              ExecStart = "${pkgs.util-linux}/bin/unshare --user --map-current-user --keep-caps --net ${lib.getExe isolate}";
              PrivateTmp = true;
              RuntimeDirectory = "gotenberg";
              WorkingDirectory = "%t/gotenberg";
              Environment = [
                "HOME=%t/gotenberg"
                "CHROMIUM_BIN_PATH=${lib.getExe cfg.chromium.package}"
                "LIBREOFFICE_BIN_PATH=${cfg.libreoffice.package}/lib/libreoffice/program/soffice.bin"
                "FONTCONFIG_FILE=${fonts}"
                # Gotenberg 8.36 defaults to exporting telemetry even without
                # a collector; do not attempt connections to localhost:4318.
                "OTEL_TRACES_EXPORTER=none"
                "OTEL_METRICS_EXPORTER=none"
                "OTEL_LOGS_EXPORTER=none"
              ];
              Restart = "on-failure";
              RestartSec = "2s";
            };
          };
      };
    };
}
