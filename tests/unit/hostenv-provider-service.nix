{ pkgs, documentationEnabled }:
let
  src = (pkgs.callPackage ../../packages/hostenv-provider-service/package.nix { }).src;
  rawServicePkg = pkgs.haskellPackages.callCabal2nix "hostenv-provider-service" src { };
  servicePkg =
    if documentationEnabled then
      rawServicePkg
    else
      pkgs.haskell.lib.dontHaddock rawServicePkg;
  ghc =
    (pkgs.haskellPackages.ghcWithPackages.override {
      installDocumentation = documentationEnabled;
    })
      (p: [
        p.aeson
        p.bytestring
        p.cryptonite
        p.memory
        p.text
      ]);

in
{
  hostenv-provider-service-build = servicePkg;
  hostenv-provider-service-tests = pkgs.runCommand "hostenv-provider-service-tests" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/Test.hs
    echo ok > $out
  '';
}
