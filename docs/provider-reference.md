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
`nodeSystems`, planning stops.

When that previous plan exists, removing a node that was marked `retiring`
also causes Hostenv to contact it using the previous connection details and
verify that no reserved Hostenv account or runtime state remains.

The previous plan is not persistent state. If it is missing or malformed,
Hostenv skips the historical comparison and uses live Hostenv-controlled DNS as
the durable node-removal tripwire. Before publishing the proposed plan, a CNAME
that identifies a node outside `provider.nodeSystems` aborts planning. If DNS
cannot be queried reliably (for example SERVFAIL, resolver failure, or `dig`
execution failure), planning also stops rather than treating the lookup as
evidence that no old node exists.

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

Source retirement is a resumable finalization transaction. Hostenv first
migrates data, deploys the destination system, successfully activates the
destination environment, and passes any enforced deployment verification. It
then records an `accepted` handoff, disables lingering/stops the old user
manager, and atomically promotes the handoff to `quiesced`.

Only after the source is quiesced does Hostenv cut the environment CNAME over to
the destination. If Cloudflare credentials are configured, `deploy` performs
the update and waits for the new CNAME to propagate. Otherwise it stops with the
source safely quiesced; update DNS manually and rerun `deploy`. Once DNS is
confirmed at the destination, Hostenv restores any desired TLS/ACME settings
that `dns-gate` temporarily disabled, redeploys the destination system, and
only then deploys the source system configuration that removes the old
account.

Handoff state is provider-owned root state under
`/var/lib/hostenv/provider/migration-handoffs/`, keyed by the environment's
stable UID. Environment users cannot read, forge, redirect, or delete it. Marker
updates use a same-directory temporary file and atomic rename, so interruption
while promoting `accepted` to `quiesced` leaves the previous accepted marker
intact rather than truncating the only recovery state.

On retry, an `accepted` marker does not suppress a fresh backup while the source
manager is still live. If the source manager is already stopped (or the passwd
entry is gone but orphan runtime remains), Hostenv can safely resume source
finalization without trying to use a dead user bus. Once a `quiesced` handoff
exists, a failed source-system deployment deliberately leaves the source
application stopped rather than restarting cron, queue workers, nginx, or other
source services alongside the live destination. Stale handoffs are cleared when
the same environment later becomes a live migration source again.

A node-filtered deploy also refuses to start a migration whose source is outside
the selected node. Run an unfiltered deploy so destination acceptance, source
quiescence, DNS cutover, and source finalization participate in the same
operation.

`dns-gate --with-dns-update` may create or repair Cloudflare records for new
environments, but it refuses to move a CNAME that currently identifies another
Hostenv node. In that case it only gates ACME/forceSSL and saves the desired TLS
settings for `deploy` to restore after migration cutover.

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

Keep `generated/state.json` in version control. Hostenv deliberately keeps
this state small: stable environment UIDs and hostname reservations. Environment
placement and provider-node history are not stored there; deployment observes
Hostenv users on the provider nodes when deciding migrations and cleanup, and
does not modify `state.json`.

`generated/plan.json` is disposable generated output. If an existing copy is
valid, `hostenv-provider plan` additionally compares its node/environment
assignments with the proposed plan. If it is absent or malformed, Hostenv skips
that historical comparison and still performs the live DNS safety check before
publishing the replacement plan.

Before publishing a proposed plan, Hostenv also checks Hostenv-controlled DNS.
If an environment hostname still CNAMEs to a provider-looking node that is
missing from the proposed `provider.nodeSystems`, planning stops before
`dns-gate` can update that DNS record. DNS lookup failure is also fatal for
this safety check; it is not treated as an empty answer.

A successful plan is published with a same-directory atomic rename, so
interruption cannot leave a partially written `generated/plan.json`.

Do not reset `generated/state.json` to `{}` as a troubleshooting step.
