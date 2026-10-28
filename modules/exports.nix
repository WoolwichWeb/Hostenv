{ lib, inputs, config, ... }:
let
  types = lib.types;

  mkFlakeModule = cfg: { ... }:
    {
      imports = [
        inputs.devshell.flakeModule
        (inputs.import-tree ./.)
      ];
      _file = builtins.toString ./exports.nix;
    } // cfg;
in
{
  options.flake = {
    lib = lib.mkOption {
      type = types.submodule {
        freeformType = types.attrsOf types.unspecified;
        options = { };
      };
      default = { };
      description = "Library outputs merged under flake.lib.";
    };

    flakeModules = lib.mkOption {
      type = types.attrsOf types.deferredModule;
      default = { };
      description = "Exported flake-parts modules (merged across modules).";
    };
  };

  config = {
    flake.flakeModules = lib.mkIf (inputs ? import-tree) {
      exports = ./exports.nix;
      project = mkFlakeModule { project.enable = true; provider.enable = false; };
      provider = mkFlakeModule { project.enable = false; provider.enable = true; };
    };

    flake.modules = lib.mkDefault { };

    flake.nixosModules = config.flake.modules.nixos;
    flake.lib.hostenv.modules = config.flake.modules.hostenv;

    # Keep the internal module collection out of public flake outputs.
    touchup.attr.modules.enable = false;
  };
}
