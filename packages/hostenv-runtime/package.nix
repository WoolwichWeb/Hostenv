{ pkgs }:
let
  raw = pkgs.haskellPackages.callPackage ./generated.nix { };
in
pkgs.haskell.lib.justStaticExecutables (pkgs.haskell.lib.dontHaddock raw)
