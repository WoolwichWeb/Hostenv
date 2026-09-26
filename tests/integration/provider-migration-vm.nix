{ pkgs }:

let
  user = "acme-prod";
  uid = 2000;
  freshUser = "fresh-prod";
  freshUid = 3000;
  orphanUser = "orphan-prod";
  orphanUid = 2100;
  snapshotId = "0123456789abcdef";

  providerCliPackage = pkgs.callPackage ../../provider/package.nix {
    providerSrc = ../../provider;
    documentationEnabled = false;
  };
  cliPkg = providerCliPackage.unwrapped;

  sshOpts = [
    "-o"
    "StrictHostKeyChecking=no"
    "-o"
    "UserKnownHostsFile=/dev/null"
  ];

  movePlan = pkgs.writeText "provider-move-plan.json" (builtins.toJSON {
    hostenvHostname = "hosting.test";
    deployUser = "root";
    nodeStatus = {
      "old-node" = "retiring";
      "new-node" = "active";
    };
    nodes = {
      "old-node" = { };
      "new-node" = { };
    };
    nodeConnections = {
      "old-node" = {
        hostname = "old";
        inherit sshOpts;
      };
      "new-node" = {
        hostname = "new";
        inherit sshOpts;
      };
    };
    environments.${user} = {
      hostenv = {
        userName = user;
        runtimeDir = "/run/hostenv/user/${user}";
        hostname = "${user}.hosting.test";
      };
      inherit uid;
      node = "new-node";
      migrations = [ "demo-migrate" ];
      virtualHosts = { };
    };
  });

  moveState = pkgs.writeText "provider-move-state.json" (builtins.toJSON {
    ${user} = {
      userName = user;
      inherit uid;
      virtualHosts = [ ];
    };
  });

  freshPlan = pkgs.writeText "provider-fresh-plan.json" (builtins.toJSON {
    hostenvHostname = "hosting.test";
    deployUser = "root";
    nodeStatus."new-node" = "active";
    nodes."new-node" = { };
    nodeConnections."new-node" = {
      hostname = "new";
      inherit sshOpts;
    };
    environments.${freshUser} = {
      hostenv = {
        userName = freshUser;
        runtimeDir = "/run/hostenv/user/${freshUser}";
        hostname = "${freshUser}.hosting.test";
      };
      uid = freshUid;
      node = "new-node";
      migrations = [ "demo-migrate" ];
      virtualHosts = { };
    };
  });

  freshState = pkgs.writeText "provider-fresh-state.json" (builtins.toJSON {
    ${freshUser} = {
      userName = freshUser;
      uid = freshUid;
      virtualHosts = [ ];
    };
  });

  orphanPlan = pkgs.writeText "provider-orphan-plan.json" (builtins.toJSON {
    hostenvHostname = "hosting.test";
    deployUser = "root";
    nodeStatus."old-node" = "active";
    nodes."old-node" = { };
    nodeConnections."old-node" = {
      hostname = "old";
      inherit sshOpts;
    };
    environments = { };
  });

  orphanState = pkgs.writeText "provider-orphan-state.json" (builtins.toJSON {
    ${orphanUser} = {
      userName = orphanUser;
      uid = orphanUid;
      virtualHosts = [ ];
    };
  });

  snapshotWrapper = pkgs.writeShellScript "restic-demo-migrate" ''
    set -euo pipefail
    case " $* " in
      *" snapshots "*)
        printf '[{"id":"${snapshotId}"}]\n'
        ;;
      *)
        exit 0
        ;;
    esac
  '';

  fakeDeployNix = pkgs.writeShellScript "hostenv-provider-vm-test-nix" ''
    set -euo pipefail

    : "''${NIX_LOG:=/tmp/hostenv-provider-nix.log}"
    printf '%s\n' "$*" >> "$NIX_LOG"

    ssh_node() {
      node="$1"
      shift
      exec_ssh=(
        ${pkgs.openssh}/bin/ssh
        -o BatchMode=yes
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        "root@$node"
      )
      "''${exec_ssh[@]}" "$@"
    }

    ensure_user() {
      node="$1"
      name="$2"
      numeric_uid="$3"
      ssh_node "$node" "
        if ! getent passwd '$name' >/dev/null; then
          getent group '$name' >/dev/null || groupadd -g '$numeric_uid' '$name'
          useradd -m -u '$numeric_uid' -g '$numeric_uid' '$name'
        fi
        loginctl enable-linger '$name'
        systemctl start 'user@$numeric_uid.service'
      "
    }

    args="$*"
    case "$args" in
      *'generated/.#"new-node"."system"'*)
        case "''${FAKE_MODE:-move}" in
          move)
            ensure_user new '${user}' '${toString uid}'
            ;;
          fresh)
            ensure_user new '${freshUser}' '${toString freshUid}'
            ;;
          *)
            echo "unknown FAKE_MODE: ''${FAKE_MODE:-}" >&2
            exit 2
            ;;
        esac
        ;;

      *'generated/.#"new-node"."${user}"'*)
        if [ "''${FAIL_DEST_ENV:-0}" = 1 ]; then
          exit 41
        fi

        restore_plan="/run/hostenv/user/${user}/restore/plan.json"
        if ssh_node new "test -f '$restore_plan'"; then
          restore_json="$(ssh_node new cat "$restore_plan")"
          printf '%s\n' "$restore_json" | ${pkgs.gnugrep}/bin/grep -Fq '"sourceNode":"old-node"'
          printf '%s\n' "$restore_json" | ${pkgs.gnugrep}/bin/grep -Fq '"demo-migrate":"${snapshotId}"'

          tmp="$(${pkgs.coreutils}/bin/mktemp)"
          ${pkgs.openssh}/bin/scp \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "root@old:/home/${user}/data/sentinel.txt" "$tmp"
          ssh_node new "install -d -o '${user}' -g '${user}' '/home/${user}/data'"
          ${pkgs.openssh}/bin/scp \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$tmp" "root@new:/home/${user}/data/sentinel.txt"
          ${pkgs.coreutils}/bin/rm -f "$tmp"
          ssh_node new "
            chown '${user}:${user}' '/home/${user}/data/sentinel.txt'
            touch '/home/${user}/activated'
            chown '${user}:${user}' '/home/${user}/activated'
            rm -f '$restore_plan'
          "
        else
          ssh_node new "
            test -f '/home/${user}/activated'
            grep -qx 'hello-from-old-node' '/home/${user}/data/sentinel.txt'
          "
        fi
        ;;

      *'generated/.#"new-node"."${freshUser}"'*)
        ssh_node new "
          test \"\$(id -u '${freshUser}')\" = '${toString freshUid}'
          touch '/home/${freshUser}/activated'
          chown '${freshUser}:${freshUser}' '/home/${freshUser}/activated'
        "
        ;;

      *'generated/.#"old-node"."system"'*)
        if [ "''${FAIL_SOURCE_SYSTEM:-0}" = 1 ]; then
          exit 42
        fi
        case "''${FAKE_MODE:-move}" in
          move)
            ssh_node old "getent passwd '${user}' >/dev/null && userdel '${user}' || true"
            ;;
          orphan)
            true
            ;;
          *)
            echo "unknown FAKE_MODE for old-node system: ''${FAKE_MODE:-}" >&2
            exit 2
            ;;
        esac
        ;;

      *)
        echo "unexpected deploy-rs target: $args" >&2
        exit 2
        ;;
    esac
  '';

  fakeDig = pkgs.writeShellScript "hostenv-provider-vm-test-dig" ''
    exit 0
  '';

  commonNode = { ... }: {
    # The NixOS test framework already provisions the root account. The
    # controller installs a runtime-generated public key, so password login is
    # neither required nor desirable for these VMs.
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "prohibit-password";
    };
    security.sudo.enable = true;
    virtualisation = {
      cores = 1;
      memorySize = 768;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "provider-migration-lifecycle-vm-test";

  nodes = {
    old = { ... }: {
      imports = [ commonNode ];

      users.users.${user} = {
        isNormalUser = true;
        inherit uid;
        createHome = true;
        linger = true;
      };

      users.users.${orphanUser} = {
        isNormalUser = true;
        uid = orphanUid;
        createHome = true;
        linger = true;
      };

      systemd.user.services."restic-backups-demo-migrate" = {
        description = "Hostenv migration test backup";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
    };

    new = { ... }: {
      imports = [ commonNode ];
    };

    controller = { ... }: {
      imports = [ commonNode ];
      environment.systemPackages = [
        cliPkg
        pkgs.openssh
      ] ++ providerCliPackage.runtimeInputs;
    };
  };

  testScript = ''
    import shlex


    start_all()
    old.wait_for_unit("multi-user.target")
    new.wait_for_unit("multi-user.target")
    controller.wait_for_unit("multi-user.target")
    old.wait_for_unit("sshd.service")
    new.wait_for_unit("sshd.service")
    old.wait_for_unit("user@${toString uid}.service")
    old.wait_for_unit("user@${toString orphanUid}.service")

    with subtest("prepare controller SSH and source backup service"):
        controller.succeed(
            "install -d -m 0700 /root/.ssh /root/provider/generated /root/fake-bin"
        )
        controller.succeed(
            "${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N \"\" -f /root/.ssh/id_ed25519"
        )
        public_key = controller.succeed("cat /root/.ssh/id_ed25519.pub").strip()

        for machine in (old, new):
            machine.succeed("install -d -m 0700 /root/.ssh")
            machine.succeed(
                "printf '%s\\n' "
                + shlex.quote(public_key)
                + " > /root/.ssh/authorized_keys"
            )
            machine.succeed("chmod 0600 /root/.ssh/authorized_keys")

        controller.succeed("ln -s ${fakeDeployNix} /root/fake-bin/nix")
        controller.succeed("ln -s ${fakeDig} /root/fake-bin/dig")

        old.succeed("install -d -o ${user} -g users /home/${user}/data")
        old.succeed(
            "printf 'hello-from-old-node\\n' > /home/${user}/data/sentinel.txt"
        )
        old.succeed("chown ${user}:users /home/${user}/data/sentinel.txt")
        old.succeed("install -d -o ${user} -g users /home/${user}/.local/bin")
        old.succeed(
            "install -m 0755 -o ${user} -g users "
            "${snapshotWrapper} /home/${user}/.local/bin/restic-demo-migrate"
        )
        old.succeed("test -e /var/lib/systemd/linger/${user}")
        old.succeed("systemctl is-active --quiet user@${toString uid}.service")

    with subtest("orphaned Hostenv runtime is cleaned without passwd entry"):
        old.succeed("systemctl is-active --quiet user@${toString orphanUid}.service")
        old.succeed("test -e /var/lib/systemd/linger/${orphanUser}")
        old.succeed("userdel --force ${orphanUser}")
        old.fail("getent passwd ${orphanUser}")
        old.succeed("systemctl is-active --quiet user@${toString orphanUid}.service")
        old.succeed("test -e /var/lib/systemd/linger/${orphanUser}")

        controller.succeed("cp ${orphanPlan} /root/provider/generated/plan.json")
        controller.succeed("cp ${orphanState} /root/provider/generated/state.json")
        controller.succeed(": > /tmp/orphan-nix.log")

        orphan_command = (
            "cd /root/provider && "
            "PATH=/root/fake-bin:$PATH "
            "NIX_LOG=/tmp/orphan-nix.log "
            "FAKE_MODE=orphan "
            "${cliPkg}/bin/hostenv-provider deploy "
            "--remote-build --skip-verification"
        )
        orphan_status, orphan_output = controller.execute(orphan_command)
        print("orphan cleanup output:\\n" + orphan_output)
        assert orphan_status == 0, (
            f"orphan cleanup failed with exit {orphan_status}:\\n{orphan_output}"
        )

        old.fail("getent passwd ${orphanUser}")
        old.fail("test -e /var/lib/systemd/linger/${orphanUser}")
        old.fail("systemctl is-active --quiet user@${toString orphanUid}.service")
        old.fail("test -e /run/user/${toString orphanUid}")

    with subtest("destination activation failure leaves source recoverable"):
        controller.succeed("cp ${movePlan} /root/provider/generated/plan.json")
        controller.succeed("cp ${moveState} /root/provider/generated/state.json")
        controller.succeed(": > /tmp/move-nix.log")

        move_command = (
            "cd /root/provider && "
            "PATH=/root/fake-bin:$PATH "
            "NIX_LOG=/tmp/move-nix.log "
            "FAKE_MODE=move "
            "${cliPkg}/bin/hostenv-provider deploy "
            "--remote-build --skip-verification"
        )
        controller.fail(
            move_command.replace(
                "FAKE_MODE=move ",
                "FAKE_MODE=move FAIL_DEST_ENV=1 ",
            )
        )

        old.succeed("getent passwd ${user}")
        old.succeed("test -e /var/lib/systemd/linger/${user}")
        old.succeed("systemctl is-active --quiet user@${toString uid}.service")
        old.succeed("grep -qx 'hello-from-old-node' /home/${user}/data/sentinel.txt")
        new.succeed("test \"$(id -u ${user})\" = '${toString uid}'")
        new.succeed("test -f /run/hostenv/user/${user}/restore/plan.json")
        controller.fail(
            "grep -Fq 'generated/.#\"old-node\".\"system\"' /tmp/move-nix.log"
        )

    with subtest("accepted destination stays live while source finalization fails"):
        controller.succeed(": > /tmp/move-nix.log")
        controller.fail(
            move_command.replace(
                "FAKE_MODE=move ",
                "FAKE_MODE=move FAIL_SOURCE_SYSTEM=1 ",
            )
        )

        old.succeed("getent passwd ${user}")
        old.fail("test -e /var/lib/systemd/linger/${user}")
        old.fail("systemctl is-active --quiet user@${toString uid}.service")
        new.succeed("getent passwd ${user}")
        new.succeed("test -f /home/${user}/activated")
        new.succeed("grep -qx 'hello-from-old-node' /home/${user}/data/sentinel.txt")
        new.succeed(
            "grep -qx 'quiesced old-node' /var/lib/hostenv/provider/migration-handoffs/${toString uid}"
        )
        new.succeed(
            "test \"$(stat -c '%U:%G %a' /var/lib/hostenv/provider/migration-handoffs)\" = 'root:root 700'"
        )
        new.succeed(
            "test \"$(stat -c '%U:%G %a' /var/lib/hostenv/provider/migration-handoffs/${toString uid})\" = 'root:root 600'"
        )
        new.fail(
            "test -e /home/${user}/.local/state/hostenv/migration-handoff-source"
        )
        controller.succeed(
            "grep -Fq 'generated/.#\"old-node\".\"system\"' /tmp/move-nix.log"
        )

    with subtest("retry skips source migration and completes finalization"):
        controller.succeed(": > /tmp/move-nix.log")
        controller.succeed(move_command)

        old.fail("getent passwd ${user}")
        old.fail("test -e /var/lib/systemd/linger/${user}")
        old.fail("systemctl is-active --quiet user@${toString uid}.service")
        new.succeed("getent passwd ${user}")
        new.succeed("test -f /home/${user}/activated")
        new.succeed("grep -qx 'hello-from-old-node' /home/${user}/data/sentinel.txt")
        new.fail("test -f /run/hostenv/user/${user}/restore/plan.json")
        controller.succeed(
            "grep -Fq 'generated/.#\"old-node\".\"system\"' /tmp/move-nix.log"
        )

    with subtest("fresh migration-capable environment deploys from reservation only"):
        controller.succeed("cp ${freshPlan} /root/provider/generated/plan.json")
        controller.succeed("cp ${freshState} /root/provider/generated/state.json")
        controller.succeed(": > /tmp/fresh-nix.log")

        fresh_command = (
            "cd /root/provider && "
            "PATH=/root/fake-bin:$PATH "
            "NIX_LOG=/tmp/fresh-nix.log "
            "FAKE_MODE=fresh "
            "${cliPkg}/bin/hostenv-provider deploy "
            "--remote-build --skip-verification"
        )
        controller.succeed(fresh_command)

        new.succeed("test \"$(id -u ${freshUser})\" = '${toString freshUid}'")
        new.succeed("test -f /home/${freshUser}/activated")
        controller.succeed(
            "grep -Fq 'generated/.#\"new-node\".\"${freshUser}\"' /tmp/fresh-nix.log"
        )
        controller.succeed("test \"$(wc -l < /tmp/fresh-nix.log)\" -eq 2")
  '';
}
