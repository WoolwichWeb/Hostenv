{ inputs, lib, ... }:
let
  packagesFor = pkgs:
    pkgs.lib.filesystem.packagesFromDirectoryRecursive {
      inherit (pkgs) callPackage;
      directory = ../../packages;
    };
in
{
  # Package definitions live outside the import-tree modules. Consumers use
  # this accessor rather than depending on the package files' locations.
  flake.lib.hostenv.packagesFor = packagesFor;

  perSystem = { pkgs, ... }:
    lib.mkIf (!(inputs ? hostenv) && pkgs.stdenv.hostPlatform.isLinux) {
      packages.hostenv-runtime = (packagesFor pkgs).hostenv-runtime;
    };
}
