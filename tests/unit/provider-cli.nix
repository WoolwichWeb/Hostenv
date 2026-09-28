{ pkgs, documentationEnabled }:
let
  src = ../../provider;
  providerCliPackage = pkgs.callPackage ../../provider/package.nix {
    providerSrc = src;
    inherit documentationEnabled;
  };
  cliPkg = providerCliPackage.unwrapped;
  ghc =
    (pkgs.haskellPackages.ghcWithPackages.override {
      installDocumentation = documentationEnabled;
    })
      (p: [
        p.aeson
        p.containers
        p.process
        p.scientific
        p.text
      ]);
  providerCliDnsObservationCache = pkgs.runCommand "provider-cli-dns-observation-cache" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDnsObservationCache.hs
    echo ok > "$out"
  '';
  providerCliTlsReadiness = pkgs.runCommand "provider-cli-tls-readiness" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestTlsReadiness.hs
    echo ok > "$out"
  '';
  providerCliDnsTransition = pkgs.runCommand "provider-cli-dns-transition" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDnsTransition.hs
    echo ok > "$out"
  '';
in
{
  provider-cli-typecheck = cliPkg;
  provider-cli-signing-targets = pkgs.runCommand "provider-cli-signing-targets" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestSigningTargets.hs
    echo ok > "$out"
  '';
  provider-cli-dns-observation-cache = providerCliDnsObservationCache;
  provider-cli-dns-transition = providerCliDnsTransition;
  provider-cli-tls-readiness = providerCliTlsReadiness;
  provider-cli-dry-run-help = pkgs.runCommand "provider-cli-dry-run-help" { nativeBuildInputs = providerCliPackage.runtimeInputs; } ''
    set -euo pipefail
    for subcmd in plan deploy; do
      help_output="$(${cliPkg}/bin/hostenv-provider "$subcmd" --help)"
      ${pkgs.gnugrep}/bin/grep -q -- "--dry-run" <<<"$help_output"
    done
    echo ok > "$out"
  '';

  provider-cli-cleanup-only-system-targets = pkgs.runCommand "provider-cli-cleanup-only-system-targets" { nativeBuildInputs = providerCliPackage.runtimeInputs; } ''
    set -euo pipefail

    work="$TMPDIR/provider"
    fakeBin="$TMPDIR/bin"
    log="$TMPDIR/nix.log"
    sshLog="$TMPDIR/ssh.log"
    mkdir -p "$work/generated" "$fakeBin"

    cat > "$work/generated/plan.json" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "nodes": {
        "old-node": {},
        "new-node": {},
        "retired-node": {}
      },
      "environments": {
        "acme-prod": {
          "hostenv": {
            "userName": "acme-prod",
            "runtimeDir": "/run/hostenv/user/acme-prod",
            "hostname": "acme-prod.hosting.test"
          },
          "uid": 2000,
          "node": "new-node",
          "virtualHosts": {}
        }
      }
    }
    EOF
    printf '{}\n' > "$work/generated/flake.nix"

    cat > "$work/generated/state.json" <<'EOF'
    {
      "acme-prod": {
        "userName": "acme-prod",
        "uid": 2000,
        "virtualHosts": []
      },
      "retired-prod": {
        "userName": "retired-prod",
        "uid": 2001,
        "virtualHosts": []
      },
      "orphan-prod": {
        "userName": "orphan-prod",
        "uid": 2002,
        "virtualHosts": []
      }
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$NIX_LOG"
    if [ "''${FAIL_RETIRED_SYSTEM:-0}" = 1 ] \
      && printf '%s\n' "$*" | grep -Fq '#"retired-node"."system"'; then
      exit 42
    fi
    exit 0
    EOF
    chmod +x "$fakeBin/nix"

    cat > "$fakeBin/ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    script="$(cat)"
    target="$*"
    if [ -n "''${SSH_LOG:-}" ]; then
      {
        printf 'target=%s\n' "$target"
        printf '%s\n' "$script"
      } >> "$SSH_LOG"
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "/etc/os-release"; then
      printf 'ID=nixos\n'
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "# HOSTENV_RUNTIME_PROBE"; then
      case "$target" in
        *retired-node.hosting.test*)
          if [ "''${ORPHAN_RUNTIME:-0}" = 1 ]; then
            printf 'orphan-prod\n'
          fi
          ;;
      esac
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "'getent' 'passwd'"; then
      case "$target" in
        *old-node.hosting.test*)
          if [ "''${UID_DRIFT:-0}" = 1 ]; then
            printf 'acme-prod:x:2999:100::/home/acme-prod:/bin/sh\n'
          else
            printf 'acme-prod:x:2000:100::/home/acme-prod:/bin/sh\n'
          fi
          ;;
        *retired-node.hosting.test*)
          printf 'retired-prod:x:2001:100::/home/retired-prod:/bin/sh\n'
          ;;
      esac
      exit 0
    fi

    # Cleanup commands are intentionally not executed by this unit test. Their
    # presence and ordering is exercised through the CLI's SSH boundary.
    exit 0
    EOF
    chmod +x "$fakeBin/ssh"

    (
      cd "$work"

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run

      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"retired-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."acme-prod"' "$log"
      test "$(wc -l < "$log")" -eq 4

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node old-node

      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$log"
      test "$(wc -l < "$log")" -eq 1

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node retired-node

      ${pkgs.gnugrep}/bin/grep -Fq '#"retired-node"."system"' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'new-node' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod' "$log"
      test "$(wc -l < "$log")" -eq 1

      : > "$log"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" FAIL_RETIRED_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node retired-node; then
        echo "cleanup-only system deployment failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq '#"retired-node"."system"' "$log"
      test "$(wc -l < "$log")" -eq 1

      # A Hostenv runtime can outlive its passwd entry. The reserved identity
      # must still be cleaned from linger, user@UID, and /run/user/UID.
      : > "$log"
      : > "$sshLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" SSH_LOG="$sshLog" ORPHAN_RUNTIME=1 \
        ${cliPkg}/bin/hostenv-provider deploy --node retired-node --remote-build --skip-verification
      ${pkgs.gnugrep}/bin/grep -Fq "/var/lib/systemd/linger/orphan-prod" "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq "user@2002.service" "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq "/run/user/2002" "$sshLog"

      # Real deploys observe node passwd state, but state.json itself is an
      # input/reservation file and must remain byte-for-byte unchanged.
      cp generated/state.json "$TMPDIR/state-before.json"
      : > "$log"
      : > "$sshLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" SSH_LOG="$sshLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification

      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json
      ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger 'acme-prod'" "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq "user@2000.service" "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger 'retired-prod'" "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq "user@2001.service" "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"retired-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$log"

      # Stable Hostenv UIDs are global identity. Drift must abort before any
      # system or environment deployment can make the situation worse.
      : > "$log"
      : > "$sshLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" SSH_LOG="$sshLog" UID_DRIFT=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "UID drift was reported as success"
        exit 1
      fi
      test ! -s "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger" "$sshLog"

      # A malformed environment entry must abort before reconciliation can
      # misclassify its live account as retired.
      cp generated/plan.json "$TMPDIR/valid-plan.json"
      ${pkgs.jq}/bin/jq 'del(.environments["acme-prod"].hostenv.hostname)'         generated/plan.json > "$TMPDIR/malformed-plan.json"
      mv "$TMPDIR/malformed-plan.json" generated/plan.json
      : > "$log"
      : > "$sshLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" SSH_LOG="$sshLog"         ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "malformed environment plan was reported as success"
        exit 1
      fi
      test ! -s "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger" "$sshLog"
      mv "$TMPDIR/valid-plan.json" generated/plan.json

      cp generated/plan.json "$TMPDIR/valid-plan.json"
      ${pkgs.jq}/bin/jq '.environments["acme-prod"].deploymentVerification = {"enable":"not-a-bool"}' \
        generated/plan.json > "$TMPDIR/malformed-plan.json"
      mv "$TMPDIR/malformed-plan.json" generated/plan.json
      : > "$log"
      : > "$sshLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" SSH_LOG="$sshLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build; then
        echo "invalid deployment verification was reported as success"
        exit 1
      fi
      test ! -s "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger" "$sshLog"
      mv "$TMPDIR/valid-plan.json" generated/plan.json

      # A source-only deployment can observe that this is a moved environment,
      # but cannot prove the destination participates in the same transaction.
      # It must fail before deploy-rs can remove the source account.
      : > "$log"
      : > "$sshLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" SSH_LOG="$sshLog" \
        ${cliPkg}/bin/hostenv-provider deploy --node old-node --remote-build --skip-verification; then
        echo "node-filtered moved-source deployment was reported as success"
        exit 1
      fi
      test ! -s "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger" "$sshLog"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json
    )

    echo ok > "$out"
  '';

  provider-cli-move-finalization-order = pkgs.runCommand "provider-cli-move-finalization-order" { nativeBuildInputs = providerCliPackage.runtimeInputs; } ''
    set -euo pipefail

    work="$TMPDIR/provider"
    fakeBin="$TMPDIR/bin"
    nixLog="$TMPDIR/nix.log"
    sshLog="$TMPDIR/ssh.log"
    eventLog="$TMPDIR/events.log"
    mkdir -p "$work/generated" "$fakeBin"

    cat > "$work/generated/plan.json" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "nodes": {
        "old-node": {},
        "new-node": {
          "services": {
            "nginx": {
              "virtualHosts": {
                "acme-prod.hosting.test": {
                  "enableACME": true,
                  "forceSSL": true
                }
              }
            }
          }
        }
      },
      "environments": {
        "acme-prod": {
          "hostenv": {
            "userName": "acme-prod",
            "runtimeDir": "/run/hostenv/user/acme-prod",
            "hostname": "acme-prod.hosting.test"
          },
          "uid": 2000,
          "node": "new-node",
          "migrations": [ "demo-migrate" ],
          "deploymentVerification": {
            "enable": true,
            "enforce": true,
            "checks": [
              {
                "name": "destination-health",
                "request": {
                  "virtualHost": "acme-prod.example.test",
                  "timeoutSeconds": 1
                },
                "constraints": [
                  {
                    "rule": "stdoutRegexMustMatch",
                    "value": "healthy"
                  }
                ]
              }
            ]
          },
          "virtualHosts": {
            "acme-prod.hosting.test": {
              "enableLetsEncrypt": true,
              "forceSSL": true
            }
          }
        }
      }
    }
    EOF
    printf '{}\n' > "$work/generated/flake.nix"

    cat > "$work/generated/state.json" <<'EOF'
    {
      "acme-prod": {
        "userName": "acme-prod",
        "uid": 2000,
        "virtualHosts": []
      }
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    printf '%s\n' "$*" >> "$NIX_LOG"
    printf 'NIX %s\n' "$*" >> "$EVENT_LOG"

    if [ "''${FAIL_DEST_ENV:-0}" = 1 ] \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"'; then
      exit 41
    fi

    if [ "''${FAIL_SOURCE_SYSTEM:-0}" = 1 ] \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"'; then
      exit 42
    fi

    if [ "''${FAIL_DEST_SYSTEM:-0}" = 1 ] \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"'; then
      exit 48
    fi

    exit 0
    EOF
    chmod +x "$fakeBin/nix"

    cat > "$fakeBin/ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    script="$(cat)"
    target="$*"

    printf 'target=%s\n%s\n' "$target" "$script" >> "$SSH_LOG"

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "/etc/os-release"; then
      printf 'ID=nixos\n'
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "# HOSTENV_RUNTIME_PROBE"; then
      case "$target" in
        *old-node.hosting.test*)
          if [ "''${ORPHAN_SOURCE:-0}" = 1 ]; then
            printf 'acme-prod\n'
          fi
          ;;
      esac
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "# HOSTENV_USER_MANAGER_PROBE"; then
      case "$script" in
        *acme-stage*) probe_user="acme-stage" ;;
        *) probe_user="acme-prod" ;;
      esac
      if [ -f "$SOURCE_STATE_DIR/$probe_user-quiesced" ]; then
        printf 'quiesced\n'
      else
        printf 'active\n'
      fi
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "/var/lib/hostenv/provider/migration-handoffs/"; then
      case "$script" in
        *"/migration-handoffs/2001"*) handoff_user="acme-stage" ;;
        *) handoff_user="acme-prod" ;;
      esac
      case "$target" in
        *new-node.hosting.test*) handoff_file="$HANDOFF_DIR/new-node-$handoff_user" ;;
        *old-node.hosting.test*) handoff_file="$HANDOFF_DIR/old-node-$handoff_user" ;;
        *) handoff_file="$HANDOFF_DIR/unknown-$handoff_user" ;;
      esac
      if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "sudo cat"; then
        [ -f "$handoff_file" ] && cat "$handoff_file"
      elif printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "sudo tee"; then
        case "$script" in
          *"accepted old-node"*) handoff_phase="accepted" ;;
          *"quiesced old-node"*) handoff_phase="quiesced" ;;
          *) echo "unexpected handoff payload" >&2; exit 44 ;;
        esac
        if [ "$handoff_phase" = quiesced ] && [ "''${FAIL_QUIESCED_MARKER:-0}" = 1 ]; then
          printf 'HANDOFF_QUIESCED_WRITE_FAIL %s\n' "$handoff_user" >> "$EVENT_LOG"
          exit 45
        fi
        printf '%s old-node\n' "$handoff_phase" > "$handoff_file"
        case "$handoff_phase" in
          accepted) printf 'HANDOFF_ACCEPTED %s\n' "$handoff_user" >> "$EVENT_LOG" ;;
          quiesced) printf 'HANDOFF_QUIESCED %s\n' "$handoff_user" >> "$EVENT_LOG" ;;
        esac
      elif printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "sudo rm -f"; then
        if [ "''${FAIL_DEST_HANDOFF_CLEAR:-0}" = 1 ] \
          && printf '%s\n' "$target" | ${pkgs.gnugrep}/bin/grep -Fq 'new-node.hosting.test'; then
          printf 'HANDOFF_CLEAR_FAIL %s\n' "$handoff_user" >> "$EVENT_LOG"
          exit 47
        fi
        rm -f "$handoff_file"
        printf 'HANDOFF_CLEARED %s\n' "$handoff_user" >> "$EVENT_LOG"
      fi
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "'getent' 'passwd'"; then
      case "$target" in
        *old-node.hosting.test*)
          if [ "''${ORPHAN_SOURCE:-0}" != 1 ] && [ "''${SOURCE_REMOVED:-0}" != 1 ]; then
            printf 'acme-prod:x:2000:100::/home/acme-prod:/bin/sh\n'
            if [ "''${MULTI_MOVE:-0}" = 1 ]; then
              printf 'acme-stage:x:2001:100::/home/acme-stage:/bin/sh\n'
            fi
          fi
          ;;
      esac
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "systemctl --user show -p LoadState"; then
      printf 'LoadState=loaded\n'
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "snapshots --latest 1"; then
      printf '[{"id":"0123456789abcdef"}]\n'
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "loginctl disable-linger"; then
      case "$script" in
        *acme-stage*) cleanup_user="acme-stage" ;;
        *) cleanup_user="acme-prod" ;;
      esac
      if [ "''${SYSTEMCTL_QUERY_FAIL:-0}" = 1 ]; then
        printf 'CLEANUP_QUERY_FAIL %s\n' "$cleanup_user" >> "$EVENT_LOG"
        exit 5
      fi
      if [ "''${FAIL_CLEANUP_AFTER_QUIESCE:-0}" = 1 ]; then
        touch "$SOURCE_STATE_DIR/$cleanup_user-quiesced"
        printf 'CLEANUP_QUIESCED_FAIL %s\n' "$cleanup_user" >> "$EVENT_LOG"
        exit 43
      fi
      if [ "''${FAIL_CLEANUP:-0}" = 1 ] || { [ "$cleanup_user" = "acme-stage" ] && [ "''${FAIL_CLEANUP_STAGE:-0}" = 1 ]; }; then
        printf 'CLEANUP_FAIL %s\n' "$cleanup_user" >> "$EVENT_LOG"
        exit 43
      fi
      touch "$SOURCE_STATE_DIR/$cleanup_user-quiesced"
      printf 'CLEANUP %s\n' "$cleanup_user" >> "$EVENT_LOG"
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "loginctl enable-linger"; then
      printf 'ROLLBACK acme-prod\n' >> "$EVENT_LOG"
      exit 0
    fi

    exit 0
    EOF
    chmod +x "$fakeBin/ssh"

    cat > "$fakeBin/dig" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    args=" $* "

    if [ "''${DNS_NS_FAIL:-0}" = 1 ]       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' NS '; then
      printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
      exit 0
    fi

    if [ "''${DNS_OBSERVATION_FAIL:-0}" = 1 ]       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq '@ns1.hosting.test'       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME '       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod.hosting.test'       && { [ -z "''${DNS_STATE_DIR:-}" ] || [ ! -f "$DNS_STATE_DIR/acme-prod-new" ]; }; then
      printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
      exit 0
    fi

    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'

    if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' hosting.test NS '; then
      if [ "''${DNS_SPLIT_AUTH:-0}" = 1 ] || [ "''${DNS_SPLIT_ADDR:-0}" = 1 ]; then
        printf 'hosting.test. 60 IN NS ns1.hosting.test.\nhosting.test. 60 IN NS ns2.hosting.test.\n'
      else
        printf 'hosting.test. 60 IN NS ns1.hosting.test.\n'
      fi
      exit 0
    fi

    if [ "''${DNS_SPLIT_AUTH:-0}" = 1 ]; then
      if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME ' \
        && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod.hosting.test'; then
        if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq '@ns1.hosting.test'; then
          printf 'acme-prod.hosting.test. 60 IN CNAME old-node.hosting.test.\n'
        else
          printf 'acme-prod.hosting.test. 60 IN CNAME new-node.hosting.test.\n'
        fi
        exit 0
      fi
    fi

    if [ "''${DNS_SPLIT_ADDR:-0}" = 1 ]; then
      if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME ' \
        && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod.hosting.test'; then
        exit 0
      fi
      if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' A ' \
        && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'new-node.hosting.test'; then
        printf 'new-node.hosting.test. 60 IN A 192.0.2.20\n'
        exit 0
      fi
      if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' A ' \
        && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod.hosting.test'; then
        if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq '@ns1.hosting.test'; then
          printf 'acme-prod.hosting.test. 60 IN A 192.0.2.10\n'
        else
          printf 'acme-prod.hosting.test. 60 IN A 192.0.2.20\n'
        fi
        exit 0
      fi
      if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' AAAA '; then
        exit 0
      fi
    fi

    if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME ' \
      && { printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod.hosting.test' \
        || printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'acme-stage.hosting.test'; }; then
      case "$args" in
        *acme-stage.hosting.test*) dns_user="acme-stage" ;;
        *) dns_user="acme-prod" ;;
      esac
      if [ "''${DNS_OLD:-0}" = 1 ]; then
        printf '%s.hosting.test. 60 IN CNAME old-node.hosting.test.\n' "$dns_user"
        printf 'DNS_OLD %s\n' "$dns_user" >> "$EVENT_LOG"
      elif [ "''${DNS_AUTOMATIC:-0}" = 1 ] && [ ! -f "$DNS_STATE_DIR/$dns_user-new" ]; then
        printf '%s.hosting.test. 60 IN CNAME old-node.hosting.test.\n' "$dns_user"
        printf 'DNS_OLD %s\n' "$dns_user" >> "$EVENT_LOG"
      else
        printf '%s.hosting.test. 60 IN CNAME new-node.hosting.test.\n' "$dns_user"
        printf 'DNS_NEW %s\n' "$dns_user" >> "$EVENT_LOG"
      fi
    fi
    EOF
    chmod +x "$fakeBin/dig"

    cat > "$fakeBin/curl" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    args=" $* "
    if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'api.cloudflare.com'; then
      case "$args" in
        *"/zones/zone/dns_records?per_page=1000&name="*)
          printf '{"success":true,"result":[{"id":"old-record","type":"CNAME","name":"acme-prod.hosting.test","content":"old-node.hosting.test","proxied":false}]}\n'
          ;;
        *"-X PUT "*"dns_records/old-record"*)
          touch "$DNS_STATE_DIR/acme-prod-new"
          printf 'DNS_UPSERT acme-prod\n' >> "$EVENT_LOG"
          printf '{"success":true,"errors":[]}\n'
          ;;
        *"/zones/zone"*)
          printf '{"success":true,"result":{"name":"hosting.test"}}\n'
          ;;
        *)
          echo "unexpected Cloudflare curl invocation: $args" >&2
          exit 46
          ;;
      esac
      exit 0
    fi

    if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq -- '--head' \
      && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'https://acme-prod.hosting.test/'; then
      printf 'HTTPS_READY acme-prod\n' >> "$EVENT_LOG"
      exit 0
    fi

    if [ "''${VERIFY_FAIL:-0}" = 1 ]; then
      body="broken"
    else
      body="healthy"
    fi
    printf '%s\n__HOSTENV_PROVIDER_HTTP_STATUS__:200\n__HOSTENV_PROVIDER_EFFECTIVE_URL__:http://acme-prod.example.test/\n' "$body"
    EOF
    chmod +x "$fakeBin/curl"

    (
      cd "$work"
      export HANDOFF_DIR="$TMPDIR/handoff"
      export SOURCE_STATE_DIR="$TMPDIR/source-state"
      export DNS_STATE_DIR="$TMPDIR/dns-state"
      mkdir -p "$HANDOFF_DIR" "$SOURCE_STATE_DIR" "$DNS_STATE_DIR"
      cp generated/state.json "$TMPDIR/state-before.json"
      cp generated/plan.json "$TMPDIR/canonical-plan.json"

      # Pointing --migration-source at the destination must not suppress a
      # real observed source. --skip-migrations is the explicit no-migrate path.
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog"         ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification           --migration-source acme-prod=new-node; then
        echo "destination migration-source override suppressed an observed source"
        exit 1
      fi
      test ! -s "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"

      # A destination-only filtered deploy must not activate the destination
      # while silently leaving its discovered migration source live.
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --node new-node --remote-build --skip-verification; then
        echo "destination-only filtered migration was reported as success"
        exit 1
      fi
      test ! -s "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"

      # The same guard applies to a move with no backup hooks. Moving between
      # nodes is a lifecycle transaction even when there is no data snapshot.
      ${pkgs.jq}/bin/jq '.environments["acme-prod"].migrations = []' generated/plan.json > "$TMPDIR/no-backup-plan.json"
      mv "$TMPDIR/no-backup-plan.json" generated/plan.json
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --node new-node --remote-build --skip-verification; then
        echo "destination-only filtered move without backup hooks was reported as success"
        exit 1
      fi
      test ! -s "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      cp "$TMPDIR/canonical-plan.json" generated/plan.json

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_DEST_ENV=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "destination environment failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json

      # Activation alone is not enough to retire the source when verification
      # is enforced. A failed destination health check must leave the source
      # account and source system untouched.
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" VERIFY_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build; then
        echo "enforced destination verification failure was reported as success"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification --skip-migrations acme-prod

      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"

      # A completed marker from an older lifecycle cannot suppress a real live
      # source. It must be discarded and a fresh backup attempted.
      printf 'quiesced old-node\n' > "$HANDOFF_DIR/new-node-acme-prod"
      rm -f "$SOURCE_STATE_DIR/acme-prod-quiesced"
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_DEST_ENV=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "stale completed handoff suppressed a fresh migration"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      test ! -f "$HANDOFF_DIR/new-node-acme-prod"

      # An indeterminate systemd query must fail cleanup closed. Acceptance is
      # durable, but the source is not marked quiesced and its system is not
      # deployed.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" SYSTEMCTL_QUERY_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "systemctl query failure was reported as successful cleanup"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP_QUERY_FAIL acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'failed to inspect user@2000.service' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'failed to verify user@2000.service after cleanup' "$sshLog"

      # If promotion to quiesced fails after source cleanup, the atomic marker
      # writer must leave the earlier accepted state intact for recovery.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_QUIESCED_MARKER=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "quiesced marker write failure was reported as success"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED_WRITE_FAIL acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -qx 'accepted old-node' "$HANDOFF_DIR/new-node-acme-prod"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_SOURCE_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "retry after quiesced marker write failure was reported as success"
        exit 1
      fi
      ! ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"

      # Migration finalization waits for every authoritative nameserver. If
      # one still serves the source while another serves the destination, the
      # source system must not be removed.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/* "$DNS_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      set +e
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" DNS_SPLIT_AUTH=1 \
        ${pkgs.coreutils}/bin/timeout 3 ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification
      split_status=$?
      set -e
      test "$split_status" -eq 124
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      # The same rule applies when the vhost uses direct A/AAAA records
      # instead of a CNAME. A union of split authoritative answers is not enough
      # to prove that traffic has left the source.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/* "$DNS_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      set +e
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" DNS_SPLIT_ADDR=1 \
        ${pkgs.coreutils}/bin/timeout 3 ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification
      split_addr_status=$?
      set -e
      test "$split_addr_status" -eq 124
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      # Failure to discover authoritative nameservers is indeterminate, not a
      # reason to fall back to the recursive resolver. The source stays
      # quiesced and its system account is not removed.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/* "$DNS_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" DNS_STATE_DIR="$DNS_STATE_DIR" DNS_NS_FAIL=1 CF_API_TOKEN=test-token CF_ZONE_ID=zone         ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification > "$TMPDIR/ns-fail.out" 2>&1; then
        echo "migration finalized despite failed authoritative nameserver discovery"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'authoritative nameserver discovery' "$TMPDIR/ns-fail.out"
      ${pkgs.gnugrep}/bin/grep -Fq 'DNS server returned SERVFAIL' "$TMPDIR/ns-fail.out"

      # DNS is part of migration finalization. If automatic updates are
      # unavailable, a moved source is quiesced but its account is not removed
      # until DNS is changed and deploy is rerun.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/* "$DNS_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" DNS_OLD=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "migration finalized before DNS cutover"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'DNS_OLD acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_SOURCE_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "manual DNS cutover retry was reported as success"
        exit 1
      fi
      ! ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'DNS_NEW acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      # A destination system failure is a real deployment failure. Hostenv
      # must not guess that ACME caused it or retry with a weaker configuration.
      cp "$TMPDIR/canonical-plan.json" generated/plan.json
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/* "$DNS_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_DEST_SYSTEM=1 DNS_AUTOMATIC=1 CF_API_TOKEN=test-token CF_ZONE_ID=zone \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "destination system failure was reported as success"
        exit 1
      fi
      test "$(${pkgs.gnugrep}/bin/grep -Fc '#"new-node"."system"' "$nixLog")" -eq 1
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'DNS_UPSERT acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/canonical-plan.json" generated/plan.json

      # If cleanup mutates the source and then reports failure, the accepted
      # marker plus a live source probe makes the interruption recoverable.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_CLEANUP_AFTER_QUIESCE=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "cleanup-after-quiesce failure was reported as success"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP_QUIESCED_FAIL acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_SOURCE_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "quiesced-source retry was reported as success"
        exit 1
      fi
      ! ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"

      # A cleanup failure that leaves the source live records only acceptance.
      # The next retry must take a fresh source backup before trying cleanup again.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_CLEANUP=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "source cleanup failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP_FAIL acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"

      # On retry the accepted marker does not suppress a fresh backup while the
      # source is still live. Successful cleanup promotes it to quiesced before
      # source-system removal is attempted.
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      cp "$TMPDIR/canonical-plan.json" generated/plan.json
      rm -f "$DNS_STATE_DIR"/*
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_SOURCE_SYSTEM=1 DNS_AUTOMATIC=1 CF_API_TOKEN=test-token CF_ZONE_ID=zone \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "source system failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'ROLLBACK acme-prod' "$eventLog"
      dest_system_line="$(${pkgs.gnugrep}/bin/grep -n -F '#"new-node"."system"' "$eventLog" | head -n1 | cut -d: -f1)"
      dest_env_line="$(${pkgs.gnugrep}/bin/grep -n -F '#"new-node"."acme-prod"' "$eventLog" | head -n1 | cut -d: -f1)"
      accepted_line="$(${pkgs.gnugrep}/bin/grep -n -F 'HANDOFF_ACCEPTED acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      cleanup_line="$(${pkgs.gnugrep}/bin/grep -n -F 'CLEANUP acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      quiesced_line="$(${pkgs.gnugrep}/bin/grep -n -F 'HANDOFF_QUIESCED acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      dns_line="$(${pkgs.gnugrep}/bin/grep -n -F 'DNS_UPSERT acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      https_ready_line="$(${pkgs.gnugrep}/bin/grep -n -F 'HTTPS_READY acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      source_system_line="$(${pkgs.gnugrep}/bin/grep -n -F '#"old-node"."system"' "$eventLog" | head -n1 | cut -d: -f1)"
      test "$dest_system_line" -lt "$dest_env_line"
      test "$dest_env_line" -lt "$accepted_line"
      test "$accepted_line" -lt "$cleanup_line"
      test "$cleanup_line" -lt "$quiesced_line"
      test "$quiesced_line" -lt "$dns_line"
      test "$dns_line" -lt "$https_ready_line"
      test "$https_ready_line" -lt "$source_system_line"
      test "$(${pkgs.gnugrep}/bin/grep -Fc '#"new-node"."system"' "$eventLog")" -eq 1
      ${pkgs.jq}/bin/jq -e '
        .environments["acme-prod"].virtualHosts["acme-prod.hosting.test"].enableLetsEncrypt == true
        and .environments["acme-prod"].virtualHosts["acme-prod.hosting.test"].forceSSL == true
        and .nodes["new-node"].services.nginx.virtualHosts["acme-prod.hosting.test"].enableACME == true
        and .nodes["new-node"].services.nginx.virtualHosts["acme-prod.hosting.test"].forceSSL == true
      ' generated/plan.json >/dev/null
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/canonical-plan.json" generated/plan.json
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json

      # If the source system succeeds but clearing the destination handoff
      # fails, the next deploy can see that the old account and runtime are
      # already gone and remove the stale marker.
      rm -f "$HANDOFF_DIR"/* "$SOURCE_STATE_DIR"/* "$DNS_STATE_DIR"/*
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_DEST_HANDOFF_CLEAR=1 DNS_AUTOMATIC=1 CF_API_TOKEN=test-token CF_ZONE_ID=zone \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "destination handoff clear failure was reported as success"
        exit 1
      fi
      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_CLEAR_FAIL acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -qx 'quiesced old-node' "$HANDOFF_DIR/new-node-acme-prod"

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" SOURCE_REMOVED=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_CLEARED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      source_system_line="$(${pkgs.gnugrep}/bin/grep -n -F '#"old-node"."system"' "$eventLog" | head -n1 | cut -d: -f1)"
      handoff_clear_line="$(${pkgs.gnugrep}/bin/grep -n -F 'HANDOFF_CLEARED acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      test "$source_system_line" -lt "$handoff_clear_line"
      test ! -f "$HANDOFF_DIR/new-node-acme-prod"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"

      # A matching accepted handoff is also sufficient to resume finalization
      # when the source passwd entry has disappeared but runtime survives. There
      # is no source account left from which another migration backup could run.
      rm -f "$SOURCE_STATE_DIR/acme-prod-quiesced"
      printf 'accepted old-node\n' > "$HANDOFF_DIR/new-node-acme-prod"
      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" ORPHAN_SOURCE=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification
      ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'snapshots --latest 1' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'ROLLBACK acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq '/var/lib/systemd/linger/acme-prod' "$sshLog"
      ${pkgs.gnugrep}/bin/grep -Fq '/run/user/2000' "$sshLog"

      # When multiple moved users share a source node, one cleanup failure must
      # not hide successful quiescing of another moved user. The successful
      # user needs its handoff marker before the node-level failure is returned,
      # otherwise the next deploy would try to back it up from a stopped manager.
      rm -f "$HANDOFF_DIR"/*
      ${pkgs.jq}/bin/jq '
        .environments["acme-stage"] = {
          "hostenv": {
            "userName": "acme-stage",
            "runtimeDir": "/run/hostenv/user/acme-stage",
            "hostname": "acme-stage.hosting.test"
          },
          "uid": 2001,
          "node": "new-node",
          "migrations": [ "demo-migrate" ],
          "virtualHosts": {
            "acme-stage.hosting.test": {}
          }
        }
      ' generated/plan.json > "$TMPDIR/multi-plan.json"
      mv "$TMPDIR/multi-plan.json" generated/plan.json
      ${pkgs.jq}/bin/jq '
        .["acme-stage"] = {
          "userName": "acme-stage",
          "uid": 2001,
          "virtualHosts": []
        }
      ' generated/state.json > "$TMPDIR/multi-state.json"
      mv "$TMPDIR/multi-state.json" generated/state.json

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" MULTI_MOVE=1 FAIL_CLEANUP_STAGE=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "partial multi-user source cleanup failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-prod"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."acme-stage"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP_FAIL acme-stage' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_ACCEPTED acme-stage' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-prod' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'HANDOFF_QUIESCED acme-stage' "$eventLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq '#"old-node"."system"' "$nixLog"
    )

    echo ok > "$out"
  '';

  provider-cli-new-environment-deploy = pkgs.runCommand "provider-cli-new-environment-deploy" { nativeBuildInputs = providerCliPackage.runtimeInputs; } ''
    set -euo pipefail

    work="$TMPDIR/provider"
    fakeBin="$TMPDIR/bin"
    log="$TMPDIR/nix.log"
    digLog="$TMPDIR/dig.log"
    mkdir -p "$work/generated" "$fakeBin"

    cat > "$work/generated/plan.json" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "nodes": {
        "new-node": {
          "services": {
            "nginx": {
              "virtualHosts": {
                "fresh-prod.hosting.test": {
                  "enableACME": true,
                  "forceSSL": true
                },
                "www-fresh-prod.hosting.test": {
                  "enableACME": true,
                  "forceSSL": true
                }
              }
            }
          }
        }
      },
      "environments": {
        "fresh-prod": {
          "hostenv": {
            "userName": "fresh-prod",
            "runtimeDir": "/run/hostenv/user/fresh-prod",
            "hostname": "fresh-prod.hosting.test"
          },
          "uid": 3000,
          "node": "new-node",
          "migrations": [ "demo-migrate" ],
          "virtualHosts": {
            "fresh-prod.hosting.test": {
              "enableLetsEncrypt": true,
              "forceSSL": true
            },
            "www-fresh-prod.hosting.test": {
              "enableLetsEncrypt": true,
              "forceSSL": true
            }
          }
        }
      }
    }
    EOF
    printf '{}\n' > "$work/generated/flake.nix"
    cp "$work/generated/plan.json" "$TMPDIR/fresh-canonical-plan.json"

    cat > "$work/generated/state.json" <<'EOF'
    {
      "fresh-prod": {
        "userName": "fresh-prod",
        "uid": 3000,
        "virtualHosts": []
      }
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$NIX_LOG"
    exit 0
    EOF
    chmod +x "$fakeBin/nix"

    cat > "$fakeBin/ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    script="$(cat)"

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "/etc/os-release"; then
      printf 'ID=nixos\n'
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "'getent' 'passwd'"; then
      if [ "''${EXISTING_DEST:-0}" = 1 ]; then
        printf 'fresh-prod:x:3000:100::/home/fresh-prod:/bin/sh\n'
      fi
      exit 0
    fi

    exit 0
    EOF
    chmod +x "$fakeBin/ssh"

    cat > "$fakeBin/dig" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    args=" $* "
    printf '%s\n' "$*" >> "$DIG_LOG"

    if [ "''${DNS_HINT_FAIL:-0}" = 1 ]       && ! printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq '@'       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME'       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'fresh-prod.hosting.test'; then
      printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
      exit 0
    fi

    if [ "''${DNS_OBSERVATION_FAIL:-0}" = 1 ]       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq '@ns1.hosting.test'       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME'       && printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq 'fresh-prod.hosting.test'       && [ ! -f "$DNS_STATE_DIR/fresh-prod-new" ]; then
      printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
      exit 0
    fi

    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
    if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' hosting.test NS '; then
      printf 'hosting.test. 60 IN NS ns1.hosting.test.\n'
      exit 0
    fi

    if printf '%s\n' "$args" | ${pkgs.gnugrep}/bin/grep -Fq ' CNAME'; then
      if [ "''${DNS_STRANDED:-0}" = 1 ]; then
        printf 'fresh-prod.hosting.test. 60 IN CNAME old-node.hosting.test.\n'
      elif [ -f "$DNS_STATE_DIR/fresh-prod-new" ]; then
        printf 'fresh-prod.hosting.test. 60 IN CNAME new-node.hosting.test.\n'
      fi
    fi
    EOF
    chmod +x "$fakeBin/dig"

    cat > "$fakeBin/curl" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    args=" $* "
    case "$args" in
      *"/zones/zone/dns_records?per_page=1000&name="*)
        printf '{"success":true,"result":[]}\n'
        ;;
      *"-X POST "*"zones/zone/dns_records"*)
        touch "$DNS_STATE_DIR/fresh-prod-new"
        printf '{"success":true,"errors":[]}\n'
        ;;
      *"/zones/zone"*)
        printf '{"success":true,"result":{"name":"hosting.test"}}\n'
        ;;
      *)
        echo "unexpected curl invocation: $args" >&2
        exit 46
        ;;
    esac
    EOF
    chmod +x "$fakeBin/curl"

    (
      cd "$work"

      mkdir -p "$TMPDIR/dns-state"

      # Fresh environment: deploy the canonical end state first. Current
      # nixpkgs supplies a baseline self-signed certificate while ACME catches
      # up; Hostenv then reconciles DNS without a staging flake.
      : > "$log"
      : > "$digLog"
      rm -f "$TMPDIR/dns-state/fresh-prod-new"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" DIG_LOG="$digLog" DNS_STATE_DIR="$TMPDIR/dns-state" CF_API_TOKEN=test-token CF_ZONE_ID=zone \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification > "$TMPDIR/fresh.out" 2>&1
      ${pkgs.gnugrep}/bin/grep -Fq 'fresh environment on new-node' "$TMPDIR/fresh.out"
      test "$(${pkgs.gnugrep}/bin/grep -Ec 'new-node\.hosting\.test A$' "$digLog")" -eq 2
      test "$(${pkgs.gnugrep}/bin/grep -Ec 'new-node\.hosting\.test AAAA$' "$digLog")" -eq 2
      ! ${pkgs.gnugrep}/bin/grep -Fq 'path:' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq '#"new-node"."fresh-prod"' "$log"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/fresh-canonical-plan.json" generated/plan.json

      # An indeterminate authoritative read can still be repaired when
      # Cloudflare is configured. The failed read is reported, the CNAME is
      # written, and the post-update authoritative check must then succeed.
      : > "$log"
      : > "$digLog"
      rm -f "$TMPDIR/dns-state/fresh-prod-new"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" DIG_LOG="$digLog" DNS_STATE_DIR="$TMPDIR/dns-state" DNS_OBSERVATION_FAIL=1 CF_API_TOKEN=test-token CF_ZONE_ID=zone         ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification > "$TMPDIR/lookup-repair.out" 2>&1
      ${pkgs.gnugrep}/bin/grep -Fq 'could not verify current DNS for fresh-prod.hosting.test' "$TMPDIR/lookup-repair.out"
      ${pkgs.gnugrep}/bin/grep -Fq 'attempting the configured Cloudflare update' "$TMPDIR/lookup-repair.out"
      test -f "$TMPDIR/dns-state/fresh-prod-new"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/fresh-canonical-plan.json" generated/plan.json

      # Existing environment on the same node follows the same canonical
      # deploy/DNS-reconciliation flow and is classified from live username+UID observation.
      : > "$log"
      : > "$digLog"
      rm -f "$TMPDIR/dns-state/fresh-prod-new"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" DIG_LOG="$digLog" DNS_STATE_DIR="$TMPDIR/dns-state" EXISTING_DEST=1 CF_API_TOKEN=test-token CF_ZONE_ID=zone \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification > "$TMPDIR/existing.out" 2>&1
      ${pkgs.gnugrep}/bin/grep -Fq 'existing environment on new-node' "$TMPDIR/existing.out"
      test "$(${pkgs.gnugrep}/bin/grep -Ec 'new-node\.hosting\.test A$' "$digLog")" -eq 2
      test "$(${pkgs.gnugrep}/bin/grep -Ec 'new-node\.hosting\.test AAAA$' "$digLog")" -eq 2
      ! ${pkgs.gnugrep}/bin/grep -Fq 'path:' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/fresh-canonical-plan.json" generated/plan.json

      # If DNS explicitly identifies a provider node that has been removed from
      # inventory, do not silently reinterpret the deployment as fresh.
      : > "$log"
      : > "$digLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" DIG_LOG="$digLog" DNS_STATE_DIR="$TMPDIR/dns-state" DNS_STRANDED=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "environment pointing at a removed provider node was treated as fresh"
        exit 1
      fi
      test ! -s "$log"

      # If this safety lookup itself fails, the CLI cannot safely conclude that
      # the environment is fresh. Preserve the exact DNS failure and abort
      # before any deployment.
      : > "$log"
      : > "$digLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" DIG_LOG="$digLog" DNS_STATE_DIR="$TMPDIR/dns-state" DNS_HINT_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification > "$TMPDIR/hint-fail.out" 2>&1; then
        echo "failed removed-inventory DNS lookup was treated as fresh"
        exit 1
      fi
      test ! -s "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'Refusing to treat the environment as fresh until DNS can be verified' "$TMPDIR/hint-fail.out"
      ${pkgs.gnugrep}/bin/grep -Fq 'DNS server returned SERVFAIL' "$TMPDIR/hint-fail.out"
    )

    echo ok > "$out"
  '';


  provider-cli-node-retirement-plan = pkgs.runCommand "provider-cli-node-retirement-plan" { nativeBuildInputs = providerCliPackage.runtimeInputs; } ''
    set -euo pipefail

    work="$TMPDIR/provider"
    fakeBin="$TMPDIR/bin"
    newPlan="$TMPDIR/new-plan.json"
    newState="$TMPDIR/new-state.json"
    newFlake="$TMPDIR/new-flake.nix"
    mkdir -p "$work/generated" "$fakeBin"

    cat > "$work/generated/plan.json" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "deployUser": "deploy",
      "nodeStatus": {
        "old-node": "active",
        "new-node": "active"
      },
      "nodes": {
        "old-node": {},
        "new-node": {}
      },
      "nodeConnections": {
        "old-node": {
          "hostname": "old-node.hosting.test",
          "sshOpts": []
        },
        "new-node": {
          "hostname": "new-node.hosting.test",
          "sshOpts": []
        }
      },
      "environments": {
        "acme-prod": {
          "uid": 2000,
          "node": "old-node",
          "hostenv": {
            "userName": "acme-prod",
            "hostname": "acme-prod.hosting.test"
          }
        }
      }
    }
    EOF

    cat > "$work/generated/state.json" <<'EOF'
    {
      "acme-prod": {
        "userName": "acme-prod",
        "uid": 2000,
        "virtualHosts": []
      },
      "retired": {
        "userName": "retired",
        "uid": 2002,
        "virtualHosts": []
      }
    }
    EOF

    cat > "$newPlan" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "deployUser": "deploy",
      "nodeStatus": {
        "new-node": "active"
      },
      "nodes": {
        "new-node": {}
      },
      "nodeConnections": {
        "new-node": {
          "hostname": "new-node.hosting.test",
          "sshOpts": []
        }
      },
      "environments": {
        "acme-prod": {
          "uid": 2000,
          "node": "new-node",
          "hostenv": {
            "userName": "acme-prod",
            "hostname": "acme-prod.hosting.test"
          }
        }
      }
    }
    EOF

    cat > "$newState" <<'EOF'
    {
      "acme-prod": {
        "userName": "acme-prod",
        "uid": 2000,
        "virtualHosts": []
      },
      "retired": {
        "userName": "retired",
        "uid": 2002,
        "virtualHosts": []
      }
    }
    EOF

    cat > "$newFlake" <<'EOF'
    { }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    args=" $* "
    case "$args" in
      *" eval "*)
        printf 'x86_64-linux\n'
        ;;
      *" build "*"planPaths.x86_64-linux.plan"*)
        printf '%s\n' "$NEW_PLAN"
        ;;
      *" build "*"planPaths.x86_64-linux.state"*)
        printf '%s\n' "$NEW_STATE"
        ;;
      *" build "*"planPaths.x86_64-linux.flake"*)
        printf '%s\n' "$NEW_FLAKE"
        ;;
      *" flake update "*)
        exit 0
        ;;
      *)
        echo "unexpected nix invocation: $*" >&2
        exit 2
        ;;
    esac
    EOF
    chmod +x "$fakeBin/nix"

    cat > "$fakeBin/git" <<'EOF'
    #!${pkgs.runtimeShell}
    exit 0
    EOF
    chmod +x "$fakeBin/git"

    cat > "$fakeBin/ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    script="$(cat)"

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "# HOSTENV_RUNTIME_PROBE"; then
      if [ "''${ORPHAN_RUNTIME:-0}" = 1 ]; then
        printf 'acme-prod\n'
      fi
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "'getent' 'passwd'"; then
      if [ "''${NODE_EMPTY:-0}" != 1 ]; then
        printf 'acme-prod:x:2000:100::/home/acme-prod:/bin/sh\n'
      fi
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "/var/lib/hostenv/provider/migration-handoffs"; then
      if [ "''${HANDOFF_PROBE_FAIL:-0}" = 1 ]; then
        echo "unexpected migration handoff probe" >&2
        exit 97
      fi
      if [ "''${HANDOFF_PENDING:-0}" = 1 ]; then
        printf '2000\tquiesced old-node\n'
      fi
      exit 0
    fi

    exit 0
    EOF
    chmod +x "$fakeBin/ssh"

    cat > "$fakeBin/dig" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    if [ "''${DNS_FAIL:-0}" = 1 ]; then
      printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
      exit 0
    fi

    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
    if [ "''${DNS_RETIRED:-0}" = 1 ] \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq 'CNAME' \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq 'retired.hosting.test'; then
      printf 'retired.hosting.test. 60 IN CNAME old-node.hosting.test.\n'
    elif [ "''${DNS_OLD:-0}" = 1 ] && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq 'CNAME'; then
      printf 'acme-prod.hosting.test. 60 IN CNAME old-node.hosting.test.\n'
    fi
    EOF
    chmod +x "$fakeBin/dig"

    (
      cd "$work"

      # DNS is a node-removal safeguard, not a prerequisite for an ordinary
      # replan. A DNS outage must not block planning when the provider inventory
      # is unchanged and valid previous-plan history is available.
      cp generated/plan.json "$TMPDIR/unchanged-plan.json"
      PATH="$fakeBin:$PATH" NEW_PLAN="$TMPDIR/unchanged-plan.json" NEW_STATE="$newState" NEW_FLAKE="$newFlake" DNS_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run

      # The previous plan is useful evidence when it exists: an environment
      # cannot jump away from a node that disappears in the same plan.
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "node disappeared while its previous environment assignment still referenced it"
        exit 1
      fi

      # A proper drain first moves the environment while keeping the source
      # node in inventory as retiring.
      ${pkgs.jq}/bin/jq \
        '.nodeStatus["old-node"] = "retiring" | .environments["acme-prod"].node = "new-node"' \
        generated/plan.json > "$TMPDIR/retiring-plan.json"
      mv "$TMPDIR/retiring-plan.json" generated/plan.json
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "retiring node with a live Hostenv account was removed"
        exit 1
      fi

      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 ORPHAN_RUNTIME=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "retiring node with orphan Hostenv runtime was removed"
        exit 1
      fi

      # Even with valid previous-plan history and a clean retiring source,
      # a destination handoff must keep that source in inventory until deploy
      # has cleared the marker.
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 HANDOFF_PENDING=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "valid previous plan ignored pending migration handoff"
        exit 1
      fi

      PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run

      # state.json keeps old UID and hostname reservations, but those
      # reservations are not evidence that an environment is still deployed.
      # If this old hostname were queried, the fake DNS response would point at
      # old-node and make the plan fail.
      PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 DNS_RETIRED=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run

      # plan.json is disposable. Without historical plan data, live DNS is
      # the safety tripwire: a CNAME to the removed node blocks publication.
      rm generated/plan.json
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" DNS_OLD=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "missing previous plan ignored DNS pointing at the removed node"
        exit 1
      fi
      # Missing plan history still uses DNS as a warning, but does not SSH
      # into every proposed node looking for migration handoffs.
      PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" HANDOFF_PENDING=1 HANDOFF_PROBE_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run

      # A malformed generated plan has the same semantics: skip historical
      # comparison, but still fail closed while DNS identifies the old node.
      printf 'deliberately not JSON\n' > generated/plan.json
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" DNS_OLD=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "malformed previous plan ignored DNS pointing at the removed node"
        exit 1
      fi
      PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" HANDOFF_PROBE_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run

      # DNS is checked before the candidate plan is published. If live Hostenv
      # DNS still identifies a node outside proposed inventory, the old file
      # remains untouched so the failure is repeatable.
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 DNS_OLD=1 \
        ${cliPkg}/bin/hostenv-provider plan; then
        echo "plan published despite Hostenv DNS pointing at a removed node"
        exit 1
      fi
      grep -Fxq 'deliberately not JSON' generated/plan.json

      # A DNS transport/server failure is not equivalent to "no removed-node
      # CNAME". The safety check must fail closed and leave the old plan intact.
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 DNS_FAIL=1 \
        ${cliPkg}/bin/hostenv-provider plan; then
        echo "plan published despite an indeterminate DNS lookup"
        exit 1
      fi
      grep -Fxq 'deliberately not JSON' generated/plan.json

      # Once the safety checks pass, a non-dry plan atomically replaces the
      # generated plan. No same-directory candidate should remain.
      PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NEW_STATE="$newState" NEW_FLAKE="$newFlake" NODE_EMPTY=1 \
        ${cliPkg}/bin/hostenv-provider plan

      ${pkgs.jq}/bin/jq -S . generated/plan.json > "$TMPDIR/published.json"
      ${pkgs.jq}/bin/jq -S . "$newPlan" > "$TMPDIR/expected.json"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/expected.json" "$TMPDIR/published.json"
      ${pkgs.jq}/bin/jq -e '.retired.uid == 2002' generated/state.json >/dev/null
      test -z "$(find generated -maxdepth 1 -name '.plan.json.tmp-*' -print -quit)"
    )

    echo ok > "$out"
  '';

  provider-cli-dns-backoff = pkgs.runCommand "provider-cli-dns-backoff" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDnsBackoff.hs
    echo ok > "$out"
  '';
  provider-cli-environment-state = pkgs.runCommand "provider-cli-environment-state" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestEnvironmentState.hs
    echo ok > "$out"
  '';
  provider-cli-migration-handoff = pkgs.runCommand "provider-cli-migration-handoff" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestMigrationHandoff.hs
    echo ok > "$out"
  '';
  provider-cli-deploy-verification = pkgs.runCommand "provider-cli-deploy-verification" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDeployVerification.hs
    echo ok > "$out"
  '';
}
