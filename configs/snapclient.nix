{ config, pkgs, ... }:
{
  systemd.services.snapclient = {
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.snapcast ];
    script = "snapclient -h 10.42.0.1 --hostID ${config.networking.hostName}";
    serviceConfig = {
      DynamicUser = true;
      Group = "pipewire";
      Restart = "on-failure";
    };
  };
}
