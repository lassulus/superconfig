{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./zigbee.nix
    ./monitoring.nix
    ./oidc.nix
  ];

  lass.ports = {
    # fixed in the home-assistant image, it runs with --network=host
    "8123" = "home-assistant";
    ${toString (lib.head config.services.mosquitto.listeners).port} = "mosquitto";
  };

  # Runs on the gg23 router: the LAN (int0) is a trusted interface there
  # (configs/gg23.nix), et0 is the WAN and stays closed.
  networking.firewall.interfaces = {
    retiolum.allowedTCPPorts = [
      config.lass.servicePorts.home-assistant
      config.lass.servicePorts.zigbee2mqtt
    ];
    wiregrill.allowedTCPPorts = [ config.lass.servicePorts.home-assistant ];
    zttzibeakb.allowedTCPPorts = [ config.lass.servicePorts.home-assistant ];
  };

  systemd.services.hass-update = {
    startAt = "daily";
    path = [ pkgs.podman ];
    script = ''
      image=${config.virtualisation.oci-containers.containers.homeassistant.image}
      podman pull "$image"
      # restart only when the running container is not on the pulled image
      if [ "$(podman inspect --format '{{.Image}}' homeassistant || true)" != "$(podman image inspect --format '{{.Id}}' "$image")" ]; then
        systemctl restart podman-homeassistant.service
      fi
      podman system prune -a --volumes -f
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
        # HA often needs more than podman's default 10 s to shut down; on
        # timeout it is SIGKILLed (exit 137, unit failed, unclean recorder DB)
        "--stop-timeout=60"
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

  environment.systemPackages = [ pkgs.mosquitto ];

  # retained messages; mosquitto.db is replaced atomically on every save
  lass.backup.state.mosquitto.folders = [ config.services.mosquitto.dataDir ];
}
