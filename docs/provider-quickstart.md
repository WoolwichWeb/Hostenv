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

## 6. Check DNS

```bash
nix run .#hostenv-provider -- dns-gate
```

If you have configured Hostenv's Cloudflare integration, `--with-dns-update`
can create or repair DNS for new environments. It will not move a hostname that
currently CNAMEs to another Hostenv node; that is a migration, and `deploy`
owns the cutover after the source is safely quiesced.

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

Hostenv keeps retiring nodes deployable for migration and cleanup. For a move,
it deploys and verifies the destination, quiesces the source, cuts DNS over to
the destination and waits for propagation, restores any TLS settings that
`dns-gate` temporarily disabled, and only then removes the old account.

If automatic Cloudflare cutover is unavailable, `deploy` stops after
quiescing the source. Update the CNAME manually and rerun `deploy`; Hostenv
resumes from the handoff instead of taking another backup. After a node is
clean and DNS no longer points at it, remove it from the provider inventory.

## Next steps

- [Manage provider secrets](provider-secrets.md).
- [Use multiple nodes](provider-reference.md#multiple-nodes).
- [Add more client projects](provider-reference.md#client-projects).
- [Configure runtime secret scopes](provider-reference.md#runtime-secrets).
- [Share NixOS configuration between nodes](provider-reference.md#shared-node-configuration).
