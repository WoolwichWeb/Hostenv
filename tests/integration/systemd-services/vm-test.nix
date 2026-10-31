{ pkgs, env, hostenvNixosModule }:

let
  cfg = env.config;
  user = cfg.hostenv.userName;
  uid = 2000;
  home = "/home/${user}";
  profile = cfg.activatePackage;
  mysqlSocket = "${cfg.services.mysql.runtimeDir}/mysql.sock";
  postgresSocket = "${cfg.services.postgresql.runtimeDir}/.s.PGSQL.5432";
  phpSocket = cfg.services.phpfpm.pools.smoke.socket;
  nginxSocket = "${cfg.hostenv.upstreamRuntimeDir}/in.sock";

  phpScript = pkgs.writeText "hostenv-service-smoke.php" "<?php echo 'hostenv-php-ready';";
  phpRequest = pkgs.writeShellScript "hostenv-service-php-request" ''
    export SCRIPT_FILENAME=${phpScript}
    export SCRIPT_NAME=/smoke.php
    export REQUEST_METHOD=GET
    export QUERY_STRING=
    export SERVER_PROTOCOL=HTTP/1.1
    exec ${pkgs.fcgi}/bin/cgi-fcgi -bind -connect ${phpSocket}
  '';
in
pkgs.testers.runNixOSTest {
  name = "hostenv-systemd-services";

  nodes.machine = { ... }: {
    imports = [ hostenvNixosModule ];

    provider.plan.environments.${cfg.hostenv.environmentName} =
      cfg.environments.${cfg.hostenv.environmentName} // { inherit uid; };

    users.groups.nginx = { };

    environment.systemPackages = [ profile ];

    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
  };

  testScript = ''
    from datetime import timedelta
    from shlex import quote

    def as_user(command):
        return (
            "${pkgs.util-linux}/bin/runuser -u ${user} -- env "
            "HOME=${home} "
            "XDG_RUNTIME_DIR=/run/user/${toString uid} "
            "XDG_CONFIG_HOME=${home}/.config "
            "XDG_CACHE_HOME=${home}/.cache "
            "XDG_DATA_HOME=${home}/.local/share "
            "XDG_STATE_HOME=${home}/.local/state "
            + command
        )

    def control(command):
        return as_user("${pkgs.systemd}/bin/systemctl --user " + command)

    def mysql(sql):
        return as_user(
            "${profile}/bin/mysql --batch --skip-column-names --execute="
            + quote(sql)
        )

    def postgres(sql):
        return as_user(
            "${cfg.services.postgresql.package}/bin/psql "
            "-X -A -t -v ON_ERROR_STOP=1 -h ${cfg.services.postgresql.runtimeDir} "
            "-d postgres -c " + quote(sql)
        )

    mysql_probe = (
        mysql("SELECT marker FROM hostenv_lifecycle.sample WHERE id = 1")
        + " | grep -Fxq persistent"
    )
    postgres_probe = (
        postgres("SELECT marker FROM hostenv_lifecycle WHERE id = 1")
        + " | grep -Fxq persistent"
    )
    php_probe = as_user("${phpRequest}") + " | grep -Fq hostenv-php-ready"
    nginx_probe = (
        as_user(
            "${pkgs.curl}/bin/curl --noproxy '*' --fail --silent --show-error "
            "--max-time 10 --unix-socket " + quote("${nginxSocket}")
            + " --header " + quote("Host: services.hosting.test")
            + " http://localhost/"
        )
        + " | grep -Fxq hostenv-nginx-ready"
    )

    def wait_active(unit):
        machine.wait_until_succeeds(
            control("show -P ActiveState " + unit)
            + " | grep -Eq '^(active|failed)$'",
            timeout=timedelta(seconds=120),
        )
        state = machine.succeed(control("show -P ActiveState " + unit)).strip()
        if state != "active":
            _, details = machine.execute(control("status --no-pager -l " + unit))
            raise AssertionError(unit + " entered " + state + ":\n" + details)

    def ready(unit, probe):
        wait_active(unit)
        machine.wait_until_succeeds(
            probe, timeout=timedelta(seconds=120)
        )

    def cycle(unit, probe):
        previous_pid = machine.succeed(
            control("show -P MainPID " + unit)
        ).strip()
        assert previous_pid != "0", (unit, previous_pid)

        machine.succeed(control("stop " + unit))
        machine.wait_until_succeeds(
            control("show -P ActiveState " + unit) + " | grep -Fxq inactive",
            timeout=timedelta(seconds=60),
        )
        machine.succeed(
            control("show -P MainPID " + unit) + " | grep -Fxq 0"
        )
        machine.fail(probe)

        machine.succeed(control("start " + unit))
        ready(unit, probe)
        started_pid = machine.succeed(
            control("show -P MainPID " + unit)
        ).strip()
        assert started_pid not in ("0", previous_pid), (unit, started_pid)

        machine.succeed(control("restart " + unit))
        ready(unit, probe)
        restarted_pid = machine.succeed(
            control("show -P MainPID " + unit)
        ).strip()
        assert restarted_pid not in ("0", started_pid), (unit, restarted_pid)

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@${toString uid}.service")

    with subtest("activation fails when the user systemd manager is unreachable"):
        status, output = machine.execute(as_user(
            "env XDG_RUNTIME_DIR=/run/hostenv-no-user-manager "
            "${profile}/bin/activate"
        ))
        assert status != 0, "activation reported success without a user manager"
        assert "user systemd service manager is not running" in output, output

    with subtest("activate the real Hostenv systemd units"):
        machine.succeed(as_user("${profile}/bin/activate"))
        for unit in ["mysql.service", "postgresql.service", "phpfpm-smoke.service", "nginx.service"]:
            wait_active(unit)
        for socket in ["${mysqlSocket}", "${postgresSocket}", "${phpSocket}", "${nginxSocket}"]:
            machine.wait_until_succeeds(
                "test -S " + quote(socket),
                timeout=timedelta(seconds=120),
            )
        machine.succeed("test \"$(stat -c '%a' ${postgresSocket})\" = 770")

    with subtest("write persistent records to both databases"):
        machine.succeed(mysql(
            "CREATE DATABASE hostenv_lifecycle; "
            "CREATE TABLE hostenv_lifecycle.sample "
            "(id INT PRIMARY KEY, marker VARCHAR(50) NOT NULL); "
            "INSERT INTO hostenv_lifecycle.sample VALUES (1, 'persistent')"
        ))
        machine.succeed(postgres(
            "CREATE TABLE hostenv_lifecycle "
            "(id INTEGER PRIMARY KEY, marker TEXT NOT NULL); "
            "INSERT INTO hostenv_lifecycle VALUES (1, 'persistent')"
        ))

    with subtest("all four services respond"):
        for unit, probe in [
            ("mysql.service", mysql_probe),
            ("postgresql.service", postgres_probe),
            ("phpfpm-smoke.service", php_probe),
            ("nginx.service", nginx_probe),
        ]:
            ready(unit, probe)

    for unit, probe in [
        ("mysql.service", mysql_probe),
        ("postgresql.service", postgres_probe),
        ("phpfpm-smoke.service", php_probe),
        ("nginx.service", nginx_probe),
    ]:
        with subtest(unit + " stops, starts and restarts"):
            cycle(unit, probe)

    with subtest("other services remain available"):
        for unit, probe in [
            ("mysql.service", mysql_probe),
            ("postgresql.service", postgres_probe),
            ("phpfpm-smoke.service", php_probe),
            ("nginx.service", nginx_probe),
        ]:
            ready(unit, probe)
  '';
}
