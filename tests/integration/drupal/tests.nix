# Drupal 10+ specific tests (assert-based).
{ pkgs, envs }:

let
  lib = pkgs.lib;
  support = import ../../support { inherit pkgs lib; };
  asserts = support.asserts;

  profileStructure = env: prefix: {
    "${prefix}-profile-structure" = asserts.assertRun {
      name = "${prefix}-profile-structure";
      inherit env;
      script = ''
        test -d "$profile" || { echo "missing $profile"; exit 1; }
        test -d "$profile/systemd/user" || { echo "missing systemd/user"; exit 1; }
        test -f "$profile/bin/activate" || { echo "missing bin/activate"; exit 1; }
        test -x "$profile/bin/hello" || { echo "missing project runtime package"; exit 1; }
        test -f "$profile/etc/nginx/nginx.conf" || { echo "missing nginx.conf"; exit 1; }
        cronUnit="$profile/systemd/user/cron-${env.config.services.drupal.codebase.name}.service"
        test -f "$cronUnit" || { echo "missing Drupal cron unit"; exit 1; }
        grep -Fq '${pkgs.hello}/bin' "$cronUnit" || {
          echo "project runtime package missing from Drupal cron PATH"
          exit 1
        }
      '';
    };
  };

  nginxSyntax = env: prefix: {
    "${prefix}-test-nginx-config-valid" = asserts.assertRun {
      name = "${prefix}-test-nginx-config-valid";
      inherit env;
      buildInputs = [ pkgs.nginx ];
      script = ''
        nginxConf="$profile/etc/nginx/nginx.conf"
        test -f "$nginxConf" || { echo "nginx.conf not found"; exit 1; }
        grep -Fq 'fastcgi_read_timeout 300s;' "$nginxConf" || {
          echo "shared FastCGI read timeout is not 300 seconds"
          exit 1
        }
        tmpdir=$(mktemp -d)
        mkdir -p "$tmpdir"/{logs,run}
        output=$("$profile"/bin/nginx -e "$tmpdir/error.log" -t -c "$nginxConf" -p "$tmpdir" 2>&1 || true)
        grep -q "syntax is ok" <<<"$output" || { echo "$output"; exit 1; }
      '';
    };
  };

  nginxExtraConfig = env: prefix: {
    "${prefix}-test-nginx-extra-config" = asserts.assertRun {
      name = "${prefix}-test-nginx-extra-config";
      inherit env;
      script = ''
        conf="$profile/etc/nginx/nginx.conf"
        test -f "$conf" || { echo "missing nginx.conf"; exit 1; }
        if ! awk '
          prev && $0 ~ /^[[:space:]]*try_files \$uri \/index\.php\?\$query_string;[[:space:]]*$/ {
            found = 1
            exit 0
          }

          {
            prev = ($0 ~ /^[[:space:]]*# Location mkBefore test marker[[:space:]]*$/)
          }

          END {
            exit found ? 0 : 1
          }
        ' "$conf"; then
          echo "Expected '# Location mkBefore test marker' to be followed by 'try_files $uri /index.php?$query_string;'"
          echo
          echo "Actual config can be found at:"
          echo "$conf"
          exit 1
        fi
      '';
    };
  };

  nginxDebugHeaders = { prod, dev, prefix }: {
    "${prefix}-prod-no-debug-headers" = asserts.assertRun {
      name = "${prefix}-prod-no-debug-headers";
      env = prod;
      script = ''
        conf="$profile/etc/nginx/nginx.conf"
        test -f "$conf" || { echo "missing nginx.conf"; exit 1; }
        if grep -q '\$hostenv_handled' "$conf"; then
          echo "\$hostenv_handled present in prod"
          exit 1
        fi
      '';
    };
    "${prefix}-dev-has-debug-headers" = asserts.assertRun {
      name = "${prefix}-dev-has-debug-headers";
      env = dev;
      script = ''
        conf="$profile/etc/nginx/nginx.conf"
        test -f "$conf" || { echo "missing nginx.conf"; exit 1; }
        if ! grep -q '\$hostenv_handled' "$conf"; then
          echo "\$hostenv_handled missing in dev"
          exit 1
        fi
      '';
    };
  };

  phpConfig = env: prefix: {
    "${prefix}-php-config-file" = asserts.assertRun {
      name = "${prefix}-php-config-file";
      inherit env;
      script = ''
        phpConf="$profile/etc/php-fpm.d"
        test -d "$phpConf" || { echo "missing $phpConf"; exit 1; }
        compgen -G "$phpConf/*.ini" >/dev/null || { echo "no ini files in $phpConf"; exit 1; }
        grep -Fq 'php_admin_value[error_log] = syslog' \
          "$phpConf/${env.config.services.drupal.codebase.name}.conf" \
          || { echo "PHP errors are not routed to syslog"; exit 1; }
      '';
    };
  };

  nginxSocketListen = env: prefix: {
    "${prefix}-unix-socket-listen" = asserts.assertRun {
      name = "${prefix}-unix-socket-listen";
      inherit env;
      script = ''
        conf="$profile/etc/nginx/nginx.conf"
        test -f "$conf" || { echo "missing nginx.conf"; exit 1; }
        grep -q 'listen.*unix:.*in\.sock' "$conf" || {
          echo "unix socket listener not found in nginx config"
          exit 1
        }
      '';
    };
  };

  drupalStructure = env: prefix: {
    "${prefix}-test-drupal-structure" = asserts.assertRun {
      name = "${prefix}-test-drupal-structure";
      inherit env;
      script = ''
        compgen -G "$profile/share/php/*/web" >/dev/null || { echo "missing web directory"; exit 1; }
        compgen -G "$profile/share/php/*/web/index.php" >/dev/null || { echo "missing web/index.php"; exit 1; }
      '';
    };
  };

  drushCanonicalUri = env: prefix: expectedUri: {
    "${prefix}-drush-canonical-uri" = asserts.assertRun {
      name = "${prefix}-drush-canonical-uri";
      inherit env;
      script = ''
        drush="$profile/bin/drush"
        test -x "$drush" || { echo "missing drush wrapper"; exit 1; }
        grep -Fq -- '--uri=${expectedUri}' "$drush" || {
          echo "drush wrapper does not default to canonical URI ${expectedUri}"
          exit 1
        }
        grep -Fq -- '--uri=*|-l|--uri)' "$drush" || {
          echo "drush wrapper no longer preserves caller-supplied URI overrides"
          exit 1
        }
      '';
    };
  };

  drupalRestoreMarker = env: prefix: {
    "${prefix}-restore-marker" = asserts.assertRun {
      name = "${prefix}-restore-marker";
      inherit env;
      script = ''
        activate="$profile/bin/activate"
        test -f "$activate" || { echo "missing activate script"; exit 1; }
        grep -q "HOSTENV_RESTORE_DRUPAL_BEGIN" "$activate" || {
          echo "restore marker missing"
          exit 1
        }
        restore_plan="${env.config.hostenv.runtimeDir}/restore/plan.json"
        grep -q "$restore_plan" "$activate" || {
          echo "restore plan path missing"
          exit 1
        }
        grep -q 'del(.snapshots' "$activate" || {
          echo "restore plan cleanup missing"
          exit 1
        }
        grep -q 'restore_key="drupal-migrate"' "$activate" || {
          echo "restore plan key missing"
          exit 1
        }
      '';
    };
  };

in
profileStructure envs.drupalProduction "drupal-prod"
// profileStructure envs.drupalDev "drupal-dev"
// nginxSyntax envs.drupalProduction "drupal-prod"
// nginxSyntax envs.drupalDev "drupal-dev"
// nginxExtraConfig envs.drupalProduction "drupal-prod"
// nginxExtraConfig envs.drupalDev "drupal-dev"
// (nginxDebugHeaders { prod = envs.drupalProduction; dev = envs.drupalDev; prefix = "drupal"; })
// phpConfig envs.drupalDev "drupal-dev"
// phpConfig envs.drupalProduction "drupal-prod"
// nginxSocketListen envs.drupalProduction "drupal-prod"
// nginxSocketListen envs.drupalDev "drupal-dev"
// drupalStructure envs.drupalProduction "drupal-prod"
// drupalStructure envs.drupalDev "drupal-dev"
// (drushCanonicalUri envs.drupalProduction "drupal-prod" "https://www.example.com")
// drupalRestoreMarker envs.drupalProduction "drupal-prod"
  // drupalRestoreMarker envs.drupalDev "drupal-dev"
