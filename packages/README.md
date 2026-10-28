# Hostenv packages

Hostenv's software packages live in this directory. Each package has its own
directory and a `package.nix` file that defines how to build it:

- `hostenv-provider`: the provider's command-line tool.
- `hostenv-provider-service`: the provider's web service and development launcher.
- `hostenv-runtime`: system helpers for HTTPS certificates and private network
  endpoints.

## Using a package

Modules obtain packages by name through `config.flake.lib.hostenv.packagesFor`:

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

`packagesFor pkgs` discovers the packages automatically and builds them
with the supplied Nixpkgs package set. Consumers need not know where a
package's `package.nix` file lives.

## Adding a package

Add `packages/<name>/package.nix` as a Nix function that returns a
derivation. The package will be available as
`(packagesFor pkgs).<name>` without adding it to a central list.

Environment activation scripts and generated service configuration stay
with the feature modules that produce them, because their contents depend
on each environment's evaluated settings.
