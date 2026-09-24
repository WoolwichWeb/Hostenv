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
this state small: stable environment UIDs, the last node placement observed
during deployment, and hostname reservations. Planning does not mark a move as
complete; deployment reconciles the recorded node from the accounts actually
present on the affected nodes.

Do not reset it to `{}` as a troubleshooting step. Removing existing state can
make Hostenv treat established environments as new ones.
