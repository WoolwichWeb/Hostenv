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
            private-network-contracts = import ../../tests/integration/private-network/contracts.nix {
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
              {"owner":"$1","runtime_dir":"$2","socket":"$3","descriptor":"$4","port":$5}
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
              write_manifest fixture.service "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 3001
              hostenv-system endpoint prepare manifest.json
              test -d "$TMPDIR/runtime/fixture"
              test ! -e "$TMPDIR/runtime/fixture/api.sock"
              mkdir -m 0700 "$TMPDIR/_runtime"
              write_manifest fixture.service "$TMPDIR/_runtime" "$TMPDIR/_runtime/fixture/api.sock" hostenv-api 3001
              hostenv-system endpoint prepare manifest.json
              test -d "$TMPDIR/_runtime/fixture"

              # The preflight must refuse occupied paths, including dangling symlinks.
              write_manifest fixture.service "$TMPDIR/runtime" "$TMPDIR/runtime/fixture/api.sock" hostenv-api 3001
              expect_occupied() {
                if hostenv-system endpoint prepare manifest.json >out.log 2>&1; then
                  echo "Endpoint runtime accepted an occupied socket path" >&2
                  exit 1
                fi
                grep -Fq 'refusing to replace existing object' out.log || {
                  cat out.log >&2
                  exit 1
                }
              }
              printf 'preserved' > "$TMPDIR/runtime/fixture/api.sock"
              expect_occupied
              test "$(cat "$TMPDIR/runtime/fixture/api.sock")" = preserved
              rm "$TMPDIR/runtime/fixture/api.sock"
              ln -s "$TMPDIR/missing" "$TMPDIR/runtime/fixture/api.sock"
              expect_occupied
              test -L "$TMPDIR/runtime/fixture/api.sock"
              rm "$TMPDIR/runtime/fixture/api.sock"

              # A symlinked parent must not redirect preparation elsewhere.
              rmdir "$TMPDIR/runtime/fixture"
              mkdir -m 0700 "$TMPDIR/elsewhere"
              ln -s "$TMPDIR/elsewhere" "$TMPDIR/runtime/fixture"
              if hostenv-system endpoint prepare manifest.json >out.log 2>&1; then
                echo "Endpoint runtime followed a symlinked parent" >&2
                exit 1
              fi
              test ! -e "$TMPDIR/elsewhere/api.sock"
              rm "$TMPDIR/runtime/fixture"

              write_manifest fixture.service "$TMPDIR/runtime" "$TMPDIR/runtime" hostenv-api 3001
              expect_rejected "the export must be inside the environment's runtime directory"
              write_manifest fixture.service "$TMPDIR/runtime" "$TMPDIR/runtime-other/fixture/api.sock" hostenv-api 3001
              expect_rejected "the export must be inside the environment's runtime directory"
              write_manifest fixture.service "$TMPDIR/runtime" "$TMPDIR/runtime/../escape.sock" hostenv-api 3001
              expect_rejected "socket and runtime paths must be absolute, normalised and contain no NUL bytes"
              long_segment=$(printf '%0108d' 0 | tr 0 a)
              write_manifest fixture.service "$TMPDIR/runtime" "$TMPDIR/runtime/$long_segment.sock" hostenv-api 3001
              expect_rejected "the Unix socket path must be at most 107 bytes"

              # Aeson remains responsible for decoding manifest field types.
              sed 's/"port":3001/"port":"not-a-port"/' manifest.json > invalid.json
              if hostenv-system endpoint prepare invalid.json >out.log 2>&1; then
                echo "Endpoint runtime accepted a malformed manifest" >&2
                exit 1
              fi
              grep -Fq 'invalid endpoint manifest:' out.log

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
