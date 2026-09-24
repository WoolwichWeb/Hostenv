{ pkgs }:

let
  user = "acme-prod";
  uid = 2000;
in
pkgs.testers.runNixOSTest {
  name = "provider-migration-lifecycle-vm-test";

  nodes = {
    old = { ... }: {
      users.users.${user} = {
        isNormalUser = true;
        inherit uid;
        createHome = true;
        linger = true;
      };

      environment.systemPackages = [
        pkgs.python3
      ];

      virtualisation = {
        cores = 1;
        memorySize = 768;
      };
    };

    new = { ... }: {
      environment.systemPackages = [
        pkgs.curl
      ];

      virtualisation = {
        cores = 1;
        memorySize = 768;
      };
    };
  };

  testScript = ''
    from datetime import timedelta


    start_all()
    old.wait_for_unit("multi-user.target")
    new.wait_for_unit("multi-user.target")
    old.wait_for_unit("user@${toString uid}.service")

    with subtest("source environment is live"):
        old.succeed(
            "install -d -o ${user} -g users /home/${user}/data"
        )
        old.succeed(
            "printf 'hello-from-old-node\\n' > /home/${user}/data/sentinel.txt"
        )
        old.succeed("chown ${user}:users /home/${user}/data/sentinel.txt")
        old.succeed("test -e /var/lib/systemd/linger/${user}")
        old.succeed("systemctl is-active --quiet user@${toString uid}.service")

    with subtest("copy migration payload between VMs"):
        old.succeed(
            "cd /home/${user}/data && "
            "${pkgs.python3}/bin/python -m http.server 18080 "
            "--bind 0.0.0.0 >/tmp/hostenv-migration-http.log 2>&1 "
            "& echo $! >/tmp/hostenv-migration-http.pid"
        )
        new.wait_until_succeeds(
            "${pkgs.curl}/bin/curl --fail --silent "
            "http://old:18080/sentinel.txt -o /tmp/sentinel.txt",
            timeout=timedelta(seconds=30),
        )
        new.succeed("grep -qx 'hello-from-old-node' /tmp/sentinel.txt")

    with subtest("failed destination activation keeps source recoverable"):
        # System deployment can create the destination identity before its
        # environment activation succeeds.
        new.succeed("groupadd -g ${toString uid} ${user}")
        new.succeed(
            "useradd -m -u ${toString uid} -g ${toString uid} ${user}"
        )
        new.succeed("loginctl enable-linger ${user}")
        new.succeed("systemctl start user@${toString uid}.service")

        # Deliberately fail before consuming the migration payload.
        new.fail("test -f /definitely-not-the-hostenv-activation-success-marker")

        old.succeed("getent passwd ${user}")
        old.succeed("test -e /var/lib/systemd/linger/${user}")
        old.succeed("systemctl is-active --quiet user@${toString uid}.service")
        old.succeed("grep -qx 'hello-from-old-node' /home/${user}/data/sentinel.txt")

    with subtest("retry succeeds before source finalization"):
        new.succeed("install -d -o ${user} -g ${user} /home/${user}/data")
        new.succeed("cp /tmp/sentinel.txt /home/${user}/data/sentinel.txt")
        new.succeed("chown ${user}:${user} /home/${user}/data/sentinel.txt")
        new.succeed("grep -qx 'hello-from-old-node' /home/${user}/data/sentinel.txt")

        # Only after destination activation succeeds is the source retired.
        old.succeed("loginctl disable-linger ${user}")
        old.succeed("systemctl stop user@${toString uid}.service")
        old.succeed("userdel ${user}")

        old.fail("getent passwd ${user}")
        old.fail("test -e /var/lib/systemd/linger/${user}")
        old.succeed("systemctl is-active --quiet user@${toString uid}.service || true")
        new.succeed("getent passwd ${user}")
        new.succeed("grep -qx 'hello-from-old-node' /home/${user}/data/sentinel.txt")
  '';
}
