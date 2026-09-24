# Hostenv Provider Template

This template consumes Hostenv projects and generates the plan, persistent
state, and flake used to deploy them.

## Quick start

1. Set `provider.hostenvHostname`, `provider.deployPublicKeys`, and the node mappings in `flake.nix`.
2. Copy `nodes/sample/` to `nodes/<node>/` and edit the configuration files for that machine.
3. Add each client project to `flake.nix` as an `organisation__project` input pointing at its `.hostenv` flake.
4. Enter the development shell with `direnv allow` or `nix develop`.
5. Configure the encrypted provider secrets in `secrets/secrets.yaml`. See [Managing Provider Secrets](../../docs/provider-secrets.md) for a complete SOPS/age example.
6. Run `nix run .#hostenv-provider -- plan`.
7. Run `nix run .#hostenv-provider -- dns-gate`, then `nix run .#hostenv-provider -- deploy`.

Commit `generated/state.json` and `generated/plan.json`. Hostenv uses state
only for durable UID/hostname reservations; the previous generated plan is used
to validate provider-node inventory transitions. Deployment leaves both
unchanged.

When draining a provider node, keep it in `provider.nodeSystems`, remove it
from `provider.nodeFor`, and set
`provider.nodeStatus.<node> = "retiring"`. Hostenv will keep the node
available for migration/cleanup and will reject removing it from inventory
until it is clean.

## Runtime secrets

Framework services may request named runtime files. Laravel requests
`laravel_env`, for example. Secrets may be set for a single environment, a
project, or an organisation.

See [Managing Provider Secrets](../../docs/provider-secrets.md) for creating and
editing the encrypted SOPS file, and the
[Provider Reference](../../docs/provider-reference.md#runtime-secrets) for the
Hostenv secret scopes.
