{ ... }:
{
  flake.modules.hostenv.api-fixture = { lib, ... }: {
    options.apiFixture = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    config.apiFixture = [ "first" ];
  };

  flake.modules.nixos.api-fixture = { lib, ... }: {
    options.apiFixture = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    config.apiFixture = [ "nixos" ];
  };
}
