# crit (https://crit.md): agents run `crit` to open their diff/plan for review
# in the browser and block until it is finished. Each review session is its
# own daemon on its own port, reachable over retiolum as
# http://<host>.r:<port>, and publicly as https://<id>.review.lassul.us
# through neoprism (configs/crit-proxy.nix) and the router nginx below.
#
# SECURITY: crit has no authentication, and comments left in a review are fed
# to the agent as instructions. Whoever can reach a daemon can steer an agent
# running here, so the ports are only open on retiolum. On the public side the
# random 10-char hostname (~51 bits, fresh per review, only on a wildcard cert
# so it never shows up in CT logs) is the only protection.
{
  self,
  config,
  pkgs,
  ...
}:
let
  firstPort = 7700;
  lastPort = 7719;
  # router nginx, neoprism proxies *.review.lassul.us here
  routerPort = 7720;
  domain = "review.lassul.us";
  # one file per port, "<id> <port>", written by the wrapper
  routesDir = "/var/lib/crit-routes";
  mapDir = "/run/crit-routes";
  crit-unwrapped = self.inputs.llm-agents.packages.${pkgs.system}.crit;

  # crit binds 127.0.0.1 on a random port by default. Bind all interfaces on a
  # free port from the firewalled range instead and advertise the public URL.
  # Only the invocation that starts a daemon binds the port; reconnecting to a
  # running session uses the port and URL recorded in ~/.crit/sessions.
  crit = pkgs.symlinkJoin {
    name = "crit";
    paths = [
      (pkgs.writeShellScriptBin "crit" ''
        if [ -z "''${CRIT_PORT:-}" ]; then
          for p in $(${pkgs.coreutils}/bin/seq ${toString firstPort} ${toString lastPort}); do
            if [ -z "$(${pkgs.iproute2}/bin/ss -Htln "sport = :$p")" ]; then
              export CRIT_PORT=$p
              # Fresh unguessable hostname per daemon. Replacing the port's
              # route kills the link of whichever review used the port before.
              id=$(LC_ALL=C ${pkgs.coreutils}/bin/tr -dc a-z0-9 </dev/urandom | ${pkgs.coreutils}/bin/head -c 10)
              tmp=${routesDir}/.$p.$$
              if printf '%s %s\n' "$id" "$p" >"$tmp" && ${pkgs.coreutils}/bin/mv -f "$tmp" ${routesDir}/"$p"; then
                export CRIT_PUBLIC_URL="''${CRIT_PUBLIC_URL:-https://$id.${domain}}"
              else
                ${pkgs.coreutils}/bin/rm -f "$tmp"
                echo "crit: cannot write ${routesDir} (not in group crit?), no public URL" >&2
              fi
              break
            fi
          done
        fi
        if [ -n "''${CRIT_PORT:-}" ]; then
          echo "crit: retiolum: http://${config.networking.hostName}.r:$CRIT_PORT" >&2
          export CRIT_PUBLIC_URL="''${CRIT_PUBLIC_URL:-http://${config.networking.hostName}.r:$CRIT_PORT}"
        else
          echo "crit: ports ${toString firstPort}-${toString lastPort} all busy, using a random port (not reachable over retiolum)" >&2
        fi
        export CRIT_HOST="''${CRIT_HOST:-0.0.0.0}"
        export CRIT_ALLOW_UNAUTHENTICATED_NETWORK=1
        exec ${crit-unwrapped}/bin/crit "$@"
      '')
      crit-unwrapped
    ];
  };

  # Only well-formed routes make it into the nginx config: the routes dir is
  # writable by the agent.
  crit-routes-map = pkgs.writeShellApplication {
    name = "crit-routes-map";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      routes=$1
      out=$2
      tmp=$(mktemp "$out.XXXXXX")
      for f in "$routes"/*; do
        [ -f "$f" ] || continue
        id=''' port='''
        read -r id port _ <"$f" || [ -n "$id" ] || continue
        if [[ $id =~ ^[a-z0-9]{10}$ && $port =~ ^[0-9]{4}$ ]] &&
          ((port >= ${toString firstPort} && port <= ${toString lastPort})); then
          printf '%s.${domain} %s;\n' "$id" "$port"
        fi
      done >"$tmp"
      chmod 644 "$tmp"
      mv -f "$tmp" "$out"
    '';
  };
in
{
  environment.systemPackages = [ crit ];

  users.groups.crit.members = [
    config.users.users.mainUser.name
    "hermes"
  ];
  # no sticky bit: any crit user must be able to replace another's route
  systemd.tmpfiles.rules = [ "d ${routesDir} 2770 root crit -" ];

  systemd.paths.crit-routes = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = routesDir;
  };
  systemd.services.crit-routes = {
    description = "Generate the nginx map of crit review hostnames";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p ${mapDir}
      ${pkgs.lib.getExe crit-routes-map} ${routesDir} ${mapDir}/routes.map
      systemctl try-reload-or-restart nginx.service
    '';
  };

  # Routes <id>.review.lassul.us to the daemon's port. A daemon that has gone
  # away gives 502, unknown ids 404.
  services.nginx = {
    enable = true;
    # the glob tolerates a missing file before crit-routes ran
    appendHttpConfig = ''
      map $host $crit_port {
        default "";
        include ${mapDir}/*.map;
      }
    '';
    virtualHosts.crit-routes = {
      listen = [
        {
          addr = "0.0.0.0";
          port = routerPort;
        }
        {
          addr = "[::]";
          port = routerPort;
        }
      ];
      extraConfig = ''
        if ($crit_port = "") {
          return 404;
        }
      '';
      # the UI follows the review over SSE
      locations."/" = {
        recommendedProxySettings = true;
        proxyPass = "http://127.0.0.1:$crit_port";
        extraConfig = ''
          proxy_buffering off;
          proxy_read_timeout 1h;
        '';
      };
    };
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ routerPort ];
  networking.firewall.interfaces.retiolum.allowedTCPPortRanges = [
    {
      from = firstPort;
      to = lastPort;
    }
  ];
}
