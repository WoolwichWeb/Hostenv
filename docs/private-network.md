# Private networking for systemd services

Hostenv can run a service's main process in its own network namespace. The
process and its children can communicate over `127.0.0.1`, but have no route
to other networks.

## Enabling private networking

Set `hostenv.network.isolated` on a systemd user service:

```nix
systemd.services.example = {
  hostenv.network.isolated = true;
  serviceConfig.ExecStart = "${lib.getExe examplePackage} --port 3000";
};
```

Private networking is disabled by default. When enabled, Hostenv also creates
a private user namespace and sets `NoNewPrivileges=true` for the service.

## Supported commands

The service must have one `ExecStart` command beginning with an absolute
executable path. Systemd command prefixes, such as `-` and `@`, and multiple
commands, including those separated by semicolons, are not supported.

The private network applies to `ExecStart` and the processes it starts. Other
systemd commands, including `ExecStartPre`, `ExecStartPost`, `ExecReload`
and `ExecStop`, run outside the private network. Run any tasks that require
isolation as part of the main service process.

## Connecting to an isolated service

To make a TCP port in the private network accessible to other processes in the
same hosting environment, declare a [TCP endpoint](endpoints.md). Hostenv
creates a Unix socket that forwards connections to that port.
