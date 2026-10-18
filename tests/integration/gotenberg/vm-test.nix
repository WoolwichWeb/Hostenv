{ pkgs, environments, hostenvNixosModule }:
let
  a = (builtins.elemAt environments 0).config;
  b = (builtins.elemAt environments 1).config;
  unisolated = (builtins.elemAt environments 2).config;

  env = cfg: uid: {
    name = cfg.hostenv.userName;
    value = cfg.environments.main // {
      hostenv = cfg.hostenv;
      inherit uid;
    };
  };

  fixture = pkgs.writeText "gotenberg-fixture.html" ''
    <html><body><h1>Hostenv PDF test</h1></body></html>
  '';

  libreofficeFixture = pkgs.writeText "gotenberg-fixture.rtf" ''
    {\rtf1\ansi\deff0
    {\fonttbl{\f0\fnil Liberation Sans;}}
    \f0\fs24 Hostenv LibreOffice PDF test\par
    }
  '';

  # Test-only client: the application and the listener share a private
  # network namespace. The listener forwards TCP to Gotenberg's Unix socket.
  reverseProxyClient = pkgs.writeShellApplication {
    name = "gotenberg-reverse-proxy-client-test";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.util-linux
    ];
    text = ''
      if [ "$#" -ne 2 ]; then
        echo "Expected Gotenberg socket and test state directory." >&2
        exit 1
      fi
      socket=$1
      state=$2
      mkdir -p "$state"
      printf '%s\n' "$BASHPID" > "$state/pid"
      readlink /proc/self/ns/net > "$state/namespace"

      # The normal systemd socket manager would bind outside this namespace.
      # Use its test utility to open port 3000 *inside* the namespace instead.
      setsid ${pkgs.systemd}/bin/systemd-socket-activate \
        --listen=127.0.0.1:3000 \
        ${pkgs.systemd}/lib/systemd/systemd-socket-proxyd "$socket" \
        > "$state/proxy.log" 2>&1 &
      listener_pid=$!
      printf '%s\n' "$listener_pid" > "$state/listener.pid"
      # Stop both the listener and its socket-activated child.
      trap 'kill -TERM -- "-$listener_pid" 2>/dev/null || true; wait "$listener_pid" 2>/dev/null || true' EXIT

      ready=0
      for _ in {1..100}; do
        if ss -H -ltn 'sport = :3000' | grep -Fq '127.0.0.1:3000'; then
          ready=1
          break
        fi
        if ! kill -0 "$listener_pid" 2>/dev/null; then
          cat "$state/proxy.log" >&2
          exit 1
        fi
        sleep 0.1
      done
      if [ "$ready" -ne 1 ]; then
        echo "Client proxy did not start listening." >&2
        cat "$state/proxy.log" >&2
        exit 1
      fi
      touch "$state/ready"

      # Let the VM inspect both client namespaces before sending requests.
      for _ in {1..300}; do
        if [ -e "$state/go" ]; then break; fi
        sleep 0.1
      done
      if [ ! -e "$state/go" ]; then
        echo "Client test did not receive the go signal." >&2
        exit 1
      fi

      # No --unix-socket option: this is ordinary HTTP over loopback TCP.
      curl --noproxy '*' --fail --silent --show-error \
        --connect-timeout 3 --max-time 30 \
        http://127.0.0.1:3000/health > "$state/health"
      curl --noproxy '*' --fail --silent --show-error \
        --connect-timeout 3 --max-time 120 \
        -F 'files=@${libreofficeFixture};filename=document.rtf;type=application/rtf' \
        http://127.0.0.1:3000/forms/libreoffice/convert \
        -o "$state/document.pdf"
      touch "$state/done"

      for _ in {1..300}; do
        if [ -e "$state/stop" ]; then exit 0; fi
        sleep 0.1
      done
      echo "Client test did not receive the stop signal." >&2
      exit 1
    '';
  };

  reverseProxyNamespace = pkgs.writeShellApplication {
    name = "gotenberg-reverse-proxy-isolate-test";
    runtimeInputs = [ pkgs.iproute2 pkgs.util-linux ];
    text = ''
      ip link set lo up
      exec setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
        ${pkgs.lib.getExe reverseProxyClient} "$@"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "gotenberg-private-socket";

  nodes.machine = { ... }: {
    imports = [ hostenvNixosModule ];

    provider.plan.environments = builtins.listToAttrs [
      (env a 2000)
      (env b 2001)
      (env unisolated 2002)
    ];

    environment.systemPackages = [
      a.activatePackage
      b.activatePackage
      unisolated.activatePackage
      pkgs.curl
      pkgs.procps
      pkgs.util-linux
      reverseProxyNamespace
    ];

    virtualisation = {
      cores = 2;
      memorySize = 4096;
    };
  };

  testScript = ''
    from datetime import timedelta

    a = ("${a.hostenv.userName}", 2000, "${a.activatePackage}", "${a.services.gotenberg.socket}")
    b = ("${b.hostenv.userName}", 2001, "${b.activatePackage}", "${b.services.gotenberg.socket}")
    unisolated = ("${unisolated.hostenv.userName}", 2002, "${unisolated.activatePackage}", "${unisolated.services.gotenberg.socket}")
    proxy_units = {
        2000: "${a.systemd.services.gotenberg.endpoints.default.proxyUnit}",
        2001: "${b.systemd.services.gotenberg.endpoints.default.proxyUnit}",
        2002: "${unisolated.systemd.services.gotenberg.endpoints.default.proxyUnit}",
    }

    def as_user(env, command):
        user, uid, _, _ = env
        home = "/home/" + user
        return (
            "runuser -u " + user + " -- env HOME=" + home +
            " XDG_RUNTIME_DIR=/run/user/" + str(uid) +
            " XDG_CONFIG_HOME=" + home + "/.config" +
            " XDG_CACHE_HOME=" + home + "/.cache" +
            " XDG_DATA_HOME=" + home + "/.local/share" +
            " XDG_STATE_HOME=" + home + "/.local/state " + command
        )

    def systemctl(env, command):
        return as_user(env, "systemctl --user " + command)

    def health(env):
        _, _, _, socket = env
        return as_user(
            env,
            "${pkgs.curl}/bin/curl --fail --silent --show-error "
            "--connect-timeout 2 --max-time 10 --unix-socket " +
            socket + " http://localhost:3000/health"
        )

    def network_namespace(pid):
        return machine.succeed("readlink /proc/" + pid + "/ns/net").strip()

    def service_processes(env):
        supervisor = machine.succeed(
            systemctl(env, "show -P MainPID gotenberg.service")
        ).strip()
        assert supervisor.isdigit() and supervisor != "0", supervisor

        # The application keeps its original unit. The endpoint proxy now has
        # an independent unit, but must join the application's private namespace.
        # Inspect executable paths rather than truncated process names.
        processes = []
        for unit in ["gotenberg.service", proxy_units[env[1]]]:
            cgroup = machine.succeed(
                systemctl(env, "show -P ControlGroup " + unit)
            ).strip()
            assert cgroup.startswith("/") and cgroup.endswith("/" + unit), cgroup
            members = machine.succeed(
                "cat /sys/fs/cgroup" + cgroup + "/cgroup.procs"
            ).split()
            for pid in members:
                status, exe = machine.execute("readlink -f /proc/" + pid + "/exe")
                if status == 0:
                    processes.append((pid, exe.strip()))

        backend = [
            pid for pid, exe in processes
            if exe.rsplit("/", 1)[-1] in ("gotenberg", ".gotenberg-wrapped")
        ]
        proxy = [
            pid for pid, exe in processes
            if exe.endswith("/systemd-socket-proxyd")
        ]
        assert len(backend) == 1 and len(proxy) == 1, processes

        # Both application processes must still belong to the environment
        # user, not root or a privileged helper.
        _, uid, _, _ = env
        for pid in backend + proxy:
            status = machine.succeed("cat /proc/" + pid + "/status")
            uid_lines = [
                line.split() for line in status.splitlines()
                if line.startswith("Uid:")
            ]
            assert len(uid_lines) == 1 and uid_lines[0][1] == str(uid), (pid, status)

        names = [network_namespace(pid) for pid in backend + proxy]
        assert len(set(names)) == 1, (processes, names)
        return supervisor, backend[0], proxy[0], names[0]

    start_all()
    machine.wait_for_unit("multi-user.target")

    with subtest("Hostenv activation installs and starts the socket units"):
        for env in [a, b, unisolated]:
            user, uid, profile, _ = env
            home = "/home/" + user
            machine.wait_for_unit("user@" + str(uid) + ".service")

            # No units are installed ahead of activation. Invoke the actual
            # profile script, which installs the units and runs sd-switch.
            machine.fail("test -e " + home + "/.config/systemd")
            machine.succeed(as_user(env, profile + "/bin/activate"))

            config_units = home + "/.config/systemd"
            state_units = home + "/.local/state/hostenv/current-state/systemd"
            machine.succeed("test -L " + config_units)
            machine.succeed("test -L " + state_units)
            machine.succeed("test " + config_units + " -ef " + state_units)
            machine.succeed(systemctl(env, "is-active --quiet gotenberg.socket"))
            machine.fail(systemctl(env, "is-active --quiet gotenberg.service"))

        # Only the socket is enabled by default. On-demand activation should
        # start the service when a client first connects.
        for env in [a, b]:
            _, _, profile, _ = env
            machine.fail(
                "test -L " + profile +
                "/systemd/user/default.target.wants/gotenberg.service"
            )

        # Keep coverage for explicit startup as well as socket activation.
        machine.succeed(systemctl(a, "start gotenberg.service"))
        machine.fail(systemctl(b, "is-active --quiet gotenberg.service"))

    with subtest("two independent Unix sockets serve Gotenberg"):
        for env in [a, b]:
            user, _, _, socket = env
            machine.wait_until_succeeds(health(env), timeout=timedelta(seconds=120))
            machine.succeed("test -S " + socket)
            owner_mode = machine.succeed(
                "stat -c '%U:%a' " + socket
            ).strip()
            assert owner_mode == user + ":600", owner_mode

    with subtest("Gotenberg exposes the default document fonts"):
        from shlex import quote

        # Use the actual service environment rather than system-wide fonts.
        environment = machine.succeed(
            systemctl(a, "show -P Environment gotenberg.service")
        )
        configs = [
            item.split("=", 1)[1]
            for item in environment.split()
            if item.startswith("FONTCONFIG_FILE=")
        ]
        assert len(configs) == 1, environment
        fontconfig_file = configs[0]
        machine.succeed("test -f " + quote(fontconfig_file))

        for family in [
            "Liberation Sans",
            "Carlito",
            "Caladea",
            "DejaVu Sans",
            "Noto Sans",
            "Noto Color Emoji",
            "Noto Sans CJK JP",
            "Noto Serif CJK JP",
        ]:
            matched = machine.succeed(
                as_user(
                    a,
                    "env FONTCONFIG_FILE=" + quote(fontconfig_file) +
                    " ${pkgs.fontconfig}/bin/fc-match -f '%{family}' " +
                    quote(family)
                )
            ).strip()
            assert family in matched.split(","), (family, matched)

    with subtest("each process shares its own private network namespace"):
        host_namespace = network_namespace("1")
        _, backend_a, proxy_a, namespace_a = service_processes(a)
        _, backend_b, proxy_b, namespace_b = service_processes(b)
        assert len(set([host_namespace, namespace_a, namespace_b])) == 3

        # Namespace setup needs capabilities temporarily, but neither
        # Gotenberg nor its proxy may retain any capabilities.
        for pid in [backend_a, proxy_a, backend_b, proxy_b]:
            status = machine.succeed("cat /proc/" + pid + "/status")
            for name in ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"]:
                values = [
                    line.partition(":")[2].strip()
                    for line in status.splitlines()
                    if line.startswith(name + ":")
                ]
                assert values == ["0000000000000000"], (pid, name, status)

        # A private namespace should have no IPv4 default route.
        for pid in [backend_a, backend_b]:
            routes = machine.succeed("cat /proc/" + pid + "/net/route")
            for route in routes.splitlines()[1:]:
                fields = route.split()
                if len(fields) > 1:
                    assert fields[1] != "00000000", routes

    with subtest("other tenants cannot access the private sockets"):
        machine.fail(health((a[0], a[1], a[2], b[3])))
        machine.fail(health((b[0], b[1], b[2], a[3])))

    with subtest("Gotenberg TCP port is not exposed on host loopback"):
        machine.fail(
            "${pkgs.curl}/bin/curl --fail --connect-timeout 2 http://127.0.0.1:3000/health"
        )

    with subtest("isolated clients reach Gotenberg over localhost TCP"):
        # Run two clients simultaneously. Each has its own loopback:3000
        # listener, forwarding to its own environment's Gotenberg socket.
        states = []
        for env in [a, b]:
            state = "/run/user/" + str(env[1]) + "/gotenberg-reverse-proxy-test"
            states.append(state)
            machine.succeed(
                "(" + as_user(
                    env,
                    "${pkgs.util-linux}/bin/unshare "
                    "--user --map-current-user --keep-caps --net "
                    "${pkgs.lib.getExe reverseProxyNamespace} " +
                    env[3] + " " + state
                ) + ") > /tmp/gotenberg-client-" + str(env[1]) +
                ".log 2>&1 </dev/null &"
            )

        for state in states:
            machine.wait_for_file(state + "/ready", timeout=timedelta(seconds=30))

        host_namespace = network_namespace("1")
        _, _, _, gotenberg_a_namespace = service_processes(a)
        _, _, _, gotenberg_b_namespace = service_processes(b)
        client_namespaces = []
        listener_pids = []
        for env, state in zip([a, b], states):
            namespace = machine.succeed("cat " + state + "/namespace").strip()
            pid = machine.succeed("cat " + state + "/pid").strip()
            listener_pid = machine.succeed("cat " + state + "/listener.pid").strip()
            listener_pids.append(listener_pid)
            client_namespaces.append(namespace)
            assert network_namespace(pid) == namespace
            assert network_namespace(listener_pid) == namespace

            # Both the test application and its TCP listener are ordinary
            # tenant processes with no remaining capabilities.
            for process in [pid, listener_pid]:
                status = machine.succeed("cat /proc/" + process + "/status")
                uids = [
                    line.split()[1] for line in status.splitlines()
                    if line.startswith("Uid:")
                ]
                assert uids == [str(env[1])], (process, status)
                for name in ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"]:
                    values = [
                        line.partition(":")[2].strip()
                        for line in status.splitlines()
                        if line.startswith(name + ":")
                    ]
                    assert values == ["0000000000000000"], (process, name, status)

            devices = machine.succeed("cat /proc/" + pid + "/net/dev")
            interfaces = {
                row.partition(":")[0].strip()
                for row in devices.splitlines()[2:]
                if ":" in row
            }
            assert interfaces == {"lo"}, (pid, interfaces)

        assert len(set([
            host_namespace, gotenberg_a_namespace, gotenberg_b_namespace,
            *client_namespaces
        ])) == 5

        # Both clients are listening on port 3000, yet the host cannot
        # reach either listener (or Gotenberg's own private listener).
        machine.fail(
            "${pkgs.curl}/bin/curl --noproxy '*' --fail "
            "--connect-timeout 2 http://127.0.0.1:3000/health"
        )

        for state in states:
            machine.succeed("touch " + state + "/go")
        for state in states:
            machine.wait_for_file(state + "/done", timeout=timedelta(seconds=120))
            machine.succeed("test -f " + state + "/health")
            machine.succeed(
                "head -c 5 " + state + "/document.pdf | grep -q '%PDF-'"
            )
            machine.succeed(
                "${pkgs.poppler-utils}/bin/pdftotext " +
                state + "/document.pdf - | grep -Fq 'Hostenv LibreOffice PDF test'"
            )

        machine.fail(
            "${pkgs.curl}/bin/curl --noproxy '*' --fail "
            "--connect-timeout 2 http://127.0.0.1:3000/health"
        )
        for state in states:
            machine.succeed("touch " + state + "/stop")
        for pid in listener_pids:
            machine.wait_until_succeeds(
                "test ! -e /proc/" + pid, timeout=timedelta(seconds=30)
            )

    with subtest("Chromium processes remain isolated during PDF conversion"):
        _, _, _, private_namespace = service_processes(a)
        _, _, _, other_tenant_namespace = service_processes(b)
        host_namespace = network_namespace("1")

        # Keep Chromium running while inspecting its processes. They may
        # move into a separate systemd scope, so do not search only the
        # gotenberg.service cgroup.
        conversion = as_user(
            a,
            "${pkgs.curl}/bin/curl --fail --silent --show-error "
            "--max-time 120 --unix-socket " + a[3] +
            " -F 'files=@${fixture};filename=index.html;type=text/html' "
            "-F 'waitDelay=20s' "
            "http://localhost:3000/forms/chromium/convert/html "
            "-o /tmp/gotenberg.pdf"
        )
        machine.succeed(
            "(if " + conversion +
            "; then echo success > /tmp/gotenberg-conversion.status; "
            "else echo failed > /tmp/gotenberg-conversion.status; fi) "
            "> /tmp/gotenberg-conversion.log 2>&1 </dev/null &"
        )

        # Inspect every Chromium process found on the VM, not merely the
        # main browser process. This also finds processes in other cgroups.
        machine.wait_until_succeeds(
            "ps -eo pid=,uid=,comm= | awk "
            "'tolower($3) ~ /chrom(e|ium)/ { n++ } END { exit (n < 2) }'",
            timeout=timedelta(seconds=30)
        )
        # Chromium may register a separate systemd scope shortly after
        # starting. Inspect it after that initial setup, not only while its
        # first helper processes are appearing.
        machine.sleep(timedelta(seconds=5))
        machine.fail("test -e /tmp/gotenberg-conversion.status")

        observed = 0
        namespaces = set()
        cgroups = set()
        for line in machine.succeed("ps -eo pid=,uid=,comm=").splitlines():
            fields = line.split()
            if len(fields) != 3:
                continue
            pid, uid, name = fields
            if not name.lower().lstrip(".").startswith(("chrome", "chromium")):
                continue

            assert uid == str(a[1]), (pid, uid, name)
            status, namespace = machine.execute("readlink /proc/" + pid + "/ns/net")
            if status != 0:
                continue  # A short-lived Chromium helper may have exited.
            namespace = namespace.strip()
            assert namespace != host_namespace, (pid, name, namespace)
            assert namespace != other_tenant_namespace, (pid, name, namespace)

            # Nested Chromium sandboxes may have their own network namespaces.
            # Those are fine if they have no non-loopback interfaces.
            status, devices = machine.execute("cat /proc/" + pid + "/net/dev")
            if status != 0:
                continue
            interfaces = {
                row.partition(":")[0].strip()
                for row in devices.splitlines()[2:]
                if ":" in row
            }
            assert interfaces == {"lo"}, (pid, name, namespace, interfaces)
            namespaces.add(namespace)
            status, cgroup = machine.execute("cat /proc/" + pid + "/cgroup")
            if status == 0:
                cgroups.add(cgroup.strip())
            observed += 1

        assert observed >= 2, "Expected to inspect Chromium and its subprocesses"
        print("Gotenberg namespace:", private_namespace,
              "Chromium namespaces:", sorted(namespaces),
              "Chromium cgroups:", sorted(cgroups))
        machine.wait_for_file(
            "/tmp/gotenberg-conversion.status",
            timeout=timedelta(seconds=120)
        )
        result = machine.succeed("cat /tmp/gotenberg-conversion.status").strip()
        assert result == "success", machine.succeed("cat /tmp/gotenberg-conversion.log")
        machine.succeed("head -c 5 /tmp/gotenberg.pdf | grep -q '%PDF-'")

    with subtest("LibreOffice converts an RTF document to PDF"):
        machine.succeed(
            as_user(
                a,
                "${pkgs.curl}/bin/curl --fail --silent --show-error "
                "--max-time 120 --unix-socket " + a[3] +
                " -F 'files=@${libreofficeFixture};filename=document.rtf;type=application/rtf' "
                "http://localhost:3000/forms/libreoffice/convert "
                "-o /tmp/gotenberg-libreoffice.pdf"
            )
        )
        machine.succeed(
            "head -c 5 /tmp/gotenberg-libreoffice.pdf | grep -q '%PDF-'"
        )
        machine.succeed(
            "${pkgs.poppler-utils}/bin/pdftotext "
            "/tmp/gotenberg-libreoffice.pdf - "
            "| grep -Fq 'Hostenv LibreOffice PDF test'"
        )

    with subtest("service restart recreates a working isolated namespace"):
        previous_pid, _, _, _ = service_processes(a)
        machine.succeed(systemctl(a, "restart gotenberg.service"))
        machine.wait_until_succeeds(health(a), timeout=timedelta(seconds=120))
        current_pid, _, _, current_ns = service_processes(a)
        assert current_pid != previous_pid
        assert current_ns != network_namespace("1")
        machine.succeed(health(b))

    with subtest("socket activation restarts a stopped Gotenberg service"):
        machine.succeed(systemctl(a, "stop gotenberg.service"))
        machine.wait_until_succeeds(health(a), timeout=timedelta(seconds=120))
        service_processes(a)

    with subtest("a missing network namespace fails closed"):
        machine.succeed(systemctl(unisolated, "is-active --quiet gotenberg.socket"))
        machine.fail(systemctl(unisolated, "start gotenberg.service"))
        logs = machine.succeed(
            "journalctl _UID=2002 --no-pager -n 100"
        )
        assert "unshare failed" in logs or "Operation not permitted" in logs, logs
        machine.fail(
            "${pkgs.curl}/bin/curl --fail --connect-timeout 2 http://127.0.0.1:3000/health"
        )
  '';
}
