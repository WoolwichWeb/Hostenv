# Private network namespaces for user services

Service integrations can run their main process in a private network namespace:

```nix
systemd.services.example = {
  hostenv.network.isolated = true;
  serviceConfig.ExecStart = "${lib.getExe examplePackage} --port 3000";
};
```

By default, `hostenv.network.isolated` is `false`. Setting it to `true` makes Hostenv create private user and network namespaces, bring up loopback and drop its namespace-setup capabilities before running the original `ExecStart` command. If setup fails, the application does not start. The service also requires `NoNewPrivileges=true`.

The application and its descendants can use `127.0.0.1` inside their private namespace, but Hostenv does not provide an outbound network route. This is an execution setting, independent of `systemd.services.<name>.endpoints`: an isolated service does not need to export an endpoint, and declaring an endpoint does not automatically enable isolation.

## Supported commands

The initial implementation accepts one ordinary `ExecStart` command beginning with an absolute executable path. It preserves the command's systemd argument parsing, the main process identity, service type, working directory, environment and readiness notifications. Unsupported executable prefixes (such as `-` or `@`) and multiple `ExecStart` commands, including semicolon-separated commands, are rejected during evaluation.

Only the **main `ExecStart` process** is placed in the private namespace. systemd control commands such as `ExecStartPre`, `ExecStartPost`, `ExecReload` and `ExecStop` retain their normal execution context. Do not use those hooks for application work that must be isolated. Extending network policy to every execution path, including outbound access and DNS, belongs to the later service-connections work in MR 52.

Gotenberg uses this option for its converter. Its HTTP readiness check and application supervision remain in the Gotenberg module.

## Verification

```bash
nix build .#checks.x86_64-linux.private-network-contracts -L
nix build .#endpoints-vm-test -L
nix build .#gotenberg-vm-test -L
```

The endpoint VM test includes a standalone service with no endpoints and verifies its isolated loopback, process capabilities, independence from another namespace and refusal to start when namespace creation is forbidden. The Gotenberg VM test verifies the application and Chromium still run in isolated network contexts.
