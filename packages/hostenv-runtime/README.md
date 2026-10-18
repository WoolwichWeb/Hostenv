# Hostenv runtime

The `hostenv-runtime` package builds `hostenv-system`, a command that Hostenv
runs on its hosting servers and in its managed user services.

`hostenv-system acme` prevents certificate requests from interfering with NixOS
deployments, and retries certificate orders after DNS changes.

`hostenv-system endpoint` validates private Unix endpoint paths, joins a
service's pinned user/network namespaces, and supervises only its socket
forwarder. The owning application's process remains under its own systemd
service. Linux-specific pidfd, socket descriptor and openat operations are
provided by the small C shim under `cbits/`.
