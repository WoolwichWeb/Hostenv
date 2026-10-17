# Prevent ACME / Let's Encrypt renewal services breaking deployments.
#
# This breakage happens when an ACME timer starts a certificate renewal that fails
# in the middle of a deployment. That registers as a deployment failure, and the
# deployment is rolled back.

{ config, ... }:
let
  packagesFor = config.flake.lib.hostenv.packagesFor;
in
{
  flake.modules.nixos.provider-acme =
    { config, lib, pkgs, ... }:
    let
      certs = config.security.acme.certs;
      names = builtins.attrNames certs;
      orderUnit = name: "acme-order-renew-${name}.service";
      hostEntry = cert: host: {
        ${lib.toLower (lib.removeSuffix "." host)} = [ (orderUnit cert) ];
      };
      certificateHosts = lib.concatMap
        (name: map (hostEntry name) ([ certs.${name}.domain ] ++ certs.${name}.extraDomainNames))
        names;
      nginxHosts = lib.concatLists (lib.mapAttrsToList
        (name: vhost:
          let
            serverName = if vhost.serverName == null then name else vhost.serverName;
            cert = if vhost.useACMEHost == null then serverName else vhost.useACMEHost;
          in
          lib.optionals ((vhost.enableACME || vhost.useACMEHost != null) && builtins.hasAttr cert certs)
            (map (hostEntry cert) ([ serverName ] ++ vhost.serverAliases)))
        config.services.nginx.virtualHosts);
      manifest = pkgs.writeText "acme-manifest.json" (builtins.toJSON {
        version = 1;
        units = map orderUnit names;
        unitsByHost = lib.zipAttrsWith (_: values: lib.unique (lib.concatLists values))
          (certificateHosts ++ nginxHosts);
      });
      runtime = (packagesFor pkgs).hostenv-runtime;
      acmeRuntimeDir = "${config.provider.plan.runtimeRoot}/acme";
      acmeRuntimeRule = "d ${acmeRuntimeDir} 0700 root root -";
      # On the first deployment the installed generation may have no ACME
      # tmpfiles rule yet. Bootstrap through systemd-tmpfiles before locking.
      # Later generations also install the same rule for boot and reactivation.
      runtimeTmpfiles = pkgs.writeText "hostenv-acme-tmpfiles.conf" ''
        d ${config.provider.plan.runtimeRoot} 0755 root root -
        ${acmeRuntimeRule}
      '';
      helper = pkgs.writeShellScriptBin "hostenv-acme-deploy" ''
        set -e
        if [ "''${1:-}" = run ] && [ "''${DRY_ACTIVATE:-}" != 1 ] && [ "''${BOOT:-}" != 1 ]; then
          ${config.systemd.package}/bin/systemd-tmpfiles --create ${runtimeTmpfiles}
        fi
        exec ${runtime}/bin/hostenv-system acme \
          --manifest ${manifest} --lock-file ${lib.escapeShellArg "${acmeRuntimeDir}/activation.lock"} \
          --systemctl ${config.systemd.package}/bin/systemctl "$@"
      '';
    in
    {
      system.build.hostenvAcmeDeployment = helper;
      environment.systemPackages = [ helper ];
      environment.etc."hostenv/acme-manifest.json".source = manifest;

      # ACME locking is shared across system activation and independent
      # certificate-order units, so a per-service RuntimeDirectory is unsuitable.
      systemd.tmpfiles.rules = [ acmeRuntimeRule ];

      # Certificate setup still runs during activation so nginx has certificate
      # files to load. Only the network-dependent order is skipped. The check
      # runs as root because application users must not control the lock.
      systemd.services = lib.mapAttrs'
        (name: _:
          let
            unit = orderUnit name;
          in
          lib.nameValuePair (lib.removeSuffix ".service" unit) {
            serviceConfig.ExecCondition = lib.mkBefore [
              "+${helper}/bin/hostenv-acme-deploy condition ${unit}"
            ];
          })
        certs;

      assertions = lib.concatMap (name: [
        {
          # Certificate names appear in ExecCondition arguments and the
          # manifest read by hostenv-system. Match its accepted characters;
          # in particular, '%' has special meaning to systemd.
          assertion = builtins.match "[A-Za-z0-9_.:@-]+" name != null;
          message = "Hostenv ACME certificate names must contain only letters, numbers, dots, underscores, colons, @ or hyphens. Use a simple certificate name and set its domain separately.";
        }
        {
          # Check the ACME unit layout expected by Hostenv. If nixpkgs
          # changes it, certificate orders must not bypass ExecCondition.
          assertion =
            (config.systemd.timers."acme-renew-${name}".timerConfig.Unit or null) == orderUnit name
            && (config.systemd.services.${lib.removeSuffix ".service" (orderUnit name)}.script or "") != "";
          message = "Hostenv does not recognise the ACME order service for '${name}'. Check the nixpkgs ACME integration before deploying.";
        }
      ]) names;
    };

  flake.lib.provider.guardAcmeActivation = pkgs: helper: activation:
    let
      guarded = pkgs.writeShellScript "hostenv-system-activate" ''
        # Keep the target fixed if another deployment changes the system profile
        # while this activation waits for a certificate order to finish.
        export PROFILE=${activation}
        exec ${helper}/bin/hostenv-acme-deploy run -- ${activation}/deploy-rs-activate "$@"
      '';
    in
    activation.overrideAttrs (old: {
      # Wrap the original entry point rather than copying deploy-rs's system
      # activation script. Its boot, test and dry-activation modes stay intact.
      postBuild = (old.postBuild or "") + ''
        rm "$out/deploy-rs-activate"
        ln -s ${guarded} "$out/deploy-rs-activate"
      '';
    });
}
