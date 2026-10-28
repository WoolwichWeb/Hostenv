{ inputs, lib, ... }:
{
  perSystem = { pkgs, ... }:
    lib.mkIf (!(inputs ? hostenv) && pkgs.stdenv.hostPlatform.isLinux) {
      checks.flake-api = import ../../tests/integration/flake-api.nix {
        inherit inputs pkgs;
      };
    };
}
