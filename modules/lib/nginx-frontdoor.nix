{ ... }:
let
  mkNodeNginxConfig =
    { lib
    , envs
    , runtimeRoot
    , defaultEnableLetsEncrypt
    , mkDefault ? (x: x)
    }:
    let
      enabledEnvs = lib.filterAttrs (_: env: env.enable != false) envs;

      sanitizeHeaderValue = label: value:
        if value == null then null else
        if lib.strings.hasInfix "\"" value then
          builtins.throw "${label} may not contain double quotes."
        else
          value;

      mkHeaderLine = name: value:
        if value == null then ""
        else
          let
            hasDouble = lib.strings.hasInfix "\"" value;
            hasSingle = lib.strings.hasInfix "'" value;
            quote =
              if hasDouble && !hasSingle then "'"
              else if hasDouble && hasSingle then
                builtins.throw "${name} header value may not contain both single and double quotes."
              else
                "\"";
          in
          ''add_header ${name} ${quote}${value}${quote} always;'';

      mkSecurityHeaders = { vhost, envType, tlsEnabled }:
        let
          referrerPolicy = vhost.security.referrerPolicy or "strict-origin-when-cross-origin";
          xFrameOptions = vhost.security.xFrameOptions or "SAMEORIGIN";
          xContentTypeOptions = vhost.security.xContentTypeOptions or true;
          reportTo = vhost.security.reportTo or null;
          hstsEnabled = vhost.security.hsts && tlsEnabled;
          cspBase = sanitizeHeaderValue "security.csp" (vhost.security.csp or null);
          cspReportTo = vhost.security.cspReportTo or null;
          cspValue =
            if cspBase == null then null else
            let trimmed = lib.strings.removeSuffix ";" cspBase;
            in
            if cspReportTo == null then
              trimmed
            else
              "${trimmed}; report-to ${cspReportTo}";
          cspHeaderName =
            if (vhost.security.cspMode or "enforce") == "report-only" then
              "Content-Security-Policy-Report-Only"
            else
              "Content-Security-Policy";
          allowIndexing = vhost.allowIndexing or (envType == "production");
        in
        lib.concatStringsSep "\n" (lib.filter (line: line != "") [
          (mkHeaderLine "Report-To" reportTo)
          (mkHeaderLine "Referrer-Policy" referrerPolicy)
          (if xFrameOptions == null then "" else mkHeaderLine "X-Frame-Options" xFrameOptions)
          (if xContentTypeOptions then mkHeaderLine "X-Content-Type-Options" "nosniff" else "")
          (if hstsEnabled then mkHeaderLine "Strict-Transport-Security" "max-age=63072000; includeSubDomains; preload" else "")
          (if cspValue == null then "" else mkHeaderLine cspHeaderName cspValue)
          (if allowIndexing then "" else mkHeaderLine "X-Robots-Tag" "noindex")
        ]);

      mkUpstream = envName: env:
        let
          user = env.hostenv.userName or envName;
          socket = (env.hostenv.upstreamRuntimeDir or "${runtimeRoot}/nginx/${user}") + "/in.sock";
        in
        {
          servers = { "unix:${socket}" = { }; };
        };

      vhostFromEnv = envName: env:
        let
          user = env.hostenv.userName or envName;
          primary = env.hostenv.hostname or user;
          normalizeVhost = vhostName: vhost:
            let
              enableLetsEncrypt =
                vhost.enableLetsEncrypt
                  or (if vhostName == primary then defaultEnableLetsEncrypt else false);
              headerConfig = mkSecurityHeaders
                {
                  vhost = vhost;
                  envType = env.type;
                  # The only TLS/SSL supported right now is Let's Encrypt, this will change in future.
                  tlsEnabled = enableLetsEncrypt;
                };
            in
            (builtins.removeAttrs vhost [
              "enableLetsEncrypt"
              "enableACME"
              "allowIndexing"
              "canonical"
              "security"
              "hsts"
            ]) // {
              enableACME = mkDefault enableLetsEncrypt;
              forceSSL = mkDefault enableLetsEncrypt;
              extraConfig = lib.concatStringsSep "\n" (lib.filter (line: line != "") [
                (vhost.extraConfig or "")
                headerConfig
              ]);
              locations = (
                if (vhost.globalRedirect or null) == null then {
                  "/" = {
                    recommendedProxySettings = true;
                    proxyPass = "http://${user}_upstream";
                  };
                } else { }
              ) // (vhost.locations or { });
            } // lib.optionalAttrs (vhostName == primary) {
              http2 = true;
            };

          addPrimary = (env.virtualHosts or { }) // {
            ${primary} = (env.virtualHosts or { }).${primary} or { };
          };
        in
        lib.mapAttrs normalizeVhost addPrimary;
    in
    {
      networking.firewall.allowedTCPPorts = [ 80 443 22 ];

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        virtualHosts =
          (lib.foldl' lib.recursiveUpdate { }
            (
              lib.mapAttrsToList
                (n: env: vhostFromEnv (env.hostenv.userName or n) env)
                enabledEnvs
            ))
          // {
            default = {
              serverName = "_";
              default = true;
              rejectSSL = true;
              locations."/".return = "444";
            };
          };
        upstreams = lib.listToAttrs (lib.mapAttrsToList
          (n: env:
            let user = env.hostenv.userName or n;
            in {
              name = "${user}_upstream";
              value = mkUpstream n env;
            })
          enabledEnvs);
      };
    };
in
{
  flake.lib.hostenv.nginxFrontdoor = {
    inherit mkNodeNginxConfig;
  };
}
