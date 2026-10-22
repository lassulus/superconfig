{
  self,
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ../../configs
    ../../configs/desktops/sway/default.nix
    ../../configs/pipewire.nix
    ../../configs/network-manager.nix
    self.wrapperModules.workspace-manager
  ];

  # the root fs is xerxes', installed with 25.05
  system.stateVersion = "25.05";

  lass.workspace-manager.enable = true;

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  # Autostart straight into sway: greetd logs the main user in on boot with no
  # prompt and execs sway (a login shell so the wrapped sway + session env from
  # programs.sway are on PATH). default_session with a real user means every
  # (re)start goes directly into the session — there is no greeter.
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${lib.getExe pkgs.bash} --login -c sway";
      user = config.users.users.mainUser.name;
    };
  };
}
