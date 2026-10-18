{ ... }:
{
  flake.modules.hostenv.native-sockets =
    { config, lib, ... }:
    let
      pathsOnly = values: lib.filter (value: builtins.isString value && lib.hasPrefix "/" value) values;
      listenPaths = value: pathsOnly (lib.toList value);
      postgres = config.services.postgresql;
      postgresDirectories = lib.splitString "," (postgres.settings.unix_socket_directories or postgres.runtimeDir);
    in
    {
      # Register existing listeners without creating, renaming or changing them.
      # Native daemons keep ownership of their sockets and authentication.
      networking.reservedSocketPaths = lib.mkMerge [
        (lib.mkIf config.services.mysql.enable [ config.services.mysql.settings.mysqld.socket ])
        (lib.mkIf config.services.redis.enable [ config.services.redis.socket ])
        (lib.mkIf postgres.enable (map
          (directory: "${lib.strings.trim directory}/.s.PGSQL.${toString (postgres.settings.port or 5432)}")
          (lib.filter (directory: lib.hasPrefix "/" (lib.strings.trim directory)) postgresDirectories)))
        (lib.mkIf config.services.phpfpm.enable (pathsOnly (lib.mapAttrsToList
          (_: pool: pool.settings.listen) config.services.phpfpm.pools)))
        (lib.concatLists (lib.mapAttrsToList (_: unit:
          lib.optionals unit.enable (listenPaths (unit.socketConfig.ListenStream or [ ]) ++ listenPaths unit.listenStreams)
        ) config.systemd.sockets))
      ];
    };
}
