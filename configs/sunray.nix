# Host side of tools/sunray: the client runs Sunshine here over ssh.
{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.python3
    pkgs.sunshine
  ];

  # Sunshine injects mouse/keyboard through uinput; hand it to the user of the
  # active session.
  hardware.uinput.enable = true;
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
  '';
}
