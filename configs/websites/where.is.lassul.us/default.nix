{ config, pkgs, ... }:
let
  domain = "where.is.lassul.us";
  # home-assistant on acheron, reached over retiolum (same as hass/proxy.nix).
  hass = "http://acheron.r:8123";
  entity = "person.lass";
  stateDir = "/var/lib/where-lassul-us";

  leaflet = pkgs.fetchzip {
    url = "https://registry.npmjs.org/leaflet/-/leaflet-1.9.4.tgz";
    hash = "sha256-zzU1O3AxsGn+r3/iL7GJr+LAjLozP0NaJ5DXnZvpllI=";
  };

  webroot = pkgs.runCommand "${domain}-webroot" { } ''
    mkdir -p $out/leaflet
    cp ${./index.html} $out/index.html
    cp ${./at.html} $out/at.html
    cp ${./maps.js} $out/maps.js
    cp ${./maps.css} $out/maps.css
    cp ${leaflet}/dist/leaflet.js ${leaflet}/dist/leaflet.css $out/leaflet/
    cp -r ${leaflet}/dist/images $out/leaflet/images
  '';

  # Pull the last 24h of ${entity} from the hass history API and boil it down
  # to [{t, lat, lon, acc}] for the page. hass returns every state write
  # (~1000/day), so consecutive identical coordinates are collapsed.
  fetch = pkgs.writeShellApplication {
    name = "where-lassul-us-fetch";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      since=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
      curl -fsS \
        -H "Authorization: Bearer $(cat "$CREDENTIALS_DIRECTORY/token")" \
        "${hass}/api/history/period/$since?filter_entity_id=${entity}&significant_changes_only=0" \
      | jq -c '
          .[0]
          | map(select(.attributes.latitude != null))
          | map({
              t: .last_updated,
              lat: .attributes.latitude,
              lon: .attributes.longitude,
              acc: .attributes.gps_accuracy,
              state: .state
            })
          | reduce .[] as $p ([];
              if length > 0 and .[-1].lat == $p.lat and .[-1].lon == $p.lon
              then .[:-1] + [$p]
              else . + [$p]
              end)
          | { updated: (now | todate), points: . }
        ' > "${stateDir}/location.json.tmp"
      mv "${stateDir}/location.json.tmp" "${stateDir}/location.json"
    '';
  };
in
{
  imports = [ ../default.nix ];

  clan.core.vars.generators.where-lassul-us = {
    files.token = { };
    prompts.token = {
      description = ''
        home-assistant long-lived access token (profile -> security ->
        long-lived access tokens) with read access to ${entity}.
      '';
      type = "hidden";
      persist = true;
    };
    script = ''
      tr -d '\n' < "$prompts/token" > "$out/token"
    '';
  };

  # Static user rather than DynamicUser: the latter hides StateDirectory under
  # /var/lib/private (0700), which nginx cannot traverse.
  users.users.where-lassul-us = {
    isSystemUser = true;
    group = "where-lassul-us";
  };
  users.groups.where-lassul-us = { };

  systemd.services.where-lassul-us-fetch = {
    description = "fetch ${entity} trail from home-assistant for ${domain}";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    startAt = "*:0/2";
    serviceConfig = {
      Type = "oneshot";
      User = "where-lassul-us";
      Group = "where-lassul-us";
      StateDirectory = "where-lassul-us";
      StateDirectoryMode = "0755";
      UMask = "0022";
      LoadCredential = [ "token:${config.clan.core.vars.generators.where-lassul-us.files.token.path}" ];
      ExecStart = "${fetch}/bin/where-lassul-us-fetch";
    };
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    root = webroot;
    # share landing page: /at#LAT,LON[@UNIXTIME]
    locations."= /at".tryFiles = "/at.html =404";
    locations."= /location.json".extraConfig = ''
      alias ${stateDir}/location.json;
      default_type application/json;
      add_header Cache-Control "no-cache";
    '';
  };
}
