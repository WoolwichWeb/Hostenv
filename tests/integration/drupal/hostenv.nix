{ pkgs, config, lib, ... }: {

  packages = [ pkgs.hello ];

  services.drupal.enable = true;
  services.drupal.backups.enable = true;

  # To update this hash when dependencies change:
  # 1. Set to pkgs.lib.fakeHash
  # 2. Run `nix build .#checks.x86-linux.test-name`
  # 3. Copy the correct hash from the error message
  services.drupal.composer.dependencyHash = "sha256-70yrRF8rAphGSTqb+7DFYuDqbMVbpurFf5e6wT76zg4=";

  services.drupal.cron.timerConfig.OnCalendar = "*:0/5";

  environments.main = {
    enable = true;
    type = "production";
    virtualHosts = {
      "example.com" = {
        globalRedirect = "www.example.com";
      };
      "www.example.com" = { };
    };
  };

  environments.dev = {
    enable = true;
    type = "development";
  };

  environments.test = {
    enable = true;
    type = "testing";
    users = {
      minseo = {
        email = "minseo@example.com";
        publicKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO5upHahyHlSQTIslm9U0b27o+UpWK/Dsvfa/quS+gbf minseo@laptop"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKib1L6s33MJ0hkNirUiKmFaeVS7hRm+r8rxJRzxzXZD minseo@workstation"
        ];
      };
    };
  };

  allEnvironments = {
    users = {
      volodymyr = {
        email = "volodymyr@example.com";
        publicKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILW+Xjg3YAtFyRDrtyzwfEoPzV94WBaFDMxhfq2L+Ypf volodymyr"
        ];
      };
    };
  };

  services.nginx.virtualHosts."${config.services.drupal.codebase.name}".locations."/" = {
    extraConfig = lib.mkBefore ''
      # Location mkBefore test marker
    '';
  };
}
