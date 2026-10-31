{ config, ... }:
{
  lass.ports = {
    ${toString config.services.atuin.port} = "atuin";
    # atuin's database.createLocally
    ${toString config.services.postgresql.settings.port} = "postgresql";
  };
  services.atuin = {
    enable = true;
    host = "0.0.0.0";
    maxHistoryLength = 1000000;
    openFirewall = true;
  };

}
