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

Commit both `generated/state.json` and `generated/plan.json` to the provider
repository. `state.json` keeps only durable reservations (stable environment
UIDs and hostname ownership), while the previous generated plan lets Hostenv
validate provider-inventory transitions such as node retirement. Deployment
does not modify either file.

## 6. Check DNS

```bash
nix run .#hostenv-provider -- dns-gate
```

If you have configured Hostenv's Cloudflare integration and want it to update
DNS records, add `--with-dns-update`.

## 7. Deploy

```bash
nix run .#hostenv-provider -- deploy
```

Use `-n node-a` to deploy only that node.

When draining a node, remove it from any `provider.nodeFor` mapping but keep
it in `provider.nodeSystems` and set:

```nix
provider.nodeStatus.old-node = "retiring";
```

Hostenv keeps retiring nodes deployable for migration and cleanup, deploys and
activates each destination before retiring its source account, and refuses to
remove the node from inventory until a live check confirms no reserved Hostenv
accounts remain.

## Next steps

- [Manage provider secrets](provider-secrets.md).
- [Use multiple nodes](provider-reference.md#multiple-nodes).
- [Add more client projects](provider-reference.md#client-projects).
- [Configure runtime secret scopes](provider-reference.md#runtime-secrets).
- [Share NixOS configuration between nodes](provider-reference.md#shared-node-configuration).
