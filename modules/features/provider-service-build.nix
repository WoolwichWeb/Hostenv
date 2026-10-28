{ inputs, lib, config, ... }:
let
  fp = inputs.flake-parts.lib;
  packagesFor = config.flake.lib.hostenv.packagesFor;
  providerEnabled = config.provider.enable or false;
in
{
  options.perSystem = fp.mkPerSystemOption ({ config, pkgs, ... }:
    let
      service = (packagesFor pkgs).hostenv-provider-service.override {
        dependencyDocumentationEnabled = config.documentation.haskell.dependencies.enable;
      };
    in
    {
      config = lib.mkIf providerEnabled {
        packages.hostenv-provider-service = service;
        apps.hostenv-provider-service = {
          type = "app";
          program = "${service}/bin/hostenv-provider-service";
          meta.description = "Hostenv provider service development app";
        };
        hostenv.haskell.devPackages = service.haskellDeps;
        devshells.default.devshell.packages = [ service service.dev ];
      };
    });
}
