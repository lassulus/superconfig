# acheron replaces styx as the gg23 router.
{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/gg23.nix
    ../../configs/hass
    ../../configs/gg23/audio/hub.nix
    ../../configs/gg23/internet.nix
    ../../configs/gg23/tv-hass.nix
    ./backup.nix
    ../../configs/gg23/wan-failover.nix
  ];

  services.earlyoom.enable = true;

  system.stateVersion = "25.11";
}
