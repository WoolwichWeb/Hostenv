# Provider reference

Start with the [Provider Quickstart](provider-quickstart.md) if you are setting up a provider for the first time. This page covers the configuration and operational tasks you are likely to need afterwards.

## Nodes and environment placement

`provider.nodeSystems` is the inventory of provider nodes. Each entry maps a node name to its Nix system:

```nix
provider.nodeSystems = {
  node-a = "x86_64-linux";
  node-b = "aarch64-linux";
};
```

`provider.nodeFor` decides where environments are placed. Set a default node, then add overrides by environment type where required:

```nix
provider.nodeFor = {
  default = "node-a";
  production = "node-b";
};
```

`testing` and `development` can be configured in the same way.

Each node should have a matching directory under `nodes/` containing its `configuration.nix` and `hardware-configuration.nix`.

If Hostenv must connect to a node using an address other than its node name, use the relevant per-node overrides:

- `provider.nodeAddresses` for the SSH hostname or IP address;
- `provider.nodeSshPorts` for a non-standard SSH port;
- `provider.nodeSshOpts` for additional SSH options; and
- `provider.nodeRemoteBuild` to build on a particular remote node.

## Client projects

Add each client project to the provider's `flake.nix` as an input named `organisation__project`:

```nix
inputs.acme__website = {
  url = "gitlab:acme/website?dir=.hostenv&ref=main";

  inputs.nixpkgs.follows = "nixpkgs";
  inputs.hostenv.follows = "hostenv";
  inputs.flake-parts.follows = "flake-parts";
};
```

Use `dir=.hostenv` when the project's Hostenv flake is in its standard `.hostenv` directory. Change `ref=main` if the Hostenv configuration should come from another branch.

After adding, removing, or changing a project input, regenerate the provider plan.

## Planning and deployment

The normal workflow is:

```bash
nix run .#hostenv-provider -- plan
nix run .#hostenv-provider -- deploy
```

Use `--dry-run` with either command to preview what Hostenv intends to do without changing generated files or remote systems:

```bash
nix run .#hostenv-provider -- plan --dry-run
nix run .#hostenv-provider -- deploy --dry-run
```

The `generated/` directory contains three files with different purposes:

- `generated/state.json` contains durable environment identity and hostname reservations. **Commit this file to version control. Do not reset it to `{}` as a troubleshooting step.**
- `generated/plan.json` describes the desired provider inventory and environment placement. It is generated output rather than persistent state. Keeping a valid previous copy gives Hostenv an additional safety check when nodes are removed, but the file can be regenerated.
- `generated/flake.nix` is generated from the current provider and project configuration.

A normal deployment may update DNS, move environments between nodes, verify applications, and remove obsolete environment accounts as part of the same operation.

## Moving an environment to another node

Change `provider.nodeFor` so that the environment type is assigned to the new node. Then run `plan` and an unfiltered `deploy`.

For example:

```nix
provider.nodeFor.production = "node-b";
```

Hostenv discovers the existing source node from the live Hostenv account and its reserved UID. It then moves any configured backup data, deploys and verifies the destination, moves DNS, and removes the old account only after the destination is ready.

Run migrations with an unfiltered deployment:

```bash
nix run .#hostenv-provider -- deploy
```

Do not use `--node` for a move that involves another node. Hostenv rejects a node-filtered deployment when the migration requires a source outside the selected node.

If more than one possible source is found, specify the source explicitly:

```bash
nix run .#hostenv-provider -- deploy --migration-source ENVIRONMENT=NODE
```

If a migration stops before it finishes, correct the reported problem and run the unfiltered `deploy` command again. Migration progress is designed to be resumed safely.

## Retiring or removing a node

Do not remove a node from `provider.nodeSystems` while it still hosts Hostenv environments.

To retire a node safely:

1. remove the node from any `provider.nodeFor` assignment;
2. keep it in `provider.nodeSystems` and mark it as retiring:

   ```nix
   provider.nodeStatus.old-node = "retiring";
   ```

3. run `plan`, then run an unfiltered `deploy` so that environments can move and old accounts can be cleaned up;
4. repeat the deployment if Hostenv reports a recoverable migration or DNS problem; and
5. once the node is clean, remove it from `nodeSystems`, `nodeStatus`, and `nodes/<name>/`, then run `plan` again.

A retiring node remains managed and reachable for migration and clean-up, but Hostenv will not schedule new environments onto it.

Hostenv performs additional checks before allowing a node to disappear from the inventory. If it refuses the change, restore the node to `provider.nodeSystems`, complete the required migration or clean-up, and try again.

## DNS and HTTPS during deployment

DNS reconciliation is part of `deploy`; there is no separate DNS deployment command.

For a new environment, or an environment staying on the same node, Hostenv deploys the desired configuration before changing DNS.

For a migration, Hostenv first deploys and verifies the destination, then stops the source environment before moving DNS. The old source account is removed only after DNS points to the destination and, if Let's Encrypt is enabled, the destination presents a publicly trusted certificate.

If Cloudflare credentials are configured, Hostenv can update the required records automatically. Otherwise, it stops at a safe point and tells you what DNS change is required. Make the change, then rerun `deploy`.

After DNS has moved during a migration, Hostenv may wait for up to 20 minutes for a trusted HTTPS certificate to become available. If DNS or certificate verification fails, Hostenv keeps the old source rather than removing it prematurely. Fix the reported problem and rerun `deploy`.

## Provider-managed application secrets

See [Managing Provider Secrets](provider-secrets.md) for the SOPS and age setup, key management, and editing workflow.

Application secrets may be defined at three scopes, from most specific to least specific:

```text
<environment-user>
<organisation>_<project>
<organisation>
```

A more specific value overrides a broader one. Use the narrowest practical scope, particularly for production credentials and application keys.

Laravel requests `laravel_env` automatically. Applications using Hostenv backups may also request `backups_secret` and `backups_env`.

## Shared NixOS configuration

Use `provider.nodeModules` for NixOS configuration that should apply to every provider node:

```nix
provider.nodeModules = [ "nodes/common.nix" ];
```

Paths are relative to the provider repository. Keep machine-specific settings in each node's own `nodes/<node>/configuration.nix`.

## Recovery and exceptional deploy options

Most deployment failures are recoverable: fix the cause, then rerun `deploy`. In particular, interrupted migrations retain enough provider-owned state for Hostenv to continue without treating the destination as a new environment.

The following options are intended for exceptional cases:

- `--migration-source ENV=NODE` selects a source when Hostenv finds more than one possible migration source.
- `--skip-migrations ENV` deliberately skips migration for an environment for that run. Hostenv preserves the source rather than finalising its removal.
- `--skip-verification` bypasses post-deployment verification checks.
- `--ignore-migration-errors` continues after migration errors and may deploy with stale data. Use it only when you have deliberately accepted that risk.
- `--node NODE` restricts deployment to one node. It is useful for ordinary node-scoped work, but not for migrations that need another node to participate.

When in doubt during a failed or interrupted migration, keep both nodes in `provider.nodeSystems` and rerun an unfiltered deployment rather than deleting state or manually removing Hostenv accounts.
