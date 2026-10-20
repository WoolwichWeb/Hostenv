# TCP endpoints through Unix sockets

A Hostenv endpoint makes a service's private TCP port available through a Unix
socket. Other processes in the same hosting environment can connect to the
service using that socket.

Hostenv configures endpoints automatically for built-in services that need
them. You can also define endpoints for your own systemd services.

## Configuring endpoints

Add endpoints to an existing systemd user service:

```nix
systemd.services.example = {
  hostenv.network.isolated = true;

  endpoints = {
    default.port = 3000;
    api.port = 3001;
  };
};
```

The application must accept connections to `127.0.0.1:3000` and
`127.0.0.1:3001` inside its private network. Hostenv forwards connections using the network
namespace of the service's main process. Any process listening on these ports must share
that namespace. See [Private networking](private-network.md) for details.

Endpoints support services running in the foreground with a systemd type of
`simple`, `exec`, `notify` or `notify-reload`.

## Socket paths

By default, Hostenv creates endpoint sockets beneath
`/run/hostenv/user/<environment-user>/`. For the example above, the paths are:

```text
/run/hostenv/user/<environment-user>/example.sock
/run/hostenv/user/<environment-user>/example/api.sock
```

The `default` endpoint uses `<service>.sock`. Named endpoints use
`<service>/<endpoint>.sock`, even if there is only one named endpoint. In Nix,
use `config.systemd.services.example.endpoints.api.socket` to obtain the path.

The environment's Unix user owns these sockets, which have permissions
`0600`. Hostenv checks for overlapping endpoint paths and conflicts with
paths declared in other systemd socket units. It also refuses to overwrite an
existing file or follow a symbolic link in the socket's directory path.

Service and endpoint names must start with an ASCII letter or digit. They may
also contain full stops, hyphens and underscores. The full socket path must be at
most 107 bytes long.

## How connections work

Hostenv creates the Unix sockets when the environment is activated. Connecting
to a socket starts its service if necessary, then forwards traffic to the
configured TCP port inside the service's private network.

Hostenv waits up to two minutes for systemd to report that the service is
active. The application should open its TCP listener promptly after starting.
Forwarding stops when the service stops. A later connection can start it again.
