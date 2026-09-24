{ pkgs, documentationEnabled }:
let
  src = ../../provider;
  rawCliPkg = pkgs.haskellPackages.callCabal2nix "hostenv-provider-cli" src { };
  cliPkg =
    if documentationEnabled then
      rawCliPkg
    else
      pkgs.haskell.lib.dontHaddock rawCliPkg;
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
  providerCliDnsGateFilter = pkgs.runCommand "provider-cli-dns-gate-filter" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDnsGateFilter.hs
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
  provider-cli-dns-gate-filter = providerCliDnsGateFilter;
  provider-cli-dns-gate-filtering = providerCliDnsGateFilter;
  provider-cli-dry-run-help = pkgs.runCommand "provider-cli-dry-run-help" { } ''
    set -euo pipefail
    for subcmd in plan dns-gate deploy; do
      help_output="$(${cliPkg}/bin/hostenv-provider "$subcmd" --help)"
      ${pkgs.gnugrep}/bin/grep -q -- "--dry-run" <<<"$help_output"
    done
    echo ok > "$out"
  '';

  provider-cli-cleanup-only-system-targets = pkgs.runCommand "provider-cli-cleanup-only-system-targets" { } ''
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
      }
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$NIX_LOG"
    if [ "''${FAIL_RETIRED_SYSTEM:-0}" = 1 ] \
      && printf '%s\n' "$*" | grep -Fq 'generated/.#"retired-node"."system"'; then
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

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"retired-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."acme-prod"' "$log"
      test "$(wc -l < "$log")" -eq 4

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node old-node

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      test "$(wc -l < "$log")" -eq 1

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node retired-node

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"retired-node"."system"' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'new-node' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod' "$log"
      test "$(wc -l < "$log")" -eq 1

      : > "$log"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" FAIL_RETIRED_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node retired-node; then
        echo "cleanup-only system deployment failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"retired-node"."system"' "$log"
      test "$(wc -l < "$log")" -eq 1

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
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"retired-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$log"

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

  provider-cli-move-finalization-order = pkgs.runCommand "provider-cli-move-finalization-order" { } ''
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
        "new-node": {}
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
          "virtualHosts": {}
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
      }
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    printf '%s\n' "$*" >> "$NIX_LOG"
    printf 'NIX %s\n' "$*" >> "$EVENT_LOG"

    if [ "''${FAIL_DEST_ENV:-0}" = 1 ] \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"'; then
      exit 41
    fi

    if [ "''${FAIL_SOURCE_SYSTEM:-0}" = 1 ] \
      && printf '%s\n' "$*" | ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"'; then
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

    printf 'target=%s\n%s\n' "$target" "$script" >> "$SSH_LOG"

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "/etc/os-release"; then
      printf 'ID=nixos\n'
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "'getent' 'passwd'"; then
      case "$target" in
        *old-node.hosting.test*)
          printf 'acme-prod:x:2000:100::/home/acme-prod:/bin/sh\n'
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
      printf 'CLEANUP acme-prod\n' >> "$EVENT_LOG"
      exit 0
    fi

    if printf '%s\n' "$script" | ${pkgs.gnugrep}/bin/grep -Fq "loginctl enable-linger"; then
      printf 'ROLLBACK acme-prod\n' >> "$EVENT_LOG"
      exit 0
    fi

    exit 0
    EOF
    chmod +x "$fakeBin/ssh"

    cat > "$fakeBin/curl" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
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
      cp generated/state.json "$TMPDIR/state-before.json"

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

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_DEST_ENV=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "destination environment failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$nixLog"
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
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification --skip-migrations acme-prod

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$nixLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$nixLog"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build

      dest_system_line="$(${pkgs.gnugrep}/bin/grep -n -F 'generated/.#"new-node"."system"' "$eventLog" | head -n1 | cut -d: -f1)"
      dest_env_line="$(${pkgs.gnugrep}/bin/grep -n -F 'generated/.#"new-node"."acme-prod"' "$eventLog" | head -n1 | cut -d: -f1)"
      cleanup_line="$(${pkgs.gnugrep}/bin/grep -n -F 'CLEANUP acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      source_system_line="$(${pkgs.gnugrep}/bin/grep -n -F 'generated/.#"old-node"."system"' "$eventLog" | head -n1 | cut -d: -f1)"

      test "$dest_system_line" -lt "$dest_env_line"
      test "$dest_env_line" -lt "$cleanup_line"
      test "$cleanup_line" -lt "$source_system_line"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      if PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" FAIL_SOURCE_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "source system failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq 'CLEANUP acme-prod' "$eventLog"
      ${pkgs.gnugrep}/bin/grep -Fq 'ROLLBACK acme-prod' "$eventLog"
      cleanup_line="$(${pkgs.gnugrep}/bin/grep -n -F 'CLEANUP acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      source_system_line="$(${pkgs.gnugrep}/bin/grep -n -F 'generated/.#"old-node"."system"' "$eventLog" | head -n1 | cut -d: -f1)"
      rollback_line="$(${pkgs.gnugrep}/bin/grep -n -F 'ROLLBACK acme-prod' "$eventLog" | head -n1 | cut -d: -f1)"
      test "$cleanup_line" -lt "$source_system_line"
      test "$source_system_line" -lt "$rollback_line"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$nixLog"
    )

    echo ok > "$out"
  '';

  provider-cli-new-environment-deploy = pkgs.runCommand "provider-cli-new-environment-deploy" { } ''
    set -euo pipefail

    work="$TMPDIR/provider"
    fakeBin="$TMPDIR/bin"
    log="$TMPDIR/nix.log"
    mkdir -p "$work/generated" "$fakeBin"

    cat > "$work/generated/plan.json" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "nodes": {
        "new-node": {}
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
          "virtualHosts": {}
        }
      }
    }
    EOF

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
      exit 0
    fi

    exit 0
    EOF
    chmod +x "$fakeBin/ssh"

    cat > "$fakeBin/dig" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    if [ "''${DNS_STRANDED:-0}" = 1 ]; then
      printf 'old-node.hosting.test.\n'
    fi
    EOF
    chmod +x "$fakeBin/dig"

    (
      cd "$work"

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."fresh-prod"' "$log"
      test "$(wc -l < "$log")" -eq 2

      # A reservation in state.json must not make a fresh environment look
      # previously deployed: the same no-source deployment remains valid.
      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."fresh-prod"' "$log"

      # If DNS explicitly identifies a provider node that has been removed from
      # inventory, do not silently reinterpret the deployment as fresh.
      : > "$log"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" DNS_STRANDED=1 \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "environment pointing at a removed provider node was treated as fresh"
        exit 1
      fi
      test ! -s "$log"
    )

    echo ok > "$out"
  '';


  provider-cli-node-retirement-plan = pkgs.runCommand "provider-cli-node-retirement-plan" { } ''
    set -euo pipefail

    work="$TMPDIR/provider"
    fakeBin="$TMPDIR/bin"
    newPlan="$TMPDIR/new-plan.json"
    mkdir -p "$work/generated" "$fakeBin"

    cat > "$work/generated/plan.json" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "deployUser": "deploy",
      "nodeStatus": {
        "old-node": "active"
      },
      "nodes": {
        "old-node": {}
      },
      "nodeConnections": {
        "old-node": {
          "hostname": "old-node.hosting.test",
          "sshOpts": []
        }
      },
      "environments": {
        "acme-prod": {
          "uid": 2000,
          "node": "old-node"
        }
      }
    }
    EOF

    cat > "$work/generated/state.json" <<'EOF'
    {}
    EOF

    cat > "$newPlan" <<'EOF'
    {
      "hostenvHostname": "hosting.test",
      "deployUser": "deploy",
      "nodeStatus": {},
      "nodes": {},
      "nodeConnections": {},
      "environments": {}
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    case " $* " in
      *" eval "*)
        printf 'x86_64-linux\n'
        ;;
      *" build "*)
        printf '%s\n' "$NEW_PLAN"
        ;;
      *)
        echo "unexpected nix invocation: $*" >&2
        exit 2
        ;;
    esac
    EOF
    chmod +x "$fakeBin/nix"

    cat > "$fakeBin/ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    set -euo pipefail
    cat >/dev/null
    if [ "''${NODE_EMPTY:-0}" != 1 ]; then
      printf 'acme-prod:x:2000:100::/home/acme-prod:/bin/sh\n'
    fi
    EOF
    chmod +x "$fakeBin/ssh"

    (
      cd "$work"

      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "active node was removed without entering retiring state"
        exit 1
      fi

      ${pkgs.gnused}/bin/sed -i 's/"old-node": "active"/"old-node": "retiring"/' generated/plan.json

      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "retiring node with a live Hostenv environment was removed"
        exit 1
      fi

      PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NODE_EMPTY=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run

      cat > generated/state.json <<'EOF'
      {
        "acme-prod": {
          "userName": "acme-prod",
          "uid": 2000,
          "virtualHosts": []
        }
      }
      EOF
      rm generated/plan.json
      if PATH="$fakeBin:$PATH" NEW_PLAN="$newPlan" NODE_EMPTY=1 \
        ${cliPkg}/bin/hostenv-provider plan --dry-run; then
        echo "existing provider planned without its previous inventory plan"
        exit 1
      fi
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
  provider-cli-deploy-verification = pkgs.runCommand "provider-cli-deploy-verification" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDeployVerification.hs
    echo ok > "$out"
  '';
}
