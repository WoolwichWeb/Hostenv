{ pkgs, hostenv }:
let
  lib = pkgs.lib;
  support = import ../support { inherit pkgs lib; };
  asserts = support.asserts;
  resticModule = hostenv.lib.hostenv.modules.restic;

  restic_exclusive_repo =
    let
      eval = support.evalWithBase {
        modules = [
          resticModule
          ({ ... }: {
            hostenv.cacheDir = "/tmp/hostenv-cache";
            hostenv.userName = "restic-test";
            hostenv.backupsRepoHost = "s3:https://backups.invalid";
          })
          ({ ... }: {
            _module.check = false;
            services.restic.enable = true;
            services.restic.backups.bad = {
              paths = [ "/data" ];
              repository = "s3:https://example.invalid";
              repositoryFile = pkgs.writeText "repo-file" "s3:https://other.invalid";
              environmentFile = null;
              passwordFile = "/tmp/pw";
            };
          })
        ];
      };
      anyFail = lib.any (a: a.assertion == false) eval.config.assertions;
    in
    asserts.assertTrue "restic-exclusive-repo-assert" anyFail
      "Expected restic assertion to fail when repository and repositoryFile are both set";

  restic_repo_envfile_ok =
    let
      eval = support.evalWithBase {
        modules = [
          resticModule
          ({ ... }: {
            hostenv.cacheDir = "/tmp/hostenv-cache";
            hostenv.userName = "restic-test";
            hostenv.backupsRepoHost = "s3:https://backups.invalid";
          })
          ({ ... }: {
            _module.check = false;
            services.restic.enable = true;
            services.restic.backups.ok = {
              paths = [ "/data" ];
              repository = "s3:https://example.invalid";
              repositoryFile = null;
              environmentFile = "/tmp/envfile";
              passwordFile = "/tmp/pw";
            };
          })
        ];
      };
      assertionsOk = ! lib.any (a: a.assertion == false) eval.config.assertions;
      service = eval.config.systemd.services."restic-backups-ok";
      env = service.environment or { };
      repoOk = (env.RESTIC_REPOSITORY or "") == "s3:https://example.invalid";
      repoFileNull = (env.RESTIC_REPOSITORY_FILE or null) == null;
      wrapperOk = eval.config.services.restic.wrapperScripts ? ok;
      execStart = service.serviceConfig.ExecStart or [ ];
      hasTag = lib.any (cmd: lib.strings.hasInfix "--tag ok" cmd) execStart;
    in
    asserts.assertTrue "restic-repo-envfile-ok"
      (assertionsOk && repoOk && repoFileNull && wrapperOk && hasTag)
      "restic repo+envfile should pass assertions, set repository/env correctly, and tag snapshots by default";

in
{
  inherit restic_exclusive_repo restic_repo_envfile_ok;
}
