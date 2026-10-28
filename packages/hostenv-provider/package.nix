# `src` would be filled from pkgs.src by callPackage, instead of using ./.
{ pkgs, sourceRoot ? ./., documentationEnabled ? false }:
let
  raw = pkgs.haskellPackages.callCabal2nix "hostenv-provider-cli" sourceRoot { };
  unwrapped =
    if documentationEnabled then
      raw
    else
      pkgs.haskell.lib.dontHaddock raw;
  runtimeInputs = [
    pkgs.jq
    pkgs.bind
    pkgs.curl
  ];
in
pkgs.writeShellApplication {
  name = "hostenv-provider";
  inherit runtimeInputs;
  text = ''
    set -euo pipefail
    exec ${unwrapped}/bin/hostenv-provider "$@"
  '';
  derivationArgs.passthru = {
    src = sourceRoot;
    inherit unwrapped runtimeInputs;
  };
}
