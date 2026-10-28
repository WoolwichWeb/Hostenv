{
  pkgs,
  # `src` would be filled from pkgs.src by callPackage.
  sourceRoot ? builtins.path {
    path = ./.;
    name = "hostenv-provider-service-src";
  },
  dependencyDocumentationEnabled ? true,
  haskellDeps ? [
    "aeson"
    "bytestring"
    "containers"
    "cookie"
    "cryptonite"
    "http-client"
    "http-client-tls"
    "http-types"
    "lucid"
    "memory"
    "network"
    "postgresql-simple"
    "process"
    "servant"
    "servant-server"
    "text"
    "tagged"
    "time"
    "turtle"
    "unix"
    "wai"
    "warp"
  ],
}:
let
  ghc =
    (pkgs.haskellPackages.ghcWithPackages.override {
      installDocumentation = dependencyDocumentationEnabled;
    }) (p: map (name: p.${name}) haskellDeps);
  service = pkgs.writeShellScriptBin "hostenv-provider-service" ''
    exec ${ghc}/bin/runghc -i${sourceRoot} ${sourceRoot}/Main.hs "$@"
  '';
in
service.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    src = sourceRoot;
    inherit haskellDeps ghc;
    dev = pkgs.callPackage ./dev.nix { inherit service; };
  };
})
