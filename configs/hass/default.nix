{ config, pkgs, ... }:
{
  imports = [
    ./zigbee.nix
  ];

  # Runs on the gg23 router: the LAN (int0) is a trusted interface there
  # (configs/gg23.nix), et0 is the WAN and stays closed.
  networking.firewall.interfaces = {
    retiolum.allowedTCPPorts = [
      8123 # hass
      1337 # zigbee2mqtt frontend
    ];
    wiregrill.allowedTCPPorts = [ 8123 ]; # hass
    zttzibeakb.allowedTCPPorts = [ 8123 ]; # hass
  };

  systemd.services.hass-update = {
    startAt = "daily";
    script = ''
      ${pkgs.podman}/bin/podman pull ${config.virtualisation.oci-containers.containers.homeassistant.image}
      systemctl restart podman-homeassistant.service
      ${pkgs.podman}/bin/podman system prune -a --volumes -f
    '';
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.homeassistant = {
      volumes = [ "home-assistant:/config" ];
      environment.TZ = "Europe/Berlin";
      image = "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
      extraOptions = [
        "--network=host"
      ];
    };
  };

  services.mosquitto = {
    enable = true;
    listeners = [
      {
        acl = [ ];
        users.gg23 = {
          acl = [ "readwrite #" ];
          password = "gg23-mqtt";
        };
      }
    ];
  };

  # used by hass via localhost only; no openFirewall, et0 is the WAN here
  services.ollama.enable = true;

  environment.systemPackages = [ pkgs.mosquitto ];
}
