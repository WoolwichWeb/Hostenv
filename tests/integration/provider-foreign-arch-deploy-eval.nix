{ pkgs, inputs }:
let
  lib = pkgs.lib;
  asserts = import ../support/assert.nix { inherit pkgs lib; };

  # This test runs on x86_64-linux; the deployment target is aarch64-linux.
  targetSystem = "aarch64-linux";
  targetPkgs = import inputs.nixpkgs { system = targetSystem; };
  runtime = (inputs.self.lib.hostenv.packagesFor targetPkgs).hostenv-runtime;
in
# deploy-rs evaluates the system profile derivation before starting the remote
# build. Force the same runtime derivation's drvPath here: using callCabal2nix
# would require building an aarch64-linux cabal2nix derivation on the local
# x86_64-linux evaluator (import-from-derivation).
#
# Avoid evaluating a synthetic NixOS installation: its filesystem, bootloader
# and SOPS setup are unrelated to this regression.
asserts.assertTrue "provider-foreign-arch-deploy-eval" (
  runtime.system == targetSystem
  && lib.hasSuffix ".drv" runtime.drvPath
) "hostenv-runtime must evaluate for aarch64-linux from x86_64-linux without an ARM64 builder"
