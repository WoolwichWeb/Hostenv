# Hostenv runtime

The `hostenv-runtime` package provides `hostenv-system`, which Hostenv uses
in its system-level and per-environment systemd services.

`hostenv-system acme` prevents certificate requests from interfering with NixOS
deployments, and retries certificate orders after DNS changes.

`hostenv-system endpoint` prepares Unix socket paths, forwards connections to
services in private network namespaces, and stops forwarding when those
services exit.

The small C shim under `cbits/` provides Linux operations for checking socket
descriptors, opening namespaces and monitoring processes.
