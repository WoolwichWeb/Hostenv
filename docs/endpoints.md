# Private TCP endpoint exports

This is the first implementation increment of the service-connection requirements in MR 52. It is not the complete Laravel networking feature. Keep the infrastructure MR in draft until the full NixOS tests pass on its current head and the lifecycle has been reviewed.

## Module-author interface

```nix
systemd.services.example.endpoints = {
  default.port = 3000;
  api.port = 3001;
  admin.port = 3002;
};
```

The declaration extends Hostenv's existing nixpkgs-derived systemd service options. It does not replace `ExecStart`, `Type`, reload or restart settings.

The service integration must start the owner in a private user and network namespace. The owner must be a foreground `simple`, `exec`, `notify` or `notify-reload` service. The current Haskell helper cannot export a listener belonging to a child in a different namespace from the owner's main process. It refuses an unisolated owner; it does not transform arbitrary commands into isolated services.

Gotenberg is the first built-in integration. Customers still enable it with `services.gotenberg.enable = true`. Its existing socket path, fonts, conversion tools and outbound isolation are retained. Its systemd user service sets `NoNewPrivileges=true` to prevent privilege gains through setuid executables or file capabilities.

## Stable paths

The default export is `<runtimeDir>/example.sock`. Named exports are `<runtimeDir>/example/api.sock` and `<runtimeDir>/example/admin.sock`, even when there is only one named endpoint. Use the read-only `config.systemd.services.example.endpoints.api.socket` rather than reconstructing it.

The internal `networking.endpointPlan` lists the paths, private ports, descriptor names and helper units. Native socket paths are registered internally for collision checks; the native-socket module does not create or modify them. Unknown pre-existing runtime objects are rejected without being removed. The provider creates the environment runtime directory with mode `2700` (private owner access and setgid for group inheritance). The generated socket units use `DirectoryMode=0700` and `SocketMode=0600`. The endpoint preflight refuses symlinked parent directories and existing socket-path objects, but does not change directory ownership or permissions.

## How forwarding works

Each endpoint has a Unix socket unit and a separate forwarding unit. A connection starts the forwarding monitor and the existing owner. The monitor waits for the owner's `ActiveState` to indicate readiness, pins its process with a pidfd, opens its namespace descriptors and verifies that they do not refer to the host network. The helper then enters the pinned namespaces and drops setup capabilities before running `systemd-socket-proxyd`.

A named activation descriptor identifies the expected Unix listener. Its type, path and owning process are checked. The application does not receive this descriptor. Separate forwarding units avoid assumptions about descriptor order across several endpoints.

The monitor supervises only its proxy child. An owner exit releases the old namespace; a later connection can start a new generation. Helper cleanup uses pidfds, a five-second termination period and bounded escalation. It never signals the application. The generated forwarding service uses `KillMode=mixed`, so systemd first signals the monitor, which can terminate and reap its proxy before exiting successfully. If cleanup fails, systemd still has whole-cgroup SIGKILL escalation. This avoids treating a normal stop as an unexpected proxy failure. Unit ordering is designed to let an owner stop before its adapters so that normal draining can retain connections; the VM test verifies the unit order, and the next VM run must verify clean shutdown status.

The default endpoint retains `<service>.socket`; other generated units have deterministic names derived from the service/endpoint pair. Existing conflicting declarations fail instead of being overwritten.

## Current limits

Namespace startup is bounded to 120 seconds per helper attempt. Services needing longer recovery must not use this increment without an explicit integration change. Finite and interactive commands, the replacement consumer-side connection API, pasta attachment, full resolver handling and Laravel's convenience option are not implemented here. Their requirements remain in MR 52.

This is a TCP/Unix byte-stream adapter, not UDP transport, authentication, an application health checker or replication configuration. Native MariaDB, Valkey, PostgreSQL and FastCGI listeners remain native. Existing database policies are not changed. Within one environment, same-user services are not separate security principals.

## Verification

```bash
nix flake check
nix build .#endpoints-vm-test -L
nix build .#gotenberg-vm-test -L
```

The contract check is included in Linux flake checks. VM tests remain explicit packages, as with the existing Gotenberg VM test.

A separate local test suite exercises the Haskell helper using real unprivileged namespaces and socket activation, but a fixture replaces `systemctl`. It is not a substitute for the VM unit-ordering tests:

```bash
HOSTENV_SYSTEM_TEST_BINARY=/path/to/hostenv-system python3 -I -S tests/unit/endpoint-runtime.py
```

The Python test harness requires Linux, the compiled hostenv-system executable, `unshare`, `nsenter`, `setpriv`, `ip`, `curl`, `systemd-socket-activate` and `systemd-socket-proxyd`. Set `HOSTENV_TEST_SOCKET_PROXY` when the proxy is not installed at `/usr/lib/systemd/systemd-socket-proxyd`.
