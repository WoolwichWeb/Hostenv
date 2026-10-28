{ inputs, lib, ... }:
let
  packagesFor = pkgs:
    pkgs.lib.filesystem.packagesFromDirectoryRecursive {
      inherit (pkgs) callPackage;
      directory = ../../packages;
    };
in
{
  flake.lib.hostenv.packagesFor = packagesFor;

  perSystem = { pkgs, config, ... }:
    lib.mkIf (!(inputs ? hostenv) && pkgs.stdenv.hostPlatform.isLinux) {
      packages = {
        inherit (packagesFor pkgs) hostenv-runtime;
        hostenv-provider = (packagesFor pkgs).hostenv-provider.override {
          documentationEnabled = config.documentation.haskell.haddock.enable;
        };
        hostenv-provider-service = (packagesFor pkgs).hostenv-provider-service.override {
          dependencyDocumentationEnabled = config.documentation.haskell.dependencies.enable;
        };
      };
    };
}
