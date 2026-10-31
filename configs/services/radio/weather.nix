{
  config,
  lib,
  pkgs,
  ...
}:
let
  weather_for_ips = pkgs.writers.writePython3Bin "weather_for_ips" {
    libraries = [ pkgs.python3Packages.geoip2 ];
    flakeIgnore = [ "E501" ];
  } ./weather_for_ips.py;

  weather_report = pkgs.writers.writeDashBin "weather_report" ''
    set -efux
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ]
    }"
    curl -fSsz /tmp/GeoLite2-City.mmdb -o /tmp/GeoLite2-City.mmdb http://c.r/GeoLite2-City.mmdb
    MAXMIND_GEOIP_DB="/tmp/GeoLite2-City.mmdb"; export MAXMIND_GEOIP_DB
    (
      curl -sS 'http://admin:hackme@localhost:${toString config.lass.servicePorts.icecast}/admin/listclients.json?mount=/radio.ogg'
      curl -sS 'http://admin:hackme@localhost:${toString config.lass.servicePorts.icecast}/admin/listclients.json?mount=/radio.mp3'
      curl -sS 'http://admin:hackme@localhost:${toString config.lass.servicePorts.icecast}/admin/listclients.json?mount=/radio.opus'
    ) | jq -rs '
      [
        .[][].source|values|to_entries[].value |
        (.listener//[]) [] |
        (.useragent | capture("client-ip=(?<ip>[a-f0-9.:]+)")).ip // .ip
      ] |
        unique[] |
        select(. != "127.0.0.1") |
        select(. != "::1")
    ' |
      ${weather_for_ips}/bin/weather_for_ips
  '';
in
{
  systemd.services.weather = {
    path = [
      weather_report
      pkgs.retry
      pkgs.jq
      pkgs.curl
    ];
    script = ''
      set -xefu
      retry -t 5 -d 10 -- weather_report |
        jq \
          --arg from "$(date -u +'%FT%TZ')" \
          --arg to "$(date -u +'%FT%TZ' -d '+1 hours')" \
          --slurp --raw-input --compact-output --ascii-output \
          '{text: ., from: $from, to: $to, priority: 100}' |
        retry -t 5 -d 10 -- curl -fSs -d@- http://radio-news.r
    '';
    startAt = "*:58:00";
    serviceConfig = {
      User = "radio-news";
    };
  };
}
