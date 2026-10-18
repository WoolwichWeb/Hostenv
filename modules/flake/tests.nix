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
            endpoint-contracts = import ../../tests/integration/endpoints/contracts.nix {
              inherit pkgs makeHostenv;
            };
            endpoint-runtime-cli = pkgs.runCommand "endpoint-runtime-cli" {
              nativeBuildInputs = [ (cfgTop.flake.lib.hostenv.packagesFor pkgs).hostenv-runtime ];
            } ''
              if hostenv-system endpoint prepare /nonexistent-manifest.json >out.log 2>&1; then
                echo "Endpoint runtime unexpectedly accepted missing manifest" >&2
                exit 1
              fi
              grep -q "Cannot export endpoint" out.log

              write_manifest() {
                cat > manifest.json <<EOF
              {"owner":"$1","name":"$2","runtime_dir":"$3","socket":"$4","descriptor":"$5","port":$6,"systemctl":"$7","nsenter":"/bin/true","setpriv":"/bin/true","proxy":"/bin/true"}
              EOF
              }

              expect_rejected() {
                if hostenv-system endpoint prepare manifest.json >out.log 2>&1; then
                  echo "Endpoint runtime unexpectedly accepted a manifest: $1" >&2
                  exit 1
                fi
                if ! grep -Fq 'invalid endpoint manifest:' out.log ||
                   ! grep -Fq "$1" out.log; then
                  cat out.log >&2
                  exit 1
                fi
              }

              mkdir -m 0700 "$TMPDIR/runtime"
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 3001 /bin/true
              hostenv-system endpoint prepare manifest.json
              test -d "$TMPDIR/runtime/fixture"
              test ! -e "$TMPDIR/runtime/fixture/api.sock"

              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime" hostenv-api 3001 /bin/true
              expect_rejected "the export must be inside the environment's runtime directory"
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime-other/fixture/api.sock" hostenv-api 3001 /bin/true
              expect_rejected "the export must be inside the environment's runtime directory"
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime/../escape.sock" hostenv-api 3001 /bin/true
              expect_rejected "socket and runtime paths must be absolute, normalised and contain safe components"
              long_segment=$(printf '%0108d' 0 | tr 0 a)
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime/$long_segment.sock" hostenv-api 3001 /bin/true
              expect_rejected "the Unix socket path must be at most 107 bytes"

              write_manifest 'fixture@.service' api "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 3001 /bin/true
              expect_rejected "invalid owning unit name"
              write_manifest fixture.service 'bad/name' "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 3001 /bin/true
              expect_rejected "invalid endpoint name"
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" 'bad descriptor' 3001 /bin/true
              expect_rejected "invalid activation descriptor name"
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 0 /bin/true
              expect_rejected "the private TCP port must be between 1 and 65535"
              write_manifest fixture.service api "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 3001 relative-systemctl
              expect_rejected "helper executable paths must be absolute"

              touch "$out"
            '';
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

            endpoints-vm-test = import ../../tests/integration/endpoints/vm-test.nix {
              inherit pkgs makeHostenv;
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
