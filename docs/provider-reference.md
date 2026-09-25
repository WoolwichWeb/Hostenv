# Provider Reference

Start with the [Provider Quickstart](provider-quickstart.md) if you are setting up a provider for the first time.

## Multiple nodes

`nodeFor` chooses which node hosts an environment. `nodeSystems` tells Hostenv
what kind of machine each node is.

A single-node provider only needs a default:

```nix
provider = {
  nodeFor.default = "node-a";
  nodeSystems.node-a = "x86_64-linux";
};
```

To put production environments on a different node:

```nix
provider = {
  nodeFor.default = "node-a";
  nodeSystems.node-a = "x86_64-linux";

  nodeFor.production = "node-b";
  nodeSystems.node-b = "aarch64-linux";
};
```

`nodeFor.testing` and `nodeFor.development` work the same way.

Each node should have a matching directory under `nodes/` containing its
`configuration.nix` and `hardware-configuration.nix`.

### Retiring or removing a node

Keep a source node in `provider.nodeSystems` until every Hostenv environment
has either moved away from it or been retired. Hostenv treats `nodeSystems`
as the authoritative provider inventory when reconciling placement.

A safe node retirement is therefore:

1. stop assigning environments to the node with `nodeFor`;
2. keep the node in `provider.nodeSystems` and declare it retiring:

   ```nix
   provider.nodeStatus.old-node = "retiring";
   ```

   Retiring nodes remain deployable and observable, but Hostenv rejects
   `nodeFor` mappings that would schedule environments onto them;
3. deploy the moves or retirements until Hostenv has removed the old
   environment accounts;
4. remove the node from `nodeSystems`, `nodeStatus`, and its
   `nodes/<name>/` configuration.

When an existing valid `generated/plan.json` is available,
`hostenv-provider plan` uses it as an additional transition check. If an
environment was assigned to a node that disappears from the proposed
`nodeSystems`, planning stops. Removing a previously retiring node also causes
Hostenv to contact it using the previous plan's connection details and inspect
its passwd database; the node is removed only when no reserved Hostenv account
remains.

The previous plan is not persistent state and is never required to regenerate
the provider configuration. If it is missing or malformed, Hostenv skips the
historical comparison and still checks Hostenv-controlled DNS before publishing
the proposed plan. A CNAME that identifies a node outside the proposed
inventory aborts planning, before `dns-gate` has an opportunity to change DNS.

A UID reservation in `state.json` does **not** mean an environment has
already been deployed; planning a brand-new environment creates its reservation
before the first deployment. Hostenv therefore decides placement from live
username+UID matches on inventory nodes, not from reservation age or history.

As an additional best-effort guard, when a migration-enabled environment has
no live source, Hostenv checks its generated Hostenv hostname. If that hostname
still CNAMEs to `<node>.<hostenvHostname>` and that node is no longer in
`provider.nodeSystems`, deployment stops and asks you to restore the node to
inventory. DNS may already have changed by deployment time, so this check
cannot prove that an absent environment is new. The inventory rule remains the
hard requirement: do not remove a node while it still owns Hostenv
environments.

Source retirement is a finalization step: Hostenv first migrates data, deploys
the destination system, successfully activates the destination environment, and
passes any enforced deployment verification. Only then does it disable
lingering/stop the old user manager and deploy the source system configuration
that removes the account. If a source system deployment fails, Hostenv attempts
to restore the old user manager so a retry remains possible.

`--skip-migrations` and ignored migration failures protect their source
accounts for that run. Hostenv may defer the corresponding source-node system
deployment rather than destroy data that was intentionally not migrated.

## Client projects

Add each client project to the provider's `flake.nix` as an input named
`organisation__project`:

```nix
inputs.acme__website = {
  url = "gitlab:acme/website?dir=.hostenv&ref=main";

  inputs.nixpkgs.follows = "nixpkgs";
  inputs.hostenv.follows = "hostenv";
  inputs.flake-parts.follows = "flake-parts";
};
```

Use `dir=.hostenv` when the project's Hostenv flake lives in its standard
`.hostenv` directory. Change `ref=main` when the Hostenv configuration should
come from another branch.

After adding or changing a project input, regenerate the plan:

```bash
nix run .#hostenv-provider -- plan
```

## Runtime secrets

See [Managing Provider Secrets](provider-secrets.md) for the complete SOPS/age
setup and editing workflow.

Projects may request provider-managed secret files by name. The provider looks
for each requested secret at environment, project, and organisation scope and
makes it available only to the corresponding environment user.

Laravel automatically requests `laravel_env`. An environment-specific value in
`secrets/secrets.yaml` looks like:

```yaml
myproject-main-a1b2c3d:
  laravel_env: |
    APP_KEY=base64:replace-with-the-generated-application-key
    MAIL_USERNAME=optional-external-service-user
    MAIL_PASSWORD=optional-external-service-password
```

The same secret can instead be placed below `<organisation>_<project>` to share
it between that project's environments, or below `<organisation>` to share it
between projects in the organisation. More specific values override broader
ones.

For applications that use Hostenv backups, the same scopes can contain the
backup credentials requested by that application, such as `backups_secret` and
`backups_env`.

## Shared node configuration

Use `provider.nodeModules` for NixOS configuration that should apply to every
provider node:

```nix
provider.nodeModules = [ "nodes/common.nix" ];
```

Paths are relative to the provider repository. Keep machine-specific settings
in each node's own `nodes/<node>/configuration.nix`.

## State

Keep both `generated/state.json` and `generated/plan.json` in version
control. Hostenv deliberately keeps `state.json` small: stable environment
UIDs and hostname reservations. Node placement is not stored there; deployment
observes Hostenv users on the provider nodes when deciding migrations and
cleanup, and does not modify `state.json`.

The previous `plan.json` is retained as generated configuration, not mutable
deployment state. `hostenv-provider plan` uses its node inventory and
connection data to enforce the explicit active → retiring → removed lifecycle.
If a provider already has state reservations but the previous plan is missing,
planning stops rather than guessing that node removal is safe.

Do not reset state to `{}` or delete the previous generated plan as a
troubleshooting step.
