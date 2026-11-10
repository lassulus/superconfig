{ pkgs, ... }:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  users.users.mainUser.extraGroups = [ "bluetooth" ];
  environment.systemPackages = [ pkgs.bluetuith ];
}
