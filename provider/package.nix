{ pkgs, providerSrc, documentationEnabled ? false }:
let
  raw = pkgs.haskellPackages.callCabal2nix "hostenv-provider-cli" providerSrc { };
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
  wrapped = pkgs.writeShellApplication {
    name = "hostenv-provider";
    inherit runtimeInputs;
    text = ''
      set -euo pipefail
      exec ${unwrapped}/bin/hostenv-provider "$@"
    '';
  };
in
{
  inherit unwrapped runtimeInputs wrapped;
}
