{ pkgs, acmeModule, hostenvTopLevelModule, guardAcmeActivation, deploy-rs }:
let
  domain = "guard.example.test";
  order = "acme-order-renew-${domain}.service";
  fakeLego = pkgs.writeShellScriptBin "lego" ''
    # The ACME service and its sandbox are real. Only the external certificate
    # authority is replaced, so this test never contacts Let's Encrypt.
    printf 'attempt\n' >> /var/lib/acme/${domain}/attempts
    exit 10
  '';
  certificateConfig = { lib, pkgs, ... }: {
    services.nginx = {
      enable = true;
      virtualHosts.${domain} = {
        enableACME = true;
        forceSSL = true;
        locations."/".return = "200 'ready'";
      };
    };
    security.acme = {
      acceptTerms = true;
      defaults.email = "admin@example.test";
    };
    systemd.services."acme-order-renew-${domain}" = {
      # Put the fake ACME client first without dropping the commands in the
      # NixOS-generated service path (including findutils).
      path = lib.mkBefore [ fakeLego ];
      serviceConfig = {
        Restart = lib.mkForce "on-failure";
        RestartSec = lib.mkForce "1h";
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "provider-acme-vm-test";
  nodes.machine = { config, lib, pkgs, ... }: {
    # Include the real provider runtime-root tmpfiles rule, even with no
    # customer environments configured.
    imports = [ acmeModule hostenvTopLevelModule ];
    virtualisation.memorySize = 1024;
    specialisation.withCertificate.configuration = certificateConfig;
    specialisation.broken.configuration = {
      imports = [ certificateConfig ];
      systemd.services.unrelated-failure = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/false";
        };
      };
    };
    environment.systemPackages = [ pkgs.curl ];

    # This profile uses the same wrapper as provider.deployOutputs. It targets
    # the certificate specialisation without changing the boot configuration.
    environment.etc = lib.mkIf (config.specialisation != { }) {
      "hostenv-test/acme-profile".source = config.system.build.acmeTestProfile;
    };
    system.build.acmeTestProfile = lib.mkIf (config.specialisation != { }) (guardAcmeActivation pkgs
      config.specialisation.withCertificate.configuration.system.build.hostenvAcmeDeployment
      (deploy-rs.lib.${pkgs.stdenv.hostPlatform.system}.activate.nixos {
        config = config.specialisation.withCertificate.configuration;
      }));
  };
  testScript = ''
    import shlex

    start_all()
    machine.wait_for_unit("multi-user.target")
    original = machine.succeed("readlink -f /run/current-system").strip()
    new_system = original + "/specialisation/withCertificate"
    broken_system = original + "/specialisation/broken"
    profile = machine.succeed("readlink -f /etc/hostenv-test/acme-profile").strip()
    helper = "/run/current-system/sw/bin/hostenv-acme-deploy"
    attempts = "/var/lib/acme/${domain}/attempts"
    order = "${order}"

    with subtest("new certificate is skipped during a real system switch"):
        machine.succeed("test ! -e " + attempts)
        machine.succeed("test -d /run/hostenv/acme")
        machine.succeed("test \"$(stat -c %a /run/hostenv/acme)\" = 700")
        # Simulate the first deployment from a generation without the ACME
        # tmpfiles rule. The wrapper must prepare the directory before switch.
        machine.succeed("rmdir /run/hostenv/acme")
        # Hold the lock after switching so assertions cannot race its release.
        # The transient systemd-run service has no guaranteed shell PATH, so
        # use store paths for commands executed after the switch.
        machine.succeed(
            "cat > /tmp/guarded-switch <<'SH'\n"
            "set -eu\n"
            + shlex.quote(new_system + "/bin/switch-to-configuration") + " test\n"
            "${pkgs.coreutils}/bin/touch /run/switch-finished\n"
            "while test ! -e /run/release-switch; do ${pkgs.coreutils}/bin/sleep 0.1; done\n"
            "SH"
        )
        machine.succeed(
            "systemd-run --unit=guarded-switch " + helper
            + " run -- ${pkgs.bash}/bin/bash /tmp/guarded-switch"
        )
        # Stop waiting if the background switch failed, and include its status
        # in the failure instead of only timing out on a missing marker.
        machine.wait_until_succeeds(
            "test -e /run/switch-finished || "
            "systemctl is-failed --quiet guarded-switch.service"
        )
        machine.succeed(
            "test -e /run/switch-finished || "
            "{ systemctl status guarded-switch.service --no-pager; exit 1; }"
        )
        machine.succeed("systemctl is-active nginx.service")
        machine.succeed("test \"$(stat -c %a /run/hostenv/acme)\" = 700")
        machine.succeed("test -s /var/lib/acme/${domain}/fullchain.pem")
        machine.succeed("test ! -e " + attempts)
        machine.succeed("test \"$(systemctl show -p Result --value " + order + ")\" = exec-condition")
        machine.fail("systemctl is-failed --quiet " + order)
        machine.succeed("curl --silent --fail --insecure --resolve ${domain}:443:127.0.0.1 https://${domain}/ | grep ready")
        machine.succeed("touch /run/release-switch")
        machine.wait_until_succeeds("test -s " + attempts)
        machine.wait_until_succeeds("test \"$(systemctl show -p SubState --value " + order + ")\" = auto-restart")
        machine.succeed("systemctl is-active acme-renew-${domain}.timer")

    with subtest("retry runs immediately rather than waiting for the failure delay"):
        before = int(machine.succeed("wc -l < " + attempts))
        machine.succeed(helper + " retry ${domain}")
        machine.wait_until_succeeds("test $(wc -l < " + attempts + ") -gt " + str(before))
        machine.wait_until_succeeds("test \"$(systemctl show -p SubState --value " + order + ")\" = auto-restart")

    with subtest("the real deploy-rs entry point guards another activation"):
        # A caller's profile path must not change the wrapper's target generation.
        machine.succeed("PROFILE=" + shlex.quote(original) + " TEST=1 " + shlex.quote(profile + "/deploy-rs-activate"))
        machine.succeed(helper + " condition")
        machine.succeed("systemctl is-active nginx.service")
        machine.wait_until_succeeds("test \"$(systemctl show -p SubState --value " + order + ")\" = auto-restart")

    with subtest("unrelated service failure is still fatal"):
        machine.fail(helper + " run -- " + shlex.quote(broken_system + "/bin/switch-to-configuration") + " test")
        machine.succeed(helper + " condition")
        machine.succeed("systemctl is-failed --quiet unrelated-failure.service")

    with subtest("rollback removes the certificate without leaving a held lock"):
        machine.succeed(helper + " run -- " + shlex.quote(original + "/bin/switch-to-configuration") + " test")
        machine.succeed(helper + " condition")
        machine.succeed("test \"$(systemctl show -p LoadState --value " + order + ")\" = not-found")
  '';
}
