{
  config,
  pkgs,
  self,
  ...
}:
let
  passless = self.packages.${pkgs.system}.passless;
  # hooked like the desktop's other user services: sway starts
  # sway-session.target after importing DISPLAY/WAYLAND_DISPLAY into the
  # user manager (configs/desktops/sway), qtile binds graphical-session.target
  # and imports WAYLAND_DISPLAY from its startup hook (configs/desktops/qtile)
  sway = config.programs.sway.enable;
  sessionTarget = if sway then "sway-session.target" else "graphical-session.target";
in
{
  # passless (tools/passless): virtual FIDO2 key keeping passkeys in the
  # passage store. It creates the key through /dev/uhid.
  users.users.mainUser.packages = [ passless ];

  boot.kernelModules = [ "uhid" ];
  users.groups.fido = { };
  users.users.mainUser.extraGroups = [ "fido" ];
  services.udev.extraRules = ''
    KERNEL=="uhid", GROUP="fido", MODE="0660"
  '';

  # graphical session: user-presence checks are desktop notifications and the
  # TPM PIN prompt (per decrypt) is rofi
  systemd.user.services.passless = {
    description = "passless virtual FIDO2 key (passage store)";
    wantedBy = [ sessionTarget ];
    partOf = [ sessionTarget ];
    after = [ (if sway then sessionTarget else "qtile.service") ];
    serviceConfig = {
      ExecStart = "${passless}/bin/passless";
      Restart = "on-failure";
      RestartSec = 5;
      # passless mlocks its secrets
      LimitMEMLOCK = "2M";
    };
  };
}
