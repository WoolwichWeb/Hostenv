{ pkgs }:
let
  cli = import ../../provider/package.nix {
    inherit pkgs;
    providerSrc = ../../provider;
  };
in
pkgs.runCommand "provider-acme-cli" { nativeBuildInputs = cli.runtimeInputs; } ''
  set -euo pipefail
  mkdir -p "$TMPDIR/provider/generated" "$TMPDIR/bin" "$TMPDIR/dns"
  cd "$TMPDIR/provider"
  export EVENT_LOG="$TMPDIR/events" DNS_STATE_DIR="$TMPDIR/dns"

  # Nix's builder otherwise shows only an exit code when a bare test/grep
  # assertion fails under set -e. Report both the scenario and captured output.
  current_test="setup"
  report_failure() {
    local status="$1"
    printf 'provider-acme-cli: %s failed (exit %s)\n' \
      "$current_test" "$status" >&2
    if [ -f "$EVENT_LOG" ]; then
      printf '%s\n' '--- deployment events ---' >&2
      cat "$EVENT_LOG" >&2
    fi
    if [ -f "$TMPDIR/deploy.log" ]; then
      printf '%s\n' '--- hostenv-provider output ---' >&2
      cat "$TMPDIR/deploy.log" >&2
    fi
    exit "$status"
  }
  trap 'report_failure "$?"' ERR

  cat > "$TMPDIR/plan.json" <<'JSON'
  {
    "hostenvHostname": "hosting.test",
    "nodes": {"new-node": {"services": {"nginx": {"virtualHosts": {
      "fresh-prod.hosting.test": {"enableACME": true, "forceSSL": true}
    }}}}},
    "environments": {"fresh-prod": {
      "hostenv": {
        "userName": "fresh-prod",
        "runtimeDir": "/run/hostenv/user/fresh-prod",
        "hostname": "fresh-prod.hosting.test"
      },
      "uid": 3000,
      "node": "new-node",
      "migrations": [],
      "virtualHosts": {
        "fresh-prod.hosting.test": {"enableLetsEncrypt": true, "forceSSL": true},
        "www.example.test": {"enableLetsEncrypt": true, "forceSSL": true}
      }
    }}
  }
  JSON
  printf '{}\n' > generated/flake.nix
  printf '{"fresh-prod":{"userName":"fresh-prod","uid":3000,"virtualHosts":[]}}\n' > generated/state.json
  cp generated/state.json "$TMPDIR/state.json"

  cat > "$TMPDIR/bin/nix" <<'SH'
  #!${pkgs.runtimeShell}
  case "$*" in
    *'#"new-node"."system"'*)
      echo SYSTEM >> "$EVENT_LOG"
      exit "$SYSTEM_FAIL"
      ;;
    *'#"new-node"."fresh-prod"'*)
      echo ENVIRONMENT >> "$EVENT_LOG"
      ;;
    *) echo "Unexpected Nix invocation: $*" >&2; exit 90 ;;
  esac
  SH

  cat > "$TMPDIR/bin/ssh" <<'SH'
  #!${pkgs.runtimeShell}
  set -euo pipefail
  script="$(cat)"
  if grep -Fq /etc/os-release <<< "$script"; then
    printf 'ID=nixos\n'
  elif grep -Fq "'getent' 'passwd'" <<< "$script"; then
    if [ "$EXISTING_DEST" = 1 ]; then
      printf 'fresh-prod:x:3000:100::/home/fresh-prod:/bin/sh\n'
    fi
  elif grep -Fq hostenv-acme-deploy <<< "$script"; then
    grep -Fq "'retry' '--' 'fresh-prod.hosting.test' 'www.example.test'" <<< "$script"
    test -e "$DNS_STATE_DIR/ready"
    echo CERTIFICATE >> "$EVENT_LOG"
    exit "$ACME_FAIL"
  fi
  SH

  cat > "$TMPDIR/bin/dig" <<'SH'
  #!${pkgs.runtimeShell}
  set -euo pipefail
  args=" $* "
  printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
  if [[ "$args" == *' hosting.test NS '* ]]; then
    printf 'hosting.test. 60 IN NS ns1.hosting.test.\n'
  elif [[ "$args" == *'www.example.test'* ]]; then
    echo "A vanity-domain DNS query was made" >&2
    exit 88
  elif [[ "$args" == *'fresh-prod.hosting.test'* && "$args" == *' CNAME'* ]] \
      && [ -e "$DNS_STATE_DIR/ready" ]; then
    printf 'fresh-prod.hosting.test. 60 IN CNAME new-node.hosting.test.\n'
  fi
  SH

  cat > "$TMPDIR/bin/curl" <<'SH'
  #!${pkgs.runtimeShell}
  set -euo pipefail
  case " $* " in
    *'/zones/zone/dns_records?per_page=1000&name='*)
      if [ "''${PROXIED_MANAGED:-0}" = 1 ]; then
        printf '{"success":true,"result":[{"id":"existing","type":"CNAME","name":"fresh-prod.hosting.test","content":"old-node.hosting.test","proxied":true}]}\n'
      else
        printf '{"success":true,"result":[]}\n'
      fi
      ;;
    *'-X PUT '*'dns_records/existing'*)
      # Existing Hostenv-controlled records must be returned to DNS-only.
      grep -Fq '"proxied":false' <<< "$*"
      touch "$DNS_STATE_DIR/ready"
      echo DNS >> "$EVENT_LOG"
      printf '{"success":true,"errors":[]}\n'
      ;;
    *'-X POST '*'zones/zone/dns_records'*)
      if [ "$DNS_FAIL" = 1 ]; then
        printf '{"success":false,"errors":[{"message":"test DNS failure"}]}\n'
      else
        touch "$DNS_STATE_DIR/ready"
        echo DNS >> "$EVENT_LOG"
        printf '{"success":true,"errors":[]}\n'
      fi
      ;;
    *'/zones/zone'*)
      printf '{"success":true,"result":{"name":"hosting.test"}}\n'
      ;;
    *) echo "Unexpected curl invocation: $*" >&2; exit 91 ;;
  esac
  SH
  chmod +x "$TMPDIR/bin/"*
  export PATH="$TMPDIR/bin:$PATH" CF_API_TOKEN=test-token CF_ZONE_ID=zone

  reset_case() {
    cp "$TMPDIR/plan.json" generated/plan.json
    rm -f "$DNS_STATE_DIR/ready"
    : > "$EVENT_LOG"
    export SYSTEM_FAIL=0 ACME_FAIL=0 DNS_FAIL=0 EXISTING_DEST=0 PROXIED_MANAGED=0
  }
  run_deploy() {
    ${cli.unwrapped}/bin/hostenv-provider deploy --remote-build --skip-verification \
      > "$TMPDIR/deploy.log" 2>&1
  }
  assert_unchanged() {
    cmp "$TMPDIR/plan.json" generated/plan.json
    cmp "$TMPDIR/state.json" generated/state.json
  }

  # The command being tested is the real provider CLI. Its external commands
  # are replaced so the test can observe ordering without contacting servers.
  for existing in 0 1; do
    current_test="successful deployment (existing=$existing)"
    reset_case
    export EXISTING_DEST="$existing"
    run_deploy
    ! grep -Fq 'www.example.test' "$TMPDIR/deploy.log"
    ! grep -Fq 'authoritative nameserver discovery' "$TMPDIR/deploy.log"
    test "$(cat "$EVENT_LOG")" = "$(printf 'SYSTEM\nENVIRONMENT\nDNS\nCERTIFICATE')"
    assert_unchanged
  done

  # Existing Hostenv-managed records must be set to DNS-only. Vanity domains
  # are never queried or changed, and their certificates are still requested.
  current_test="correct existing proxied Hostenv DNS record"
  reset_case
  export PROXIED_MANAGED=1
  run_deploy
  test "$(cat "$EVENT_LOG")" = "$(printf 'SYSTEM\nENVIRONMENT\nDNS\nCERTIFICATE')"
  assert_unchanged

  current_test="DNS reconciliation failure"
  reset_case
  export DNS_FAIL=1
  if run_deploy; then
    echo "A DNS failure was accepted" >&2
    report_failure 1
  fi
  ! grep -qx CERTIFICATE "$EVENT_LOG"
  grep -Fq 'Environment fresh-prod was deployed, but domain setup could not finish' "$TMPDIR/deploy.log"
  grep -Fq 'Cloudflare could not update DNS for fresh-prod.hosting.test: test DNS failure' "$TMPDIR/deploy.log"
  grep -Fq 'Check the Cloudflare zone and API token, then rerun deploy.' "$TMPDIR/deploy.log"
  ! grep -Fq 'dig exited' "$TMPDIR/deploy.log"
  assert_unchanged

  current_test="DNS update without Cloudflare credentials"
  reset_case
  if (unset CF_API_TOKEN CF_ZONE_ID; run_deploy); then
    echo "A DNS update without Cloudflare credentials was accepted" >&2
    report_failure 1
  fi
  grep -Fq 'DNS for fresh-prod.hosting.test does not point to new-node.hosting.test' "$TMPDIR/deploy.log"
  grep -Fq 'the Cloudflare API token is missing' "$TMPDIR/deploy.log"
  grep -Fq 'Check that its DNS record points to new-node.hosting.test' "$TMPDIR/deploy.log"
  ! grep -qx DNS "$EVENT_LOG"
  ! grep -qx CERTIFICATE "$EVENT_LOG"
  assert_unchanged

  # The system, environment and DNS can deploy successfully before a remote
  # certificate-retry request fails. Assert that the reported failure is from
  # certificate setup, not system activation, for both fresh and existing users.
  for existing in 0 1; do
    current_test="certificate retry failure (existing=$existing)"
    reset_case
    export EXISTING_DEST="$existing" ACME_FAIL=9
    if run_deploy; then
      echo "A failed remote certificate retry was accepted" >&2
      report_failure 1
    fi
    test "$(cat "$EVENT_LOG")" = "$(printf 'SYSTEM\nENVIRONMENT\nDNS\nCERTIFICATE')"
    grep -Fq 'Environment fresh-prod was deployed, but domain setup could not finish' "$TMPDIR/deploy.log"
    grep -Fq 'Could not request certificates on new-node for fresh-prod.hosting.test, www.example.test (exit code 9).' "$TMPDIR/deploy.log"
    grep -Fq 'Check the certificate service logs on that node, then rerun deploy.' "$TMPDIR/deploy.log"
    ! grep -Fq 'System deployment failed' "$TMPDIR/deploy.log"
    assert_unchanged
  done

  current_test="system deployment failure"
  reset_case
  export SYSTEM_FAIL=42
  if run_deploy; then
    echo "A failed system deployment was accepted" >&2
    report_failure 1
  fi
  test "$(cat "$EVENT_LOG")" = SYSTEM
  assert_unchanged

  current_test="deployment without ACME"
  reset_case
  jq '
    .environments["fresh-prod"].virtualHosts["fresh-prod.hosting.test"].enableLetsEncrypt = false |
    .environments["fresh-prod"].virtualHosts["fresh-prod.hosting.test"].forceSSL = false |
    .environments["fresh-prod"].virtualHosts["www.example.test"].enableLetsEncrypt = false |
    .environments["fresh-prod"].virtualHosts["www.example.test"].forceSSL = false |
    .nodes["new-node"].services.nginx.virtualHosts["fresh-prod.hosting.test"].enableACME = false |
    .nodes["new-node"].services.nginx.virtualHosts["fresh-prod.hosting.test"].forceSSL = false
  ' generated/plan.json > "$TMPDIR/plain-plan.json"
  cp "$TMPDIR/plain-plan.json" generated/plan.json
  run_deploy
  ! grep -qx CERTIFICATE "$EVENT_LOG"
  cmp "$TMPDIR/plain-plan.json" generated/plan.json
  cmp "$TMPDIR/state.json" generated/state.json

  touch "$out"
''
