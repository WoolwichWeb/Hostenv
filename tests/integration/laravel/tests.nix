{ pkgs, envs }:
let
  lib = pkgs.lib;
  asserts = (import ../../support { inherit pkgs lib; }).asserts;

  frameworkVersions = {
    "10" = "10.50.3";
    "11" = "11.56.1";
    "12" = "12.68.0";
  };

  profileCheck =
    major: env:
    let
      serviceName = "laravel${major}";
      cfg = env.config.services.laravel;
      user = env.config.hostenv.userName;
    in
    {
      "laravel-${major}-profile" = asserts.assertRun {
        name = "laravel-${major}-profile";
        inherit env;
        buildInputs = [
          pkgs.fcgi
          pkgs.jq
          pkgs.nginx
          pkgs.rsync
        ];
        script = ''
          fail() {
            printf 'Laravel ${major} fixture failed: %s\n' "$1" >&2
            exit 1
          }

          app="$profile/share/php/${serviceName}"
          project_app=$(readlink -f "$app")
          nginx_conf="$profile/etc/nginx/nginx.conf"
          units="$profile/systemd/user"
          fpm_conf="$profile/etc/php-fpm.d/${serviceName}.conf"
          fpm_unit="$units/phpfpm-${serviceName}.service"
          scheduler_unit="$units/laravel-scheduler-${serviceName}.service"

          test -f "$app/public/index.php" || fail "public/index.php was not packaged"
          grep -Fq 'hostenv generated stylesheet' "$app/public/css/hostenv.css" \
            || fail "build-time public asset package was not overlaid"
          grep -Fq 'hostenv generated script' "$app/public/js/hostenv.js" \
            || fail "build-time JavaScript asset was not overlaid"
          test -f "$app/vendor/autoload.php" || fail "Composer vendor tree was not packaged"
          test -x "$profile/bin/artisan" || fail "server-side Artisan wrapper is missing"
          test -x "$profile/bin/composer" || fail "Composer is missing from the profile"
          test -x "$profile/bin/hello" || fail "project runtime package is missing from the profile"

          test "$(readlink "$app/storage")" = ${lib.escapeShellArg cfg.storageDir} \
            || fail "storage is not linked to persistent Hostenv data"
          test "$(readlink "$app/bootstrap/cache")" = ${lib.escapeShellArg cfg.bootstrapCacheDir} \
            || fail "bootstrap/cache is not linked to persistent Hostenv cache"
          grep -Fq '${serviceName} initial storage' "$app/.hostenv-initial-storage/hostenv-fixture.txt" \
            || fail "initial storage contents were not retained for activation"

          grep -Fq 'APP_ENV="production"' "$app/.env" || fail "production APP_ENV default is missing"
          grep -Fq 'APP_DEBUG="false"' "$app/.env" || fail "production APP_DEBUG default is missing"
          grep -Fq 'APP_URL="https://${env.config.environments.main.canonicalHost}"' "$app/.env" || fail "canonical APP_URL is missing"
          grep -Fq 'LOG_CHANNEL="stderr"' "$app/.env" || fail "stderr logging default is missing"
          grep -Fq 'DB_SOCKET="${env.config.hostenv.runtimeDir}/mysql.sock"' "$app/.env" \
            || fail "MariaDB socket default is missing"
          grep -Fq 'HOSTENV_FIXTURE="non-secret"' "$app/.env" \
            || fail "additional non-secret environment value is missing"
          ${lib.optionalString cfg.redis.enable ''
            grep -Fq 'REDIS_CLIENT="phpredis"' "$app/.env" \
              || fail "PhpRedis client default is missing"
            grep -Fq 'REDIS_HOST="${env.config.services.redis.socket}"' "$app/.env" \
              || fail "Redis Unix socket default is missing"
            grep -Fq 'REDIS_PORT="0"' "$app/.env" \
              || fail "Redis TCP port was not disabled in Laravel config"
            if grep -Eq '^(CACHE_STORE|CACHE_DRIVER|SESSION_DRIVER|QUEUE_CONNECTION)="redis"$' "$app/.env"; then
              fail "enabling Redis unexpectedly changed an application driver"
            fi
          ''}
          if grep -Fq 'APP_KEY=' "$app/.env"; then
            fail "APP_KEY must not be written to the immutable generated .env"
          fi

          grep -Fq "root $project_app/public;" "$nginx_conf" || fail "nginx does not expose only public/"
          grep -Fq 'index index.php;' "$nginx_conf" || fail "Laravel front-controller index is missing"
          grep -Fq 'location = /index.php' "$nginx_conf" || fail "front controller location is missing"
          grep -Fq 'location ~ /\.(?!well-known).*' "$nginx_conf" || fail "hidden-file protection is missing"
          grep -Fq 'fastcgi_pass unix:${env.config.hostenv.runtimeDir}/${serviceName}.sock;' "$nginx_conf" \
            || fail "FastCGI Unix socket is missing"
          grep -Fq 'fastcgi_read_timeout 300s;' "$nginx_conf" \
            || fail "shared FastCGI read timeout is not 300 seconds"
          if grep -Fq "root $project_app;" "$nginx_conf"; then
            fail "nginx must never serve the Laravel project root"
          fi

          tmpdir=$(mktemp -d)
          mkdir -p "$tmpdir/logs" "$tmpdir/run"
          nginx_output=$("$profile/bin/nginx" -e "$tmpdir/error.log" -t -c "$nginx_conf" -p "$tmpdir" 2>&1 || true)
          grep -Fq 'syntax is ok' <<<"$nginx_output" || fail "nginx syntax check failed"

          grep -Fq 'clear_env = no' "$fpm_conf" || fail "PHP-FPM still clears inherited variables"
          grep -Fq 'error_log = /proc/self/fd/2' "$fpm_conf" \
            || fail "PHP-FPM main errors are not routed to the service stderr"
          grep -Fq 'php_admin_value[error_log] = /proc/self/fd/2' "$fpm_conf" \
            || fail "PHP errors are not routed to the worker stderr"
          grep -Fq 'env[PATH] = $HOSTENV_PHPFPM_PATH' "$fpm_conf" \
            || fail "PHP-FPM does not import the merged application PATH"
          grep -Fq '${pkgs.hello}/bin' "$fpm_unit" \
            || fail "project runtime package is missing from the PHP-FPM service PATH"
          grep -Fq '${pkgs.hello}/bin' "$scheduler_unit" \
            || fail "project runtime package is missing from the scheduler service PATH"
          if grep -Fq '${pkgs.hello}/bin' "$units/mysql.service"; then
            fail "project runtime package leaked into the MariaDB service PATH"
          fi
          if grep -Fq '${pkgs.hello}/bin' "$units/redis.service"; then
            fail "project runtime package leaked into the Valkey service PATH"
          fi
          grep -Fq '/bin/artisan schedule:run --no-interaction' "$scheduler_unit" \
            || fail "scheduler does not route through the tested Artisan wrapper"
          grep -Fq 'EnvironmentFile=/run/secrets/${user}/laravel_env' "$scheduler_unit" \
            || fail "scheduler does not load laravel_env"
          ${lib.optionalString (major == "12") ''
            queue_unit="$units/laravel-queue-priority-1.service"
            grep -Fq '${pkgs.hello}/bin' "$queue_unit" \
              || fail "project runtime package is missing from the queue-worker service PATH"
            grep -Fq '/bin/artisan queue:work' "$queue_unit" \
              || fail "queue worker does not route through the tested Artisan wrapper"
            grep -Fq 'EnvironmentFile=/run/secrets/${user}/laravel_env' "$queue_unit" \
              || fail "queue worker does not load laravel_env"
          ''}
          php="$profile/bin/php@${serviceName}"
          php_modules=$("$php" -m)
          for extension in bcmath curl fileinfo mbstring openssl pdo_mysql redis tokenizer xml; do
            if ! grep -Fxiq -- "$extension" <<<"$php_modules"; then
              printf '\nPHP diagnostics:\n' >&2
              printf '%s\n' '----------------' >&2
              printf 'System: %s\n' ${lib.escapeShellArg pkgs.stdenv.hostPlatform.system} >&2
              printf 'PHP executable: %s\n\n' "$php" >&2
              "$php" -v >&2 || true
              printf '\nPHP configuration:\n' >&2
              "$php" --ini >&2 || true
              printf '\nLoaded modules:\n%s\n' "$php_modules" >&2
              printf '\n' >&2
              fail "PHP extension $extension is missing"
            fi
          done

          grep -R -Fq 'EnvironmentFile=/run/secrets/${user}/laravel_env' "$units" \
            || fail "systemd services do not receive laravel_env"
          grep -R -Fq 'schedule:run --no-interaction' "$units" \
            || fail "scheduler service does not run Artisan every minute"
          grep -R -Fq 'OnCalendar=minutely' "$units" \
            || fail "scheduler timer is not configured for every minute"

          app_copy="$tmpdir/app"
          mkdir -p "$app_copy"
          rsync -a --exclude=/storage --exclude=/bootstrap/cache "$app/" "$app_copy/"
          chmod -R u+w "$app_copy"
          mkdir -p \
            "$app_copy/storage/framework/cache" \
            "$app_copy/storage/framework/sessions" \
            "$app_copy/storage/framework/views" \
            "$app_copy/storage/logs" \
            "$app_copy/bootstrap/cache"


          # Prove PHP-FPM workers receive the Hostenv-controlled application
          # PATH even if the master process starts with a hostile PATH. This is
          # the runtime behavior that EnvironmentFile=laravel_env must not undo.
          cat > "$app_copy/public/hostenv-path-test.php" <<'PHP'
<?php
file_put_contents('php://stderr', "hostenv php-fpm stderr test\n");
error_log("hostenv php error_log test");
$output = [];
$status = 0;
exec('hello', $output, $status);
http_response_code($status === 0 ? 200 : 500);
echo "status=$status\n";
echo implode("\n", $output), "\n";
echo "path=", getenv('PATH'), "\n";
PHP
          provider_path="$tmpdir/provider-bin"
          mkdir -p "$provider_path"
          fpm_test_conf="$tmpdir/phpfpm-test.conf"
          fpm_test_socket="$tmpdir/phpfpm-test.sock"
          sed \
            -e "s|^listen = .*|listen = $fpm_test_socket|" \
            "$fpm_conf" > "$fpm_test_conf"
          fpm_package=$(readlink -f "$profile/etc/php-fpm.d/${serviceName}-php")
          fpm_ini=$(readlink -f "$profile/etc/php-fpm.d/${serviceName}.ini")
          fpm_start=$(sed -n 's|^ExecStart=\([^ ]*\) .*|\1|p' "$fpm_unit")
          test -x "$fpm_start" || fail "PHP-FPM start wrapper is missing"
          PATH="$provider_path" \
            "$fpm_start" "$fpm_package/bin/php-fpm" -F -y "$fpm_test_conf" -c "$fpm_ini" \
            > "$tmpdir/phpfpm-test.stdout" 2>&1 &
          fpm_test_pid=$!
          trap 'kill "$fpm_test_pid" 2>/dev/null || true' EXIT
          for _ in $(seq 1 50); do
            [ -S "$fpm_test_socket" ] && break
            sleep 0.1
          done
          if [ ! -S "$fpm_test_socket" ]; then
            cat "$tmpdir/phpfpm-test.stdout" >&2
            fail "PHP-FPM did not create the path-test socket"
          fi
          if ! fpm_response=$(
            # cgi-fcgi forwards its environment as request parameters. Do not
            # let the check's build PATH mask the PHP-FPM worker PATH.
            ${pkgs.coreutils}/bin/env -u PATH \
            SCRIPT_FILENAME="$app_copy/public/hostenv-path-test.php" \
            SCRIPT_NAME=/hostenv-path-test.php \
            REQUEST_METHOD=GET \
            REQUEST_URI=/hostenv-path-test.php \
            SERVER_PROTOCOL=HTTP/1.1 \
            ${pkgs.fcgi}/bin/cgi-fcgi -bind -connect "$fpm_test_socket"
          ); then
            cat "$tmpdir/phpfpm-test.stdout" >&2
            fail "FastCGI request to PHP-FPM path test failed"
          fi
          grep -Fq 'status=0' <<<"$fpm_response" \
            || fail "PHP-FPM application process could not execute a declared runtime package"
          grep -Fq 'Hello, world!' <<<"$fpm_response" \
            || fail "PHP-FPM application process did not execute pkgs.hello"
          if ! grep -Fq "$provider_path" <<<"$fpm_response"; then
            printf '%s\n' "$fpm_response" >&2
            fail "PHP-FPM discarded PATH entries supplied by laravel_env"
          fi

          # PHP-FPM must carry both application stderr (Laravel's default
          # LOG_CHANNEL) and PHP's own error_log() through the FPM main log to
          # the service stderr. This is what makes both visible to
          # journalctl --user for the environment.
          for _ in $(seq 1 50); do
            if grep -Fq 'hostenv php-fpm stderr test' "$tmpdir/phpfpm-test.stdout" \
              && grep -Fq 'hostenv php error_log test' "$tmpdir/phpfpm-test.stdout"; then
              break
            fi
            sleep 0.1
          done
          if ! grep -Fq 'hostenv php-fpm stderr test' "$tmpdir/phpfpm-test.stdout"; then
            cat "$tmpdir/phpfpm-test.stdout" >&2
            fail "PHP-FPM worker stderr did not reach the service stderr"
          fi
          if ! grep -Fq 'hostenv php error_log test' "$tmpdir/phpfpm-test.stdout"; then
            cat "$tmpdir/phpfpm-test.stdout" >&2
            fail "PHP error_log() did not reach the service stderr"
          fi

          # Exercise the generated nginx and PHP-FPM configuration together.
          # Rewrite only machine-specific paths so both daemons can run inside
          # the build sandbox; retain the generated location and index rules.
          cat > "$app_copy/public/index.php" <<'PHP'
<?php
header('Content-Type: text/plain');
echo "hostenv Laravel index reached\n";
PHP
          nginx_test_conf="$tmpdir/nginx-test.conf"
          nginx_test_socket="$tmpdir/nginx-test.sock"
          nginx_test_state="$tmpdir/nginx-state"
          mkdir -p "$nginx_test_state"
          sed \
            -e "s|^pid .*|pid $tmpdir/nginx.pid;|" \
            -e "s|^error_log .*|error_log $tmpdir/nginx-error.log notice;|" \
            -e 's|access_log syslog:server=unix:/dev/log combined;|access_log off;|' \
            -e "s|${env.config.hostenv.stateDir}/nginx/|$nginx_test_state/|g" \
            -e "s|listen unix:${env.config.hostenv.upstreamRuntimeDir}/in.sock default_server;|listen unix:$nginx_test_socket default_server;|" \
            -e "s|root $project_app/public;|root $app_copy/public;|" \
            -e "s|fastcgi_pass unix:${env.config.hostenv.runtimeDir}/${serviceName}.sock;|fastcgi_pass unix:$fpm_test_socket;|" \
            "$nginx_conf" > "$nginx_test_conf"
          "$profile/bin/nginx" -c "$nginx_test_conf" -p "$tmpdir" \
            > "$tmpdir/nginx-test.stdout" 2>&1 &
          nginx_test_pid=$!
          trap 'kill "$nginx_test_pid" "$fpm_test_pid" 2>/dev/null || true' EXIT
          for _ in $(seq 1 50); do
            [ -S "$nginx_test_socket" ] && break
            sleep 0.1
          done
          if [ ! -S "$nginx_test_socket" ]; then
            cat "$tmpdir/nginx-test.stdout" >&2
            cat "$tmpdir/nginx-error.log" >&2 2>/dev/null || true
            fail "nginx did not create the Laravel HTTP test socket"
          fi
          nginx_status=$(
            ${pkgs.curl}/bin/curl \
              --silent \
              --show-error \
              --unix-socket "$nginx_test_socket" \
              --output "$tmpdir/nginx-response" \
              --write-out '%{http_code}' \
              http://localhost/
          )
          test "$nginx_status" = 200 || {
            cat "$tmpdir/nginx-response" >&2
            cat "$tmpdir/nginx-error.log" >&2 2>/dev/null || true
            fail "Laravel root returned HTTP $nginx_status instead of reaching index.php"
          }
          grep -Fq 'hostenv Laravel index reached' "$tmpdir/nginx-response" \
            || fail "Laravel root response did not come from public/index.php"
          kill "$nginx_test_pid"
          wait "$nginx_test_pid" || true
          kill "$fpm_test_pid"
          wait "$fpm_test_pid" || true
          trap - EXIT

          # Exercise the actual generated Artisan wrapper with a writable test
          # application and a laravel_env that deliberately replaces PATH. The
          # wrapper must restore Hostenv's application service PATH afterwards.
          artisan_test="$tmpdir/artisan"
          sed \
            -e "s|/run/secrets/${user}/laravel_env|$tmpdir/laravel_env|g" \
            -e "s|$project_app|$app_copy|g" \
            "$profile/bin/artisan" > "$artisan_test"
          chmod +x "$artisan_test"
          cat > "$tmpdir/laravel_env" <<EOF
APP_ENV=testing
APP_KEY=base64:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
PATH=$provider_path
EOF
          artisan_path_output=$(PATH=/also/does/not/contain/hello "$artisan_test" hostenv:path-test)
          grep -Fq 'Hello, world!' <<<"$artisan_path_output" \
            || fail "Artisan lost a declared runtime package after loading laravel_env PATH"
          grep -Fq "$provider_path" <<<"$artisan_path_output" \
            || fail "Artisan discarded PATH entries supplied by laravel_env"

          ${lib.optionalString cfg.redis.enable ''
            redis_test_dir="$tmpdir/valkey"
            redis_test_socket="$redis_test_dir/redis.sock"
            mkdir -p "$redis_test_dir"
            cat > "$redis_test_dir/valkey.conf" <<EOF
            port 0
            tls-port 0
            cluster-enabled no
            unixsocket $redis_test_socket
            unixsocketperm 700
            dir $redis_test_dir
            appendonly no
            daemonize no
            supervised no
            logfile ""
            EOF
            "$profile/bin/valkey-server" "$redis_test_dir/valkey.conf" \
              > "$redis_test_dir/valkey.log" 2>&1 &
            redis_test_pid=$!
            trap 'kill "$redis_test_pid" 2>/dev/null || true' EXIT
            for _ in $(seq 1 50); do
              [ -S "$redis_test_socket" ] && break
              sleep 0.1
            done
            if [ ! -S "$redis_test_socket" ]; then
              cat "$redis_test_dir/valkey.log" >&2
              fail "Valkey did not create the Laravel test socket"
            fi

            # Exercise the generated Laravel/PhpRedis convention through the
            # framework itself, not just the raw Redis extension. The fixture
            # copy is writable, so point only this test copy at the temporary
            # socket while preserving REDIS_CLIENT=phpredis and REDIS_PORT=0.
            sed -i "s|^REDIS_HOST=.*|REDIS_HOST=\"$redis_test_socket\"|" "$app_copy/.env"
            LARAVEL_TEST_APP="$app_copy" "$profile/bin/php@${serviceName}" -r '
              chdir(getenv("LARAVEL_TEST_APP"));
              require "vendor/autoload.php";
              $app = require "bootstrap/app.php";
              $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
              $redis = $app->make("redis")->connection();
              $redis->set("hostenv:laravel-socket-test", "ok");
              if ($redis->get("hostenv:laravel-socket-test") !== "ok") {
                  fwrite(STDERR, "Laravel Redis Unix socket round-trip failed\n");
                  exit(1);
              }
            ' || fail "Laravel could not use the Valkey Unix socket"

            "$profile/bin/valkey-cli" -s "$redis_test_socket" shutdown nosave
            wait "$redis_test_pid"
            trap - EXIT
          ''}

          version_output=$("$profile/bin/php@${serviceName}" "$app_copy/artisan" --version)
          grep -Fq 'Laravel Framework ${frameworkVersions.${major}}' <<<"$version_output" \
            || fail "Artisan did not run the pinned Laravel ${major} fixture"
          precedence_output=$(APP_ENV=provider-secret-value \
            "$profile/bin/php@${serviceName}" "$app_copy/artisan" env)
          grep -Fq 'provider-secret-value' <<<"$precedence_output" \
            || fail "an inherited provider value did not override generated .env defaults"

          # Test the security boundary by behavior, not by requiring the secret
          # check to occupy a particular textual position in the composed
          # activation script. Safe prologue code, such as the runtime-package
          # PATH setup, may run first; persistent state and services may not.
          activation_output=$(
            XDG_CONFIG_HOME="$tmpdir/config" \
            XDG_STATE_HOME="$tmpdir/state" \
            XDG_CACHE_HOME="$tmpdir/cache" \
            "$profile/bin/activate" 2>&1 && exit 99 || true
          )
          grep -Fq "/run/secrets/${user}/laravel_env" <<<"$activation_output" \
            || fail "activation did not identify the missing laravel_env secret file"
          grep -Eq "laravel_env.*provider secret|provider secret.*laravel_env" <<<"$activation_output" \
            || fail "activation did not explain how to configure the laravel_env provider secret"
          test ! -e "$tmpdir/config" || fail "activation changed services before checking laravel_env"
        '';
      };
    };

  cfg10 = envs.laravel10.config;
  cfg12 = envs.laravel12.config;
  cfgDev = envs.laravelDev.config;
  activation12 = cfg12.activate;
  backups12 = cfg12.services.restic.backups;
  queueServiceNames = builtins.filter (name: lib.hasPrefix "laravel-queue-" name) (
    builtins.attrNames cfg12.systemd.services
  );
  priorityUnit = cfg12.systemd.services."laravel-queue-priority-1";
  queueContract =
    builtins.length queueServiceNames == 3
    && lib.hasInfix "queue:work" priorityUnit.serviceConfig.ExecStart
    && lib.hasInfix "database" priorityUnit.serviceConfig.ExecStart
    && lib.hasInfix "--queue=high,default" priorityUnit.serviceConfig.ExecStart
    && lib.hasInfix "--sleep=2" priorityUnit.serviceConfig.ExecStart
    && lib.hasInfix "--timeout=75" priorityUnit.serviceConfig.ExecStart
    && lib.hasInfix "--max-time=1800" priorityUnit.serviceConfig.ExecStart
    && lib.hasInfix "--tries=5" priorityUnit.serviceConfig.ExecStart
    && priorityUnit.serviceConfig.Restart == "always"
    && priorityUnit.serviceConfig.KillSignal == "SIGTERM"
    && priorityUnit.serviceConfig.TimeoutStopSec == "120";

  laravelContractChecks = [
    {
      name = "Laravel 10 requests laravel_env";
      passed = cfg10.environments.main.requiredSecretFiles == [ "laravel_env" ];
    }
    {
      name = "Laravel 10 has no queue workers by default";
      passed =
        cfg10.services.laravel.queue.workers == { }
        && !(builtins.any (name: lib.hasPrefix "laravel-queue-" name) (
          builtins.attrNames cfg10.systemd.services
        ));
    }
    {
      name = "Laravel 12 queue worker configuration";
      passed = queueContract;
    }
    {
      name = "Laravel 12 uses socket-only MariaDB";
      passed =
        cfg12.services.mysql.settings.mysqld.skip-networking == true
        && cfg12.services.mysql.ensureDatabases == [ "laravel" ];
    }
    {
      name = "Laravel 12 enables socket-backed Valkey";
      passed =
        cfg12.services.laravel.redis.enable
        && cfg12.services.redis.enable
        && cfg12.services.redis.package == pkgs.valkey
        && cfg12.services.redis.socket == "${cfg12.hostenv.runtimeDir}/redis.sock"
        && cfg12.services.redis.appendOnly;
    }
    {
      name = "Laravel services wait for Valkey";
      passed =
        lib.elem "redis.service" cfg12.systemd.services."phpfpm-laravel12".wants
        && lib.elem "redis.service" cfg12.systemd.services."phpfpm-laravel12".after
        && lib.elem "redis.service" cfg12.systemd.services."laravel-scheduler-laravel12".wants
        && lib.elem "redis.service" cfg12.systemd.services."laravel-scheduler-laravel12".after
        && lib.elem "redis.service" priorityUnit.wants
        && lib.elem "redis.service" priorityUnit.after;
    }
    {
      name = "Valkey lifecycle checks its Unix socket";
      passed =
        lib.hasInfix cfg12.services.redis.socket cfg12.systemd.services.redis.postStart
        && lib.hasInfix cfg12.services.redis.socket cfg12.systemd.services.redis.postStop
        && lib.hasInfix "systemctl --user start redis.service" activation12;
    }
    {
      name = "Laravel backup configuration";
      passed =
        backups12 ? laravel
        && backups12 ? "laravel-migrate"
        && lib.elem "laravel-migrate" backups12."laravel-migrate".tags
        && lib.elem cfg12.services.laravel.storageDir backups12.laravel.paths;
    }
    {
      name = "Laravel restore, migration, and optimization activation";
      passed =
        lib.hasInfix "HOSTENV_RESTORE_LARAVEL_BEGIN" activation12
        && lib.hasInfix "restore_key=\"laravel-migrate\"" activation12
        && lib.hasInfix "del(.snapshots" activation12
        && lib.hasInfix "artisan migrate --force" activation12
        && lib.hasInfix "artisan optimize" activation12;
    }
    {
      name = "Laravel activation excludes APP_KEY";
      passed = !(lib.hasInfix "APP_KEY" activation12);
    }
    {
      name = "Laravel 10 default deployment health check";
      passed =
        cfg10.environments.main.deploymentVerification.checks != [ ]
        && (builtins.head cfg10.environments.main.deploymentVerification.checks).request.path == "/"
        && (builtins.head cfg10.environments.main.deploymentVerification.checks).request.virtualHost
          == cfg10.environments.main.canonicalHost;
    }
    {
      name = "Laravel 12 configured deployment health check";
      passed =
        cfg12.environments.main.deploymentVerification.checks != [ ]
        && (builtins.head cfg12.environments.main.deploymentVerification.checks).request.path == "/up"
        && (builtins.head cfg12.environments.main.deploymentVerification.checks).request.virtualHost
          == cfg12.environments.main.canonicalHost;
    }
  ];

  failedLaravelContracts = builtins.filter (check: !check.passed) laravelContractChecks;
  laravelContractFailure =
    "Laravel contracts failed:\n"
    + lib.concatMapStringsSep "\n" (check: "- ${check.name}") failedLaravelContracts;
in
profileCheck "10" envs.laravel10
// profileCheck "11" envs.laravel11
// profileCheck "12" envs.laravel12
// {
  laravel-contracts =
    asserts.assertTrue "laravel-contracts"
      (failedLaravelContracts == [ ])
      laravelContractFailure;

  laravel-development-defaults = asserts.assertRun {
    name = "laravel-development-defaults";
    env = envs.laravelDev;
    script = ''
      app="$profile/share/php/laravel12"
      grep -Fq 'APP_ENV="development"' "$app/.env"
      grep -Fq 'APP_DEBUG="true"' "$app/.env"
    '';
  };

  laravel-artisan-cli = asserts.assertRun {
    name = "laravel-artisan-cli";
    env = envs.laravel12;
    script = ''
      cli=${cfg12.hostenv.cliPackage}
      test -x "$cli/bin/hostenv"
      test -x "$cli/bin/artisan"
      grep -Fq -- '/bin/hostenv artisan -- "$@"' "$cli/bin/artisan"
      "$cli/bin/hostenv" --help > "$TMPDIR/root-help"
      grep -Fq 'Laravel:' "$TMPDIR/root-help"
      "$cli/bin/hostenv" artisan --help > "$TMPDIR/artisan-help"
      grep -Fq 'ARGUMENTS...' "$TMPDIR/artisan-help" \
        || fail "artisan should expose its pass-through arguments"
      grep -Fq 'remote_artisan+=(--no-interaction)' "$cli/bin/hostenv"
      grep -Fq 'hostenv_quote_remote_command' "$cli/bin/hostenv"
      grep -Fq 'hostenv_ssh_exec "''${remote_artisan[@]}" "$@"' "$cli/bin/hostenv"

      # Exercise the generated quoting helper with shell metacharacters that
      # must survive OpenSSH flattening argv into a remote command.
      sed -n '/hostenv_quote_remote_command() {/,/^[[:space:]]*}/p' "$cli/bin/hostenv" \
        > "$TMPDIR/hostenv-quote-function"
      . "$TMPDIR/hostenv-quote-function"
      remote_command="$(hostenv_quote_remote_command \
        artisan \
        tinker \
        '--execute=Example\Namespace\Command::run();' \
        "single quote: O'Reilly" \
        '$HOME; $(false)' \
        "")"
      EXPECTED_QUOTE="single quote: O'Reilly" \
      EXPECTED_LITERAL='$HOME; $(false)' \
      REMOTE_COMMAND="$remote_command" ${pkgs.bash}/bin/bash -c '
        set -euo pipefail
        eval "set -- $REMOTE_COMMAND"
        test "$#" -eq 6
        test "$1" = artisan
        test "$2" = tinker
        test "$3" = "--execute=Example\\Namespace\\Command::run();"
        test "$4" = "$EXPECTED_QUOTE"
        test "$5" = "$EXPECTED_LITERAL"
        test "$6" = ""
      '
    '';
  };

  laravel-secret-store-exclusion = asserts.assertRun {
    name = "laravel-secret-store-exclusion";
    env = envs.laravelSecretExclusion;
    script = ''
      app=$(readlink -f "$profile/share/php/laravelsecret")
      grep -Fq 'APP_ENV="production"' "$app/.env"
      if find "$app" -type f -exec grep -Fq \
        'hostenv-secret-must-not-enter-project-output' '{}' \; -print -quit | grep -q .; then
        echo "source .env secret leaked into the immutable Laravel project" >&2
        exit 1
      fi
      if find "$app" -type f -exec grep -Fq \
        'hostenv-local-secret-must-not-enter-project-output' '{}' \; -print -quit | grep -q .; then
        echo "source .env.local secret leaked into the immutable Laravel project" >&2
        exit 1
      fi
    '';
  };
}
