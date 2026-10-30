{
  pkgs,
  config,
  self,
  ...
}:
let
  noctalia = self.packages.${pkgs.system}.noctalia;
in
{
  systemd.user.services.noctalia = {
    description = "Noctalia Shell - Wayland desktop shell";
    documentation = [ "https://docs.noctalia.dev/v5/" ];
    partOf = [ "sway-session.target" ];
    wantedBy = [ "sway-session.target" ];
    after = [ "sway-session.target" ];
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.procps
      pkgs.util-linux
      pkgs.sway
      pkgs.brightnessctl
      pkgs.pulseaudio
      pkgs.networkmanager
      pkgs.wl-clipboard
    ];
    serviceConfig = {
      ExecStart = "${noctalia}/bin/noctalia";
      Restart = "on-failure";
    };
  };

  environment.systemPackages = [
    noctalia
    # ryzenadj and power-profile for power profile control
    pkgs.ryzenadj
    self.packages.${pkgs.system}.power-profile
  ];

  # Idle inhibit service - toggled by bar button
  systemd.user.services.sway-idle-inhibit = {
    description = "Inhibit idle/sleep";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=idle:sleep --who=noctalia --why='User requested' --mode=block sleep infinity";
    };
  };

  # Allow user to run ryzenadj without password (for power profile switching)
  security.sudo.extraRules = [
    {
      users = [ config.users.users.mainUser.name ];
      commands = [
        {
          command = "/run/current-system/sw/bin/ryzenadj";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Make RAPL energy counters readable for power monitoring
  services.udev.extraRules = ''
    SUBSYSTEM=="powercap", ACTION=="add", RUN+="${pkgs.coreutils}/bin/chmod a+r /sys/class/powercap/%k/energy_uj"
  '';
}
