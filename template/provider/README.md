# Hostenv Provider Template

This template allows you to run your own hostenv hosting provider.

## Quick start

1. Set `provider.hostenvHostname`, `provider.deployPublicKeys`, and the node mappings (`nodeSystems`, `nodeFor`) in `flake.nix`.
2. Copy `nodes/sample/` to `nodes/<node>/` and edit the configuration files for that machine.
3. Add each client project to `flake.nix` as an `organisation__project` input pointing at its `.hostenv` flake.
4. Enter the development shell with `direnv allow` or `nix develop`.
5. Configure the encrypted provider secrets in `secrets/secrets.yaml`. See [Managing Provider Secrets](https://gitlab.com/woolwichweb/hostenv/-/blob/0cacc14922e10ad62df6bdefe8d861206e27a170/docs/provider-secrets.md) for a complete SOPS/age example.
6. Run `hostenv-provider -- plan`.
7. Run `hostenv-provider -- deploy`.

Commit `generated/state.json` to the provider repository. Hostenv uses it to
keep persistent state between deployments, including UIDs and hostname
reservations.

`generated/plan.json` is a snapshot of the inventory's Nix configuration,
which may be committed to git or deleted, depending on your auditing needs.

`generated/flake.nix` tracks every project environment as a separate input,
as opposed to `flake.nix` with one input per-project.

## More information

See the hostenv docs for a [complete quick start](https://gitlab.com/woolwichweb/hostenv/-/blob/0cacc14922e10ad62df6bdefe8d861206e27a170/docs/provider-quickstart.md)
