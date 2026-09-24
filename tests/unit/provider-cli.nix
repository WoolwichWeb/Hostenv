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
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --remote-build --skip-verification

      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"retired-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$log"

      # A source-only deployment can observe that this is a moved environment,
      # but cannot prove the destination participates in the same transaction.
      # It must fail before deploy-rs can remove the source account.
      : > "$log"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --node old-node --remote-build --skip-verification; then
        echo "node-filtered moved-source deployment was reported as success"
        exit 1
      fi
      test ! -s "$log"
      ${pkgs.diffutils}/bin/cmp "$TMPDIR/state-before.json" generated/state.json
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
