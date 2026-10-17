{ inputs, lib, config, ... }:
let
  cfgTop = config;
in
{
  perSystem = { system, pkgs, ... }:
    lib.mkIf (!(inputs ? hostenv))
      (
        let
          makeHostenv = cfgTop.flake.makeHostenv.${system};
          envs = import ../../tests/environments.nix { inherit pkgs makeHostenv; };
          drupalRoot = import ../../tests/integration/drupal/source.nix { inherit pkgs; };
        in
        {
          hostenvProject = {
            inherit makeHostenv;
            modules = [
              ../../tests/integration/drupal/hostenv.nix
              ({ ... }: {
                hostenv = {
                  organisation = "test";
                  project = "testproject";
                  hostenvHostname = "hosting.test";
                  root = drupalRoot;
                };
              })
            ];
            environmentName = "main";
          };

          checks = (import ../../tests {
            inherit pkgs envs makeHostenv inputs;
            documentationEnabled = false;
          }) // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            provider-acme-process-tests = import ../../tests/unit/acme-deployment.nix {
              inherit pkgs;
              runtime = (cfgTop.flake.lib.hostenv.packagesFor pkgs).hostenv-runtime;
            };
            provider-acme-cli = import ../../tests/unit/provider-acme-cli.nix {
              inherit pkgs;
            };
          };

          packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            provider-acme-vm-test = import ../../tests/integration/provider-acme-vm.nix {
              inherit pkgs;
              inherit (inputs) deploy-rs;
              acmeModule = cfgTop.flake.modules.nixos.provider-acme;
              hostenvTopLevelModule = cfgTop.flake.modules.nixos.hostenv-top-level;
              guardAcmeActivation = cfgTop.flake.lib.provider.guardAcmeActivation;
            };

            drupal6-vm-test = import ../../tests/integration/drupal6/vm-test.nix {
              inherit pkgs;
              env = envs.drupal6;
              hostenvNixosModule = cfgTop.flake.modules.nixos.hostenv-top-level;
            };

            gotenberg-vm-test = import ../../tests/integration/gotenberg/vm-test.nix {
              inherit pkgs;
              environments = [ envs.gotenbergA envs.gotenbergB envs.gotenbergWithoutNetworkNamespace ];
              hostenvNixosModule = cfgTop.flake.modules.nixos.hostenv-top-level;
            };

            laravel-syslog-vm-test = import ../../tests/integration/laravel/logging-vm-test.nix {
              inherit pkgs;
              env = envs.laravel11;
              hostenvNixosModule = cfgTop.flake.modules.nixos.hostenv-top-level;
            };

            # This is intentionally a package rather than a normal flake check:
            # it boots a controller plus two provider VMs and exercises the
            # destructive migration boundary through the real provider CLI.
            provider-migration-lifecycle-vm-test =
              import ../../tests/integration/provider-migration-vm.nix {
                inherit pkgs;
              };
          };
        }
      );
}
