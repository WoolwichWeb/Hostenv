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

    with subtest("namespace setup failure does not launch an isolated service"):
        machine.fail(control(a, "start isolated-probe-blocked.service"))
        machine.fail("test -e " + quote(a["runtime"] + "/blocked-probe-state/loopback"))

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
        machine.succeed(control(a, "stop " + ep["socketUnit"]))
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
  '';
}
