{ pkgs, makeHostenv, hostenvNixosModule }:
let
  lib = pkgs.lib;
  server = pkgs.writeText "endpoint-test-server.py" ''
    import os
    import selectors
    import signal
    import socket
    import sys
    from pathlib import Path

    state = Path(sys.argv[1])
    state.mkdir(parents=True, exist_ok=True)
    selector = selectors.DefaultSelector()
    for port in [3000, 3001, 3002]:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(64)
        selector.register(listener, selectors.EVENT_READ, port)
    (state / "pid").write_text(str(os.getpid()))
    (state / "net").write_text(os.readlink("/proc/self/ns/net"))
    (state / "activation").write_text(str(os.environ.get("LISTEN_FDS", "0")))
    signal.signal(signal.SIGUSR1, lambda *_: (state / "reloaded").touch())
    notify = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    notify.connect(os.environ["NOTIFY_SOCKET"])
    notify.sendall(b"READY=1")
    notify.close()
    while True:
        for key, _ in selector.select():
            connection, _ = key.fileobj.accept()
            with connection:
                connection.settimeout(5)
                request = b""
                while b"\r\n\r\n" not in request:
                    data = connection.recv(4096)
                    if not data:
                        break
                    request += data
                body = (str(key.data) + "\n").encode()
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body
                )
  '';

  delayedServer = pkgs.writeText "endpoint-delayed-server.py" ''
    import socket
    import sys
    import time
    from pathlib import Path

    state = Path(sys.argv[1])
    state.mkdir(parents=True, exist_ok=True)
    (state / "starting").touch()
    time.sleep(3)

    listener = socket.socket()
    listener.bind(("127.0.0.1", 3100))
    listener.listen(8)
    connections = 0
    while True:
        connection, _ = listener.accept()
        connections += 1
        (state / "connections").write_text(str(connections))
        with connection:
            connection.settimeout(5)
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                request += chunk
            if request:
                body = b"ready\n"
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body
                )
  '';

  dualStackServer = pkgs.writeText "endpoint-dual-stack.py" ''
    import socket
    import sys
    from pathlib import Path

    state = Path(sys.argv[1])
    state.mkdir(parents=True, exist_ok=True)
    listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    listener.bind(("::", 3200))
    listener.listen(8)
    requests = 0
    accepted = 0
    while True:
        connection, _ = listener.accept()
        accepted += 1
        (state / "accepted").write_text(str(accepted))
        with connection:
            connection.settimeout(2)
            try:
                request = connection.recv(4096)
            except (TimeoutError, ConnectionResetError):
                continue
            if not request:
                continue
            requests += 1
            (state / "requests").write_text(str(requests))
            body = b"dual-stack\n"
            connection.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode()
                + b"\r\nConnection: close\r\n\r\n" + body
            )
  '';

  v6ThenV4Server = pkgs.writeText "endpoint-v6-then-v4.py" ''
    import socket
    import sys
    import time
    from pathlib import Path

    state = Path(sys.argv[1])
    state.mkdir(parents=True, exist_ok=True)
    ipv6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    ipv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    ipv6.bind(("::", 3300))
    ipv6.listen(8)
    (state / "ipv6-listening").touch()

    # IPv4 becomes available after the namespace has already been inspected.
    time.sleep(4)
    ipv4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ipv4.bind(("127.0.0.1", 3300))
    ipv4.listen(8)
    (state / "ipv4-listening").touch()

    accepted = 0
    while True:
        connection, _ = ipv4.accept()
        accepted += 1
        (state / "accepted").write_text(str(accepted))
        with connection:
            connection.settimeout(5)
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                request += chunk
            if request:
                body = b"ipv4-ready\n"
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body
                )
  '';
  probe = pkgs.writeShellScript "isolated-service-probe" ''
    ${pkgs.coreutils}/bin/mkdir -p "$1"
    ${pkgs.iproute2}/bin/ip -o link show lo > "$1/loopback"
    ${pkgs.iproute2}/bin/ip route show default > "$1/default-route"
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
  make = project: endpoints: (makeHostenv [
    ({ config, ... }: {
      hostenv = { organisation = "test"; inherit project; root = pkgs.emptyDirectory; hostenvHostname = "hosting.test"; };
      environments.main.enable = true;
      systemd.services.example = {
        inherit endpoints;
        hostenv.network.isolated = true;
        serviceConfig = {
          Type = "notify";
          ExecStart = "${pkgs.python3}/bin/python3 -I -S ${server} ${config.hostenv.runtimeDir}/server-state";
          ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";
          Restart = "on-failure";
        };
      };
      # Type=exec can become active before the TCP listener is open.
      systemd.services.delayed = {
        endpoints.default.port = 3100;
        hostenv.network.isolated = true;
        serviceConfig = {
          Type = "exec";
          ExecStart = "${pkgs.python3}/bin/python3 -I -S ${delayedServer} ${config.hostenv.runtimeDir}/delayed-state";
        };
      };
      systemd.services.dual-stack = {
        endpoints.default.port = 3200;
        hostenv.network.isolated = true;
        serviceConfig = {
          Type = "exec";
          ExecStart = "${pkgs.python3}/bin/python3 -I -S ${dualStackServer} ${config.hostenv.runtimeDir}/dual-stack-state";
        };
      };
      systemd.services.v6-then-v4 = {
        endpoints.default.port = 3300;
        hostenv.network.isolated = true;
        serviceConfig = {
          Type = "exec";
          ExecStart = "${pkgs.python3}/bin/python3 -I -S ${v6ThenV4Server} ${config.hostenv.runtimeDir}/v6-then-v4-state";
        };
      };
      # This service has no endpoint: namespace setup must also work on its own.
      systemd.services.isolated-probe = {
        hostenv.network.isolated = true;
        serviceConfig = {
          Type = "exec";
          ExecStart = "${probe} ${config.hostenv.runtimeDir}/probe-state";
        };
      };
      systemd.services.isolated-probe-blocked = {
        hostenv.network.isolated = true;
        serviceConfig = {
          Type = "exec";
          ExecStart = "${probe} ${config.hostenv.runtimeDir}/blocked-probe-state";
          RestrictNamespaces = true;
        };
      };
    })
  ] "main").config;
  a = make "endpointa" { default.port = 3000; api.port = 3001; };
  aExpanded = make "endpointa" { default.port = 3000; api.port = 3001; admin.port = 3002; };
  b = make "endpointb" { default.port = 3000; api.port = 3001; };
  asPlan = cfg: uid: { name = cfg.hostenv.userName; value = cfg.environments.main // { hostenv = cfg.hostenv; inherit uid; }; };
  settings = cfg: uid: {
    user = cfg.hostenv.userName;
    inherit uid;
    profile = toString cfg.activatePackage;
    runtime = cfg.hostenv.runtimeDir;
    endpoints = lib.mapAttrs (_: ep: { inherit (ep) socket socketUnit proxyUnit; }) cfg.systemd.services.example.endpoints;
    delayedSocket = cfg.systemd.services.delayed.endpoints.default.socket;
    dualStackSocket = cfg.systemd.services.dual-stack.endpoints.default.socket;
    v6ThenV4Socket = cfg.systemd.services.v6-then-v4.endpoints.default.socket;
    v6ThenV4ProxyUnit = cfg.systemd.services.v6-then-v4.endpoints.default.proxyUnit;
  };
in
pkgs.testers.runNixOSTest {
  name = "hostenv-service-endpoints";
  nodes.machine = { ... }: {
    imports = [ hostenvNixosModule ];
    provider.plan.environments = builtins.listToAttrs [ (asPlan a 2000) (asPlan b 2001) ];
    environment.systemPackages = [ a.activatePackage aExpanded.activatePackage b.activatePackage pkgs.curl pkgs.procps ];
    virtualisation = { cores = 2; memorySize = 1536; };
  };
  testScript = ''
    import json
    from datetime import timedelta
    from shlex import quote

    a = json.loads(${builtins.toJSON (builtins.toJSON (settings a 2000))})
    expanded = json.loads(${builtins.toJSON (builtins.toJSON (settings aExpanded 2000))})
    b = json.loads(${builtins.toJSON (builtins.toJSON (settings b 2001))})

    def as_user(env, command):
        home = "/home/" + env["user"]
        return (
            "runuser -u " + env["user"] + " -- env HOME=" + home
            + " XDG_RUNTIME_DIR=/run/user/" + str(env["uid"])
            + " XDG_CONFIG_HOME=" + home + "/.config"
            + " XDG_CACHE_HOME=" + home + "/.cache"
            + " XDG_DATA_HOME=" + home + "/.local/share"
            + " XDG_STATE_HOME=" + home + "/.local/state " + command
        )

    def control(env, command):
        return as_user(env, "systemctl --user " + command)

    def request(env, name):
        return as_user(env, "${pkgs.curl}/bin/curl --noproxy '*' --fail --silent --show-error --max-time 15 --unix-socket "
                       + quote(env["endpoints"][name]["socket"]) + " http://localhost/")

    def ready(env, name, port):
        machine.wait_until_succeeds(request(env, name) + " | grep -Fxq " + str(port), timeout=timedelta(seconds=40))

    def main_pid(env, unit):
        pid = machine.succeed(control(env, "show -P MainPID " + unit)).strip()
        assert pid.isdigit() and pid != "0", (unit, pid)
        return pid

    def members(env, unit):
        group = machine.succeed(control(env, "show -P ControlGroup " + unit)).strip()
        assert group.startswith("/") and group.endswith("/" + unit), group
        return machine.succeed("cat /sys/fs/cgroup" + group + "/cgroup.procs").split()

    def namespace(pid):
        return machine.succeed("readlink /proc/" + pid + "/ns/net").strip()

    def check_processes(env):
        owner = main_pid(env, "example.service")
        assert machine.succeed("cat " + env["runtime"] + "/server-state/pid").strip() == owner
        own_ns = namespace(owner)
        assert own_ns != namespace("1")
        processes = [owner]
        for ep in env["endpoints"].values():
            processes += members(env, ep["proxyUnit"])
        for pid in processes:
            assert namespace(pid) == own_ns, (pid, own_ns)
            fields = dict(line.split(":", 1) for line in machine.succeed("cat /proc/" + pid + "/status").splitlines() if ":" in line)
            assert fields["Uid"].split() == [str(env["uid"])] * 4
            for key in ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"]:
                assert int(fields[key].strip(), 16) == 0, (pid, key, fields[key])
        return owner, processes, own_ns

    start_all()
    machine.wait_for_unit("multi-user.target")

    with subtest("activation installs named exports without starting their owner"):
        for env in [a, b]:
            machine.wait_for_unit("user@" + str(env["uid"]) + ".service")
            machine.succeed(as_user(env, env["profile"] + "/bin/activate"))
            # The provider creates this directory with setgid, not plain 0700.
            # New endpoint subdirectories may inherit setgid as well.
            assert machine.succeed("stat -c '%u:%a' " + quote(env["runtime"])).strip() == str(env["uid"]) + ":2700"
            machine.fail(control(env, "is-active --quiet example.service"))
            for ep in env["endpoints"].values():
                machine.succeed(control(env, "is-active --quiet " + ep["socketUnit"]))
                assert machine.succeed("stat -c '%u:%a' " + quote(ep["socket"])).strip() == str(env["uid"]) + ":600"

    with subtest("first request waits for a Type=exec service to listen"):
        # One curl invocation, without test-harness retries. The backend counts
        # every connection, including any unintended readiness probes.
        machine.fail(control(a, "is-active --quiet delayed.service"))
        result = machine.succeed(as_user(
            a,
            "${pkgs.curl}/bin/curl --noproxy '*' --fail --silent "
            "--show-error --max-time 15 --unix-socket "
            + quote(a["delayedSocket"]) + " http://localhost/"
        ))
        assert result == "ready\n", result
        machine.succeed("grep -Fxq 1 " + quote(a["runtime"] + "/delayed-state/connections"))

    with subtest("dual-stack IPv6 wildcard listener accepts IPv4 through the endpoint"):
        result = machine.succeed(as_user(
            a,
            "${pkgs.curl}/bin/curl --noproxy '*' --fail --silent "
            "--show-error --max-time 15 --unix-socket "
            + quote(a["dualStackSocket"]) + " http://localhost/"
        ))
        assert result == "dual-stack\n", result
        machine.succeed("grep -Fxq 1 " + quote(a["runtime"] + "/dual-stack-state/requests"))
        # The readiness check must not make an extra connection and close it.
        machine.succeed("grep -Fxq 1 " + quote(a["runtime"] + "/dual-stack-state/accepted"))

    with subtest("IPv6-only listener waits for IPv4 without restarting forwarding"):
        # A single request activates the owner; its IPv6-only listener opens
        # first. The proxy must remain running until IPv4 becomes available.
        machine.fail(control(a, "is-active --quiet v6-then-v4.service"))
        result = machine.succeed(as_user(
            a,
            "${pkgs.curl}/bin/curl --noproxy '*' --fail --silent "
            "--show-error --max-time 20 --unix-socket "
            + quote(a["v6ThenV4Socket"]) + " http://localhost/"
        ))
        assert result == "ipv4-ready\n", result
        state = a["runtime"] + "/v6-then-v4-state"
        machine.succeed("test -f " + quote(state + "/ipv6-listening"))
        machine.succeed("test -f " + quote(state + "/ipv4-listening"))
        machine.succeed("grep -Fxq 1 " + quote(state + "/accepted"))
        assert machine.succeed(
            control(a, "show -P NRestarts " + a["v6ThenV4ProxyUnit"])
        ).strip() == "0"

    with subtest("several named sockets reach their own private ports"):
        for env in [a, b]:
            ready(env, "default", 3000)
            ready(env, "api", 3001)
            machine.succeed("grep -Fxq 0 " + env["runtime"] + "/server-state/activation")
        _, _, na = check_processes(a)
        _, _, nb = check_processes(b)
        assert na != nb
        for port in [3000, 3001, 3002]:
            machine.fail("${pkgs.curl}/bin/curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:" + str(port))
        for caller, target in [(a, b), (b, a)]:
            for name in target["endpoints"]:
                copy = dict(caller, endpoints=target["endpoints"])
                machine.fail(request(copy, name))

    with subtest("a service without endpoints can opt into private networking"):
        for env in [a, b]:
            machine.succeed(control(env, "start isolated-probe.service"))
            state = env["runtime"] + "/probe-state"
            machine.wait_for_file(state + "/loopback")
            machine.succeed("grep -Fq 'LOOPBACK,UP' " + quote(state + "/loopback"))
            machine.succeed("test ! -s " + quote(state + "/default-route"))
            pid = main_pid(env, "isolated-probe.service")
            assert namespace(pid) not in [namespace("1"), namespace(main_pid(env, "example.service"))]
            fields = dict(
                line.split(":", 1) for line in
                machine.succeed("cat /proc/" + pid + "/status").splitlines()
                if ":" in line
            )
            assert fields["Uid"].split() == [str(env["uid"])] * 4
            for key in ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"]:
                assert int(fields[key].strip(), 16) == 0, (pid, key, fields[key])
            assert machine.succeed(
                control(env, "show -P NoNewPrivileges isolated-probe.service")
            ).strip() == "yes"
            machine.succeed(control(env, "stop isolated-probe.service"))

    with subtest("owner readiness and reload retain the real main process"):
        before = main_pid(a, "example.service")
        machine.succeed(control(a, "reload example.service"))
        machine.wait_for_file(a["runtime"] + "/server-state/reloaded")
        assert main_pid(a, "example.service") == before
        ready(a, "api", 3001)

    with subtest("a failed proxy recovers without replacing the application"):
        owner = main_pid(a, "example.service")
        helper = main_pid(a, a["endpoints"]["api"]["proxyUnit"])
        machine.succeed("kill -KILL " + helper)
        ready(a, "api", 3001)
        assert main_pid(a, "example.service") == owner
        machine.wait_until_succeeds("test ! -e /proc/" + helper, timeout=timedelta(seconds=15))
        check_processes(a)

    with subtest("an unexpected proxy child exit restarts forwarding"):
        owner = main_pid(a, "example.service")
        unit = a["endpoints"]["api"]["proxyUnit"]
        helper = main_pid(a, unit)
        children = [pid for pid in members(a, unit) if pid != helper]
        assert len(children) == 1, children
        child = children[0]
        machine.succeed("kill -TERM " + child)
        machine.wait_until_succeeds(
            control(a, "show -P MainPID " + unit)
            + " | grep -E '^[1-9][0-9]*$' | grep -vx " + quote(helper),
            timeout=timedelta(seconds=15),
        )
        ready(a, "api", 3001)
        assert main_pid(a, "example.service") == owner
        machine.wait_until_succeeds("test ! -e /proc/" + child, timeout=timedelta(seconds=15))
        check_processes(a)

    with subtest("owner restart discards old namespace references"):
        owner, old, _ = check_processes(a)
        machine.succeed(control(a, "restart example.service"))
        ready(a, "default", 3000)
        ready(a, "api", 3001)
        current, _, _ = check_processes(a)
        assert current != owner
        for pid in old:
            machine.wait_until_succeeds("test ! -e /proc/" + pid, timeout=timedelta(seconds=15))
        ready(b, "api", 3001)

    with subtest("automatic owner crash recovery reattaches both endpoints"):
        owner, previous_processes, previous_namespace = check_processes(a)
        machine.succeed("kill -KILL " + owner)

        # The owner must restart under its own Restart= policy, before a
        # socket request can cause activation.
        machine.wait_until_succeeds(
            control(a, "show -P MainPID example.service")
            + " | grep -E '^[1-9][0-9]*        for name in a["endpoints"]:
            assert a["endpoints"][name]["socket"] == expanded["endpoints"][name]["socket"]
        machine.succeed(as_user(expanded, expanded["profile"] + "/bin/activate"))
        for name, port in [("default", 3000), ("api", 3001), ("admin", 3002)]:
            ready(expanded, name, port)
        check_processes(expanded)
        machine.succeed(as_user(a, a["profile"] + "/bin/activate"))
        machine.fail("test -e " + quote(expanded["endpoints"]["admin"]["socket"]))
        ready(a, "default", 3000)
        ready(a, "api", 3001)

    with subtest("socket preflight refuses an unrelated existing object"):
        ep = a["endpoints"]["api"]
        owner = main_pid(a, "example.service")
        unaffected = a["endpoints"]["default"]["proxyUnit"]
        unaffected_pid = main_pid(a, unaffected)
        machine.succeed(control(a, "stop " + ep["socketUnit"]))
        # Stopping one socket must not stop or restart its owner or another
        # forwarding unit.
        machine.succeed(control(a, "is-active --quiet example.service"))
        machine.succeed(control(a, "is-active --quiet " + unaffected))
        assert main_pid(a, "example.service") == owner
        assert main_pid(a, unaffected) == unaffected_pid
        ready(a, "default", 3000)
        # Intentional socket shutdown must not mark its forwarding service
        # failed merely because the proxy child received SIGTERM.
        assert machine.succeed(control(a, "show -P Result " + ep["proxyUnit"])).strip() == "success"
        machine.succeed("printf '%s' preserved > " + quote(ep["socket"]))
        machine.fail(control(a, "start " + ep["socketUnit"]))
        assert machine.succeed("cat " + quote(ep["socket"])).strip() == "preserved"
        machine.succeed("rm " + quote(ep["socket"]))
        machine.succeed(control(a, "reset-failed " + ep["socketUnit"]))
        machine.succeed(control(a, "start " + ep["socketUnit"]))
        ready(a, "api", 3001)

    with subtest("namespace setup failure does not launch an isolated service"):
        # Type=exec can report startup before unshare attempts its syscall.
        machine.execute(control(a, "start isolated-probe-blocked.service"))
        machine.wait_until_succeeds(
            control(a, "is-failed --quiet isolated-probe-blocked.service"),
            timeout=timedelta(seconds=30),
        )
        machine.fail("test -e " + quote(a["runtime"] + "/blocked-probe-state/loopback"))
  '';
}
 | grep -vx " + quote(owner),
            timeout=timedelta(seconds=40),
        )
        machine.wait_until_succeeds(
            control(a, "is-active --quiet example.service"),
            timeout=timedelta(seconds=40),
        )
        assert main_pid(a, "example.service") != owner

        # Both socket forwarders must reach the new application namespace.
        ready(a, "default", 3000)
        ready(a, "api", 3001)
        _, _, current_namespace = check_processes(a)
        assert current_namespace != previous_namespace

        # Neither the crashed process nor the old endpoint forwarders may
        # remain after recovery.
        for pid in previous_processes:
            machine.wait_until_succeeds(
                "test ! -e /proc/" + pid, timeout=timedelta(seconds=15)
            )
        ready(b, "api", 3001)

    with subtest("upgrade and rollback preserve existing paths"):
        for name in a["endpoints"]:
            assert a["endpoints"][name]["socket"] == expanded["endpoints"][name]["socket"]
        machine.succeed(as_user(expanded, expanded["profile"] + "/bin/activate"))
        for name, port in [("default", 3000), ("api", 3001), ("admin", 3002)]:
            ready(expanded, name, port)
        check_processes(expanded)
        machine.succeed(as_user(a, a["profile"] + "/bin/activate"))
        machine.fail("test -e " + quote(expanded["endpoints"]["admin"]["socket"]))
        ready(a, "default", 3000)
        ready(a, "api", 3001)

    with subtest("socket preflight refuses an unrelated existing object"):
        ep = a["endpoints"]["api"]
        owner = main_pid(a, "example.service")
        unaffected = a["endpoints"]["default"]["proxyUnit"]
        unaffected_pid = main_pid(a, unaffected)
        machine.succeed(control(a, "stop " + ep["socketUnit"]))
        # Stopping one socket must not stop or restart its owner or another
        # forwarding unit.
        machine.succeed(control(a, "is-active --quiet example.service"))
        machine.succeed(control(a, "is-active --quiet " + unaffected))
        assert main_pid(a, "example.service") == owner
        assert main_pid(a, unaffected) == unaffected_pid
        ready(a, "default", 3000)
        # Intentional socket shutdown must not mark its forwarding service
        # failed merely because the proxy child received SIGTERM.
        assert machine.succeed(control(a, "show -P Result " + ep["proxyUnit"])).strip() == "success"
        machine.succeed("printf '%s' preserved > " + quote(ep["socket"]))
        machine.fail(control(a, "start " + ep["socketUnit"]))
        assert machine.succeed("cat " + quote(ep["socket"])).strip() == "preserved"
        machine.succeed("rm " + quote(ep["socket"]))
        machine.succeed(control(a, "reset-failed " + ep["socketUnit"]))
        machine.succeed(control(a, "start " + ep["socketUnit"]))
        ready(a, "api", 3001)

    with subtest("namespace setup failure does not launch an isolated service"):
        # Type=exec can report startup before unshare attempts its syscall.
        machine.execute(control(a, "start isolated-probe-blocked.service"))
        machine.wait_until_succeeds(
            control(a, "is-failed --quiet isolated-probe-blocked.service"),
            timeout=timedelta(seconds=30),
        )
        machine.fail("test -e " + quote(a["runtime"] + "/blocked-probe-state/loopback"))
  '';
}
