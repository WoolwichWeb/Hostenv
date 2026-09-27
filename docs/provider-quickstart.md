# Provider Quickstart

This guide takes a new Hostenv provider from an empty repository to its first deployment.

## 1. Initialize the provider

Start with the provider template:

```bash
nix flake init -t gitlab:woolwichweb/hostenv#provider
```

Open `flake.nix` and edit the `provider` block near the bottom:

```nix
provider = {
  hostenvHostname = "hosting.example.com";
  deployPublicKeys = [ "ssh-ed25519 AAAA..." ]; # replace with your key

  # Put environments on node-a unless configured otherwise.
  nodeFor.default = "node-a";

  # node-a is an x86_64 Linux machine.
  nodeSystems.node-a = "x86_64-linux";

  letsEncrypt.adminEmail = "admin@hosting.example.com";
  letsEncrypt.acceptTerms = true;
};
```

Use `aarch64-linux` instead if the node is ARM64.

## 2. Configure the node

Copy the sample node configuration:

```bash
cp -r nodes/sample nodes/node-a
```

Edit `nodes/node-a/configuration.nix` and
`nodes/node-a/hardware-configuration.nix` for the machine you are deploying to.
The directory name must match the node selected by `nodeFor` in `flake.nix`.

## 3. Add a client project

Add the client project as an input in `flake.nix`:

```nix
inputs.acme__website = {
  # Point at the Hostenv flake in the client project.
  url = "gitlab:acme/website?dir=.hostenv&ref=main";

  inputs.nixpkgs.follows = "nixpkgs";
  inputs.hostenv.follows = "hostenv";
  inputs.flake-parts.follows = "flake-parts";
};
```

Name project inputs `organisation__project`. Change `ref=main` if the project's
Hostenv configuration lives on another branch.

## 4. Configure secrets

Create the encrypted provider secrets file at `secrets/secrets.yaml`.

See [Managing Provider Secrets](provider-secrets.md) for a complete example
using SOPS and age on NixOS or Ubuntu with Nix installed.

## 5. Generate the plan

```bash
nix run .#hostenv-provider -- plan
```

This writes the deployment files under `generated/`.

Commit `generated/state.json` to the provider repository. It contains the
durable information Hostenv cannot safely reconstruct: stable environment UIDs
and hostname reservations. It does not store environment placement or
provider-node history.

`generated/plan.json` is disposable generated output. When a previous copy is
present, `hostenv-provider plan` uses its environment assignments as an
additional transition check. If it is missing or malformed, planning skips that
historical comparison and relies on live Hostenv DNS as the node-removal safety
tripwire. A CNAME to a node outside the proposed inventory blocks the plan.

## 6. Deploy

```bash
nix run .#hostenv-provider -- deploy
```

Use `-n node-a` to deploy only that node when no cross-node migration is
required. Migrations must run unfiltered so destination deployment, source
quiescence, DNS cutover, and source cleanup stay in one resumable operation.

Before changing any public DNS, `deploy` checks every environment's vhosts. A
fresh environment or an existing same-node environment whose DNS is not ready is
first deployed with a transient HTTP-only configuration. For a migration, the
destination is staged and verified before the source is quiesced. Only then does
Hostenv move DNS to the destination.

When Cloudflare credentials are configured, deploy creates or repairs the
required CNAMEs and waits for propagation. Without automatic DNS credentials,
deploy stops at the safe staging/quiesced point; update DNS manually and rerun.

`generated/plan.json` is never changed to represent staging. It always
describes the desired end state. Once DNS is ready, Hostenv attempts that desired
TLS/ACME configuration. If certificate activation fails but the HTTP-only
configuration succeeds, the environment remains available over HTTP and deploy
reports a warning instead of failing the whole application deployment. A later
deploy retries TLS.

When draining a node, remove it from any `provider.nodeFor` mapping but keep
it in `provider.nodeSystems` and set:

```nix
provider.nodeStatus.old-node = "retiring";
```

Hostenv keeps retiring nodes deployable for migration and cleanup. Source
accounts are removed only after destination verification, source quiescence and
DNS cutover have completed.

## Next steps

- [Manage provider secrets](provider-secrets.md).
- [Use multiple nodes](provider-reference.md#multiple-nodes).
- [Add more client projects](provider-reference.md#client-projects).
- [Configure runtime secret scopes](provider-reference.md#runtime-secrets).
- [Share NixOS configuration between nodes](provider-reference.md#shared-node-configuration).
