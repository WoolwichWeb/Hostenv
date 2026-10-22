{ ... }:
{
  flake.modules.hostenv.gotenberg =
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.gotenberg;
      apiPort = config.systemd.services.gotenberg.endpoints.default.port;
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
        enable = lib.mkEnableOption "Gotenberg PDF conversion";
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
          default = if cfg.enable then
            config.systemd.services.gotenberg.endpoints.default.socket
          else "${config.hostenv.runtimeDir}/gotenberg.sock";
          description = "Unix socket for Gotenberg's HTTP API.";
        };
      };

      config = lib.mkIf cfg.enable {
        systemd.services.gotenberg =
          let
            start = pkgs.writeShellApplication {
              name = "gotenberg-start";
              runtimeInputs = [ pkgs.curl pkgs.coreutils ];
              text = ''
                # Gotenberg listens on a port inside a private network namespace.
                (
                  # The supervisor, not the converter, signals readiness.
                  unset NOTIFY_SOCKET
                  exec ${lib.getExe cfg.package} \
                    --api-bind-ip=127.0.0.1 \
                    --api-port=${toString apiPort} \
                    --api-disable-download-from
                ) &
                gotenberg_pid=$!

                # Called by the EXIT trap below, not by a direct function call.
                # shellcheck disable=SC2329
                cleanup() {
                  trap - EXIT
                  kill "$gotenberg_pid" 2>/dev/null || true
                  wait "$gotenberg_pid" 2>/dev/null || true
                }
                trap cleanup EXIT
                trap 'exit 0' TERM INT

                # The endpoint waits for this service to become ready
                # before forwarding.
                ready=0
                for _ in {1..60}; do
                  if ! kill -0 "$gotenberg_pid" 2>/dev/null; then
                    echo "Gotenberg exited before its HTTP API was ready." >&2
                    exit 1
                  fi
                  if curl --fail --silent --max-time 2 http://127.0.0.1:${toString apiPort}/health >/dev/null 2>&1; then
                    ready=1
                    break
                  fi
                  sleep 1
                done
                if [ "$ready" -ne 1 ]; then
                  echo "Gotenberg did not become healthy." >&2
                  exit 1
                fi
                ${config.systemd.package}/bin/systemd-notify --ready

                if wait "$gotenberg_pid"; then
                  echo "Gotenberg exited unexpectedly." >&2
                  exit 1
                else
                  exit "$?"
                fi
              '';
            };
          in
          {
            description = "Gotenberg PDF conversion";
            path = [ cfg.package ];
            endpoints.default.port = lib.mkDefault 3000;
            hostenv.network.isolated = true;
            serviceConfig = {
              Type = "notify";
              NotifyAccess = "all";
              ExecStart = lib.getExe start;
              PrivateTmp = true;
              RuntimeDirectory = "gotenberg";
              WorkingDirectory = "%t/gotenberg";
              Environment = [
                "HOME=%t/gotenberg"
                "CHROMIUM_BIN_PATH=${lib.getExe cfg.chromium.package}"
                "LIBREOFFICE_BIN_PATH=${cfg.libreoffice.package}/lib/libreoffice/program/soffice.bin"
                "FONTCONFIG_FILE=${fonts}"
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
