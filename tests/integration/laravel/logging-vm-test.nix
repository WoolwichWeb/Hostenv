{ pkgs, env, hostenvNixosModule }:

let
  cfg = env.config;
  profile = cfg.activatePackage;
  laravel = cfg.services.laravel;
  pool = laravel.codebase.name;
  user = cfg.hostenv.userName;
  uid = 2000;
  home = "/home/${user}";
  app = "${profile}/share/php/${pool}";
  fpmUnit = "phpfpm-${pool}.service";
  fpmSocket = cfg.services.phpfpm.pools.${pool}.socket;

  # Run Laravel itself inside PHP-FPM, rather than a standalone PHP
  # syslog() call. This uses the packaged application's logging config.
  loggingRequest = pkgs.writeText "hostenv-laravel-logging.php" ''<?php
    chdir("${app}");
    require "${app}/vendor/autoload.php";
    $app = require "${app}/bootstrap/app.php";
    $app->make(\Illuminate\Contracts\Console\Kernel::class)->bootstrap();

    $phase = isset($_GET["phase"]) ? preg_replace("/[^A-Za-z0-9_-]/", "", $_GET["phase"]) : "unknown";
    $channel = config("logging.default");
    if ($channel !== "syslog") {
        http_response_code(500);
        echo "Unexpected Laravel log channel: $channel\n";
        exit;
    }

    \Illuminate\Support\Facades\Log::error("HOSTENV_LARAVEL_SYSLOG_" . strtoupper($phase));
    error_log("HOSTENV_PHP_ERROR_" . strtoupper($phase));
    header("Content-Type: text/plain");
    echo "laravel_channel=$channel\n";
    echo "laravel_logged=$phase\n";
  '';

  systemctlUser = pkgs.writeShellScript "laravel-logging-systemctl-user" ''
    export HOME=${home}
    export XDG_RUNTIME_DIR=/run/user/${toString uid}
    exec ${pkgs.systemd}/bin/systemctl --user "$@"
  '';

  journalctlUser = pkgs.writeShellScript "laravel-logging-journalctl-user" ''
    export HOME=${home}
    export XDG_RUNTIME_DIR=/run/user/${toString uid}
    exec ${pkgs.systemd}/bin/journalctl --user "$@"
  '';

  request = pkgs.writeShellScript "laravel-logging-fastcgi-request" ''
    set -euo pipefail
    phase="$1"

    export SCRIPT_FILENAME=${loggingRequest}
    export SCRIPT_NAME=/hostenv-laravel-logging.php
    export REQUEST_METHOD=GET
    export QUERY_STRING="phase=$phase"
    export REQUEST_URI="/hostenv-laravel-logging.php?phase=$phase"
    export SERVER_PROTOCOL=HTTP/1.1

    exec ${pkgs.fcgi}/bin/cgi-fcgi -bind -connect ${fpmSocket}
  '';
in
pkgs.testers.runNixOSTest {
  name = "laravel-syslog-vm-test";

  nodes.machine = { ... }: {
    imports = [ hostenvNixosModule ];

    provider.plan.environments.${cfg.hostenv.environmentName} =
      cfg.environments.${cfg.hostenv.environmentName} // { inherit uid; };

    users.groups.nginx = { };

    environment.systemPackages = [
      pkgs.fcgi
      profile
    ];

    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
  };

  testScript = ''
    from datetime import timedelta

    def as_user(command):
        return "${pkgs.util-linux}/bin/runuser -u ${user} -- " + command

    def service(command):
        return as_user("${systemctlUser} " + command)

    def show_diagnostics(phase):
        print("PHP-FPM logging diagnostics (" + phase + "):")
        # Include both the Laravel and native PHP error messages.
        marker = "HOSTENV_"
        sources = [
            ("environment syslog messages",
             "journalctl _UID=${toString uid} --no-pager --output=short-precise --grep=" + marker),
            ("PHP-FPM user journal",
             as_user("${journalctlUser} -u ${fpmUnit} --no-pager --output=short-precise --grep=" + marker)),
            ("recent environment messages",
             "journalctl _UID=${toString uid} --no-pager -n 50"),
            ("PHP-FPM unit status",
             service("status --no-pager -l ${fpmUnit}")),
        ]
        for label, command in sources:
            status, output = machine.execute(command)
            print(label + " (exit " + str(status) + "):\n" + output)

    def check_request(phase):
        response = machine.succeed("${request} " + phase)
        print("Laravel FastCGI response (" + phase + "):\n" + response)
        assert "laravel_channel=syslog" in response, response
        assert "laravel_logged=" + phase in response, response

        markers = [
            "HOSTENV_LARAVEL_SYSLOG_" + phase.upper(),
            "HOSTENV_PHP_ERROR_" + phase.upper(),
        ]
        try:
            for marker in markers:
                # Both Laravel and native PHP errors must reach the system
                # journal and be visible to the environment owner.
                machine.wait_until_succeeds(
                    "journalctl _UID=${toString uid} --no-pager --grep=" + marker,
                    timeout=timedelta(seconds=20),
                )
                machine.wait_until_succeeds(
                    as_user("${journalctlUser} -u ${fpmUnit} --no-pager --grep=" + marker),
                    timeout=timedelta(seconds=20),
                )
        except Exception:
            show_diagnostics(phase)
            raise

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@${toString uid}.service")
    machine.succeed("test -d ${cfg.hostenv.runtimeDir}")

    with subtest("prepare the Laravel fixture and its PHP-FPM user unit"):
        machine.succeed(
            "grep -Fq 'LOG_CHANNEL=\"syslog\"' ${app}/.env"
        )
        machine.succeed(
            "grep -Fq 'php_admin_value[error_log] = syslog' "
            "${profile}/etc/php-fpm.d/${pool}.conf"
        )

        # FPM reads laravel_env through EnvironmentFile=, just as it does
        # when deployed by the provider. This is a test-only APP_KEY.
        machine.succeed(
            "install -d -m 0750 -o root -g ${user} /run/secrets/${user}"
        )
        machine.succeed(
            "printf '%s\\n' "
            "'APP_KEY=base64:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=' "
            "> /run/secrets/${user}/laravel_env"
        )
        machine.succeed(
            "chown root:${user} /run/secrets/${user}/laravel_env && "
            "chmod 0640 /run/secrets/${user}/laravel_env"
        )

        # Laravel's project and bootstrap/cache are read-only Nix store
        # paths. Prepare only its persistent writable directories.
        machine.succeed(
            as_user(
                "${pkgs.coreutils}/bin/mkdir -p "
                "${laravel.storageDir}/logs "
                "${laravel.storageDir}/framework/cache/data "
                "${laravel.storageDir}/framework/sessions "
                "${laravel.storageDir}/framework/views "
                "${laravel.bootstrapCacheDir} "
                "${home}/.config/systemd"
            )
        )

        # Install the real generated unit into the running systemd user
        # manager without running unrelated DB, backup or migration steps.
        machine.succeed(
            as_user(
                "${pkgs.coreutils}/bin/ln -s "
                "${profile}/systemd/user ${home}/.config/systemd/user"
            )
        )
        machine.succeed(service("daemon-reload"))
        machine.succeed(service("start ${fpmUnit}"))
        machine.wait_until_succeeds(
            service("is-active --quiet ${fpmUnit}"),
            timeout=timedelta(seconds=60),
        )
        machine.wait_until_succeeds(
            "test -S ${fpmSocket}",
            timeout=timedelta(seconds=60),
        )

    with subtest("Laravel Log::error reaches journald through PHP-FPM"):
        check_request("first")

    with subtest("Laravel logs still reach journald after PHP-FPM restarts"):
        before = machine.succeed(service("show -P MainPID ${fpmUnit}")).strip()
        machine.succeed(service("restart ${fpmUnit}"))
        machine.wait_until_succeeds(
            service("is-active --quiet ${fpmUnit}"),
            timeout=timedelta(seconds=60),
        )
        machine.wait_until_succeeds(
            "test -S ${fpmSocket}",
            timeout=timedelta(seconds=60),
        )
        after = machine.succeed(service("show -P MainPID ${fpmUnit}")).strip()
        assert before != after and after != "0", (before, after)
        check_request("restarted")
  '';
}
