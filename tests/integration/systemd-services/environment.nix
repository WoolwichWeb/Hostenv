{ pkgs, makeHostenv }:

makeHostenv [
  ({ config, ... }: {
    hostenv = {
      organisation = "test";
      project = "services";
      root = pkgs.emptyDirectory;
      hostenvHostname = "hosting.test";
    };

    environments.main = {
      enable = true;
      type = "testing";
    };

    services.mysql = {
      enable = true;
      user = config.hostenv.userName;
      package = pkgs.mariadb;
      settings.mysqld.innodb_buffer_pool_size = "64M";
    };

    services.postgresql = {
      enable = true;
      user = config.hostenv.userName;
    };

    services.phpfpm.pools.smoke.settings = {
      pm = "static";
      "pm.max_children" = 1;
    };

    services.nginx.virtualHosts."services.hosting.test".locations."/".return =
      "200 hostenv-nginx-ready";
  })
] "main"
