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

This writes configuration files necessary for deployment under `generated/`.

Commit `generated/state.json` to the provider repository. Hostenv uses it to
keep persistent state between deployments, including UIDs and hostname
reservations between deployments.

`generated/plan.json` is a snapshot of the inventory's Nix configuration,
which may be committed to git or deleted, depending on your auditing needs.

`generated/flake.nix` tracks every project environment as a separate input,
as opposed to `flake.nix` with one input per-project.

## 6. Deploy

```bash
nix run .#hostenv-provider -- deploy
```

## 7. Deleting a server / Migrating environments to a new server

Before deleting a server from the inventory, or if moving environments to
a new server, remove the old server from `provider.nodeFor` but keep it in
`provider.nodeSystems` and set:

```nix
provider.nodeStatus.old-node = "retiring";
```

Hostenv will manage moving the environments on that server to another one
with the same role.

## Next steps

- [Manage provider secrets](provider-secrets.md).
- [Use multiple nodes](provider-reference.md#multiple-nodes).
- [Add more client projects](provider-reference.md#client-projects).
- [Configure runtime secret scopes](provider-reference.md#runtime-secrets).
- [Share NixOS configuration between nodes](provider-reference.md#shared-node-configuration).
