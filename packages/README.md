# Hostenv packages

Hostenv's software packages live here. Each package has its own directory,
with a `package.nix` file defining how to build it.

When using a package from a Hostenv module, access it by name through
`config.flake.lib.hostenv.packagesFor pkgs` rather than referring to its
`package.nix` file directly.
