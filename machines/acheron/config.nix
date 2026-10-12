# acheron replaces styx as the gg23 router. Like starkstrom it has no card in
# the shared kartei registry; its retiolum identity lives in retiolum/
# (self.retiolum), which every superconfig machine injects into its tinc host
# set and /etc/hosts. Move that entry into kartei/lass if the rest of krebs
# should be able to reach it too.
{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/gg23.nix
    ../../configs/hass
    ../../configs/snapserver.nix
  ];

  services.earlyoom.enable = true;

  system.stateVersion = "25.11";
}
