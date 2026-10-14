{ pkgs, self, ... }:
let
  domain = "wallpaper.lassul.us";
  port = 8477;
  stateDir = "/var/lib/wallpaper-lassul-us";
  server = self.packages.${pkgs.stdenv.hostPlatform.system}.realwallpaper-server;
in
{
  # live world map wallpapers rendered on demand (tools/realwallpaper):
  # https://wallpaper.lassul.us/?location=52.52,13.40&variant=lens
  imports = [ ./default.nix ];

  users.users.wallpaper-lassul-us = {
    isSystemUser = true;
    group = "wallpaper-lassul-us";
    home = stateDir;
  };
  users.groups.wallpaper-lassul-us = { };

  systemd.services.wallpaper-lassul-us = {
    description = "realwallpaper renders for ${domain}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # astropy wants a writable home for its config
    environment.HOME = stateDir;
    serviceConfig = {
      User = "wallpaper-lassul-us";
      Group = "wallpaper-lassul-us";
      StateDirectory = "wallpaper-lassul-us";
      ExecStart = "${server}/bin/realwallpaper-server --listen 127.0.0.1:${toString port} --state-dir ${stateDir}";
      Restart = "on-failure";
      # one 4K render peaks at a few GB; keep it from starving the host
      MemoryHigh = "6G";
      MemoryMax = "8G";
      Nice = 10;
    };
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      recommendedProxySettings = true;
      # a request for a new location waits for its render (a minute or two)
      extraConfig = ''
        proxy_read_timeout 900;
      '';
    };
  };
}
