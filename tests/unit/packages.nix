{ pkgs, makeHostenv }:
let
  env = makeHostenv [
    ({ lib, ... }: {
      hostenv = {
        organisation = "acme";
        project = "packages";
        hostenvHostname = "hosting.test";
        root = ./.;
      };
      packages = [ pkgs.hello ];
      # Framework modules can run activation steps before the normal option
      # priority, so package PATH setup must be earlier still.
      activate = lib.mkOrder 1 ''
        hello > "$HOSTENV_PACKAGES_ACTIVATION_OUTPUT"
      '';
      environments.main = {
        enable = true;
        type = "production";
      };
    })
  ] "main";
in
{
  hostenv-packages-activation = pkgs.runCommand "hostenv-packages-activation" { } ''
    set -euo pipefail
    output="$TMPDIR/activation-output"

    # Model a first deployment: the caller PATH deliberately does not contain
    # pkgs.hello and no previous Hostenv profile is installed. Give systemd a
    # private runtime directory as well so this test can never interact with a
    # user manager inherited from the build host.
    install -d -m 0700 "$TMPDIR/run"
    # The activation hook runs before Hostenv contacts user systemd.
    # No user manager exists in the build sandbox, so the full activation
    # must fail after the hook has exercised the package PATH.
    if PATH=${pkgs.coreutils}/bin \
      XDG_CONFIG_HOME="$TMPDIR/config" \
      XDG_STATE_HOME="$TMPDIR/state" \
      XDG_CACHE_HOME="$TMPDIR/cache" \
      XDG_RUNTIME_DIR="$TMPDIR/run" \
      HOSTENV_PACKAGES_ACTIVATION_OUTPUT="$output" \
      ${env.config.activatePackage}/bin/activate >"$TMPDIR/activation-log" 2>&1
    then
      echo "Activation unexpectedly succeeded without user systemd" >&2
      exit 1
    fi

    grep -Fq 'Hello, world!' "$output" || {
      cat "$TMPDIR/activation-log" >&2
      echo "Activation did not run the package PATH hook" >&2
      exit 1
    }
    grep -Fq 'user systemd service manager is not running' "$TMPDIR/activation-log" || {
      cat "$TMPDIR/activation-log" >&2
      echo "Activation failed for a reason other than the missing user manager" >&2
      exit 1
    }
    touch "$out"
  '';
}
