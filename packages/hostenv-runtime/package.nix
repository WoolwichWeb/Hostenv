{ pkgs }:
let
  raw = pkgs.haskellPackages.callCabal2nix "hostenv-runtime" ./. { };
in
pkgs.haskell.lib.justStaticExecutables (pkgs.haskell.lib.dontHaddock raw)
