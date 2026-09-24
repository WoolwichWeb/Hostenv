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
            "runtimeDir": "/run/hostenv/user/acme-prod"
          },
          "uid": 2000,
          "knownIdentity": true,
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
          printf 'acme-prod:x:2000:100::/home/acme-prod:/bin/sh\n'
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
            "runtimeDir": "/run/hostenv/user/acme-prod"
          },
          "uid": 2000,
          "knownIdentity": true,
          "node": "new-node",
          "migrations": [ "demo-migrate" ],
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

    (
      cd "$work"
      cp generated/state.json "$TMPDIR/state-before.json"

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

      : > "$nixLog"
      : > "$sshLog"
      : > "$eventLog"
      PATH="$fakeBin:$PATH" NIX_LOG="$nixLog" SSH_LOG="$sshLog" EVENT_LOG="$eventLog" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification

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
            "runtimeDir": "/run/hostenv/user/fresh-prod"
          },
          "uid": 3000,
          "knownIdentity": false,
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

    (
      cd "$work"

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."fresh-prod"' "$log"
      test "$(wc -l < "$log")" -eq 2

      ${pkgs.gnused}/bin/sed -i 's/"knownIdentity": false/"knownIdentity": true/' generated/plan.json
      : > "$log"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification; then
        echo "missing known environment was incorrectly treated as new"
        exit 1
      fi
      test ! -s "$log"
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
