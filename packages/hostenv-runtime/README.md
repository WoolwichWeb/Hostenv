# Hostenv runtime

The `hostenv-runtime` package builds `hostenv-system`, a command that Hostenv
runs on its hosting servers.

`hostenv-system` prevents certificate requests from interfering with NixOS
deployments. It holds off new certificate orders while the system switches,
then resumes them afterwards. Hostenv also uses it to retry certificate
requests after updating DNS records.
