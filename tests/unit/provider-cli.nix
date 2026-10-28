{ pkgs, documentationEnabled }:
import ../../packages/hostenv-provider/tests.nix {
  inherit pkgs documentationEnabled;
}
