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
        "new-node": {}
      },
      "environments": {
        "acme-prod": {
          "hostenv": {
            "userName": "acme-prod",
            "runtimeDir": "/run/hostenv/user/acme-prod"
          },
          "node": "new-node",
          "virtualHosts": {}
        }
      }
    }
    EOF

    cat > "$fakeBin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$NIX_LOG"
    if [ "''${FAIL_OLD_SYSTEM:-0}" = 1 ] \
      && printf '%s\n' "$*" | grep -Fq 'generated/.#"old-node"."system"'; then
      exit 42
    fi
    exit 0
    EOF
    chmod +x "$fakeBin/nix"

    (
      cd "$work"

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."system"' "$log"
      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"new-node"."acme-prod"' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."acme-prod"' "$log"
      test "$(wc -l < "$log")" -eq 3

      : > "$log"
      PATH="$fakeBin:$PATH" NIX_LOG="$log" \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node old-node

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'new-node' "$log"
      ! ${pkgs.gnugrep}/bin/grep -Fq 'acme-prod' "$log"
      test "$(wc -l < "$log")" -eq 1

      : > "$log"
      if PATH="$fakeBin:$PATH" NIX_LOG="$log" FAIL_OLD_SYSTEM=1 \
        ${cliPkg}/bin/hostenv-provider deploy --dry-run --node old-node; then
        echo "cleanup-only system deployment failure was reported as success"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -Fq 'generated/.#"old-node"."system"' "$log"
      test "$(wc -l < "$log")" -eq 1
    )

    echo ok > "$out"
  '';
  provider-cli-dns-backoff = pkgs.runCommand "provider-cli-dns-backoff" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDnsBackoff.hs
    echo ok > "$out"
  '';
  provider-cli-dns-points-to-cache = pkgs.runCommand "provider-cli-dns-points-to-cache" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDnsPointsToCache.hs
    echo ok > "$out"
  '';
  provider-cli-prev-node-discovery = pkgs.runCommand "provider-cli-prev-node-discovery" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestPrevNodeDiscovery.hs
    echo ok > "$out"
  '';
  provider-cli-deploy-verification = pkgs.runCommand "provider-cli-deploy-verification" { } ''
    set -euo pipefail
    ${ghc}/bin/runghc -i${src} ${src}/TestDeployVerification.hs
    echo ok > "$out"
  '';
}
