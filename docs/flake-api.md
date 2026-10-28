# Hostenv flake API

Hostenv provides Nix modules and functions for project and hosting-provider
flakes. This page is for developers building on Hostenv or adding features to
it. You should be familiar with Nix flakes and the Nix module system.

A **project flake** reads the project's `hostenv.nix`, lists its hosting
environments, and provides a package to activate each enabled environment.
A **provider flake** consumes project flakes and prepares the NixOS machines
that host them. The **Hostenv library flake** supplies the modules and
functions used by both.

## Project and provider entrypoints

Hostenv exports two flake-parts modules:

| Output | What it sets up |
| --- | --- |
| `flakeModules.project` | Project configuration, environment discovery, activation packages, and CLI commands. |
| `flakeModules.provider` | Provider options, deployment planning, and provider tools. |

A project flake imports `hostenv.flakeModules.project` and supplies its
configuration modules:

```nix
imports = [ hostenv.flakeModules.project ];

perSystem = { ... }: {
  hostenvProject.modules = [
    ./hostenv.nix
    {
      hostenv = {
        organisation = "example";
        project = "website";
        hostenvHostname = "hosting.example.org";
        root = ../.;
      };
    }
  ];
};
```

The `hostenvProject.modules` list is where the project supplies its
`hostenv.nix` and other project-wide configuration. See
`template/project/.hostenv/flake.nix` for a complete project flake.

A hosting provider instead imports `hostenv.flakeModules.provider` and sets
its `provider` options. See `template/provider/flake.nix` and the
[provider quickstart](provider-quickstart.md).

## Exported modules

Hostenv exports two kinds of modules, for two different configuration
systems:

| Output | Where to use it |
| --- | --- |
| `nixosModules.<name>` | In a NixOS system configuration, such as the machines that run Hostenv. |
| `lib.hostenv.modules.<name>` | In the module evaluation for a single hosting environment (services, applications, and their settings). |

A NixOS module belongs in the `modules` list passed to
`nixpkgs.lib.nixosSystem`. A Hostenv environment module belongs in a Hostenv
evaluation, not a NixOS system. Keeping these separate helps catch accidental
mixing of the two types of configuration.

To add an environment feature in a flake-parts module, contribute to
`flake.modules.hostenv.<name>`:

```nix
{ ... }: {
  flake.modules.hostenv.example = { lib, ... }: {
    options.services.example.enable =
      lib.mkEnableOption "the example service";
  };
}
```

All modules contributed by the current flake, including modules added by
a project, participate when that flake evaluates its environments. See the
[Dendritic Pattern guide](dendritic-structure.md) for how feature modules
are organised.

## Discovering and evaluating environments

Two functions are available for each supported system:

| Output | What it returns |
| --- | --- |
| `lib.hostenv.discoverProject.<system>` | The declared environments and the chosen default environment, without evaluating all runtime services. |
| `lib.hostenv.makeHostenv.<system>` | The result of evaluating one named environment's full module configuration. |

Both accept a list of project configuration modules; `makeHostenv` also
takes the environment name. For example, in a flake-parts feature file:

```nix
{ config, ... }:
{
  perSystem = { system, ... }:
    let
      projectModules = [
        ./hostenv.nix
        {
          hostenv = {
            organisation = "example";
            project = "website";
            hostenvHostname = "hosting.example.org";
            root = ../.;
          };
        }
      ];
      project = config.flake.lib.hostenv.discoverProject.${system} projectModules;
      main = config.flake.lib.hostenv.makeHostenv.${system} projectModules "main";
    in
    {
      packages.example = main.config.activatePackage;
    };
}
```

Here `config` refers to the surrounding flake-parts evaluation. Using
`config.flake.lib.hostenv.makeHostenv` means that any Hostenv modules added
by this project are included; directly using the upstream Hostenv flake's
evaluator would omit them.

Project flakes also expose
`lib.hostenv.<system>.environments` and
`lib.hostenv.<system>.defaultEnvironment` so a provider can discover
environments without evaluating every service.

When planning a deployment, the provider uses each project's exported
`makeHostenv` function to evaluate its enabled environments. The project's
input name (for example, `example__website`) determines the organisation
and project identity used by the provider. The provider also supplies its
hosting domain; the project supplies its application source root.

The provider checks that the evaluator returns the expected identity and
consistent runtime paths. It refuses to generate a plan if those checks
fail. A provider must still choose which project revisions to trust:
project flakes contain Nix code, not merely passive configuration data.

## Reusable packages

`lib.hostenv.packagesFor pkgs` discovers software packages in `packages/`
using the given Nixpkgs package set. A module can obtain a package by name:

```nix
{ config, ... }:
let
  packagesFor = config.flake.lib.hostenv.packagesFor;
in
{
  flake.modules.hostenv.example = { pkgs, ... }: {
    profile = [ (packagesFor pkgs).hostenv-runtime ];
  };
}
```

On Linux, the library flake also provides
`packages.<system>.hostenv-provider`,
`packages.<system>.hostenv-provider-service`, and
`packages.<system>.hostenv-runtime`. See
[the packages README](../packages/README.md) for their purposes.

## Where to look in the repository

`modules/exports.nix` exports the public module API;
`modules/hostenv.nix` defines the environment evaluator;
`modules/entrypoints/` contains the project and provider entrypoints; and
`modules/flake/packages.nix` handles package discovery.

These files are flake-parts modules. Within them, `config.flake` refers
to the current flake's combined configuration. This matters when a
project contributes its own modules: `inputs.self` refers to the
already-constructed input flake, not the current project's additions.
