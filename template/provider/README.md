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
7. Run `nix run .#hostenv-provider -- deploy`.

Commit `generated/state.json`; it contains Hostenv's durable UID and hostname
reservations, not environment placement or provider-node history.
`generated/plan.json` is disposable generated output. When a previous valid
plan is present, Hostenv uses it as an additional node-removal check. When that
generated history is unavailable, live DNS and pending provider-owned migration
handoffs remain the node-removal safety tripwires.

When draining a provider node, keep it in `provider.nodeSystems`, remove it
from `provider.nodeFor`, and set
`provider.nodeStatus.<node> = "retiring"`. Hostenv keeps the node available
for migration/cleanup. During a move, `deploy` applies the canonical desired
configuration, verifies the destination, quiesces the source, cuts DNS over,
waits for trusted HTTPS on Let's-Encrypt-enabled vhosts, and only then removes
the source account. `generated/plan.json` always remains the desired end
state; Hostenv does not derive a weaker ACME-disabled staging configuration.

## Runtime secrets

Framework services may request named runtime files. Laravel requests
`laravel_env`, for example. Secrets may be set for a single environment, a
project, or an organisation.

See [Managing Provider Secrets](../../docs/provider-secrets.md) for creating and
editing the encrypted SOPS file, and the
[Provider Reference](../../docs/provider-reference.md#runtime-secrets) for the
Hostenv secret scopes.
