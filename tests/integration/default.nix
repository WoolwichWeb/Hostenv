{ pkgs, envs, makeHostenv, inputs }:

# Integration / full-stack suites
(import ./drupal/tests.nix { inherit pkgs envs; })
// (import ./drupal7/tests.nix { inherit pkgs envs; })
// (import ./drupal6/tests.nix { inherit pkgs envs; })
// (import ./laravel/tests.nix { inherit pkgs envs; })
// { hostenv-cli-list = import ./cli-list.nix { inherit pkgs makeHostenv; }; }
// { hostenv-cli-legacy-completion = import ./cli-legacy-completion.nix { inherit pkgs makeHostenv; }; }
// { hostenv-cli-service-wrappers = import ./cli-wrappers.nix { inherit pkgs; env = envs.drupalProduction; }; }
// { hostenv-cli-project-upload = import ./cli-deploy.nix { inherit pkgs makeHostenv; }; }
// { hostenv-outputs-eval = import ./hostenv-outputs.nix { inherit pkgs makeHostenv inputs; }; }
// (import ./provider-plan.nix { inherit pkgs makeHostenv inputs; })
// (import ./provider-plan-regressions.nix { inherit pkgs makeHostenv inputs; })
// (import ./provider-template.nix { inherit pkgs; })
// { provider-plan-paths-eval = import ./provider-plan-paths.nix { inherit pkgs inputs; }; }
// { provider-tooling-plan-paths-eval = import ./provider-tooling.nix { inherit pkgs inputs; }; }
// (import ./provider-full.nix { inherit pkgs makeHostenv inputs; })
// (import ./provider-nixos-system.nix { inherit pkgs makeHostenv inputs; })
// { provider-service-module-eval = import ./provider-service-module.nix { inherit pkgs makeHostenv; }; }
// { devshells-eval = import ./devshells.nix { inherit pkgs makeHostenv inputs; }; }
// (import ./socket-contract.nix { inherit pkgs envs; })
// { hostenv-hostname = import ./hostname.nix { inherit pkgs makeHostenv; }; }
// { public-env-json = import ./public-env-json.nix { inherit pkgs makeHostenv; }; }
// pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
  provider-foreign-arch-deploy-eval = import ./provider-foreign-arch-deploy-eval.nix { inherit pkgs inputs; };
}
