{ pkgs, lib, ... }:
let
  # qtile =
  #   (pkgs.python3.pkgs.qtile.override {
  #     pulsectl-asyncio = pkgs.python3.pkgs.pulsectl-asyncio.overrideAttrs (_oldAttrs: {
  #       postPatch = ''
  #         substituteInPlace setup.cfg --replace "pulsectl >=23.5.0,<=24.11.0" "pulsectl >=23.5.0"
  #       '';
  #     });
  #     extraPackages = [
  #       pkgs.python3.pkgs.dbus-fast
  #       pkgs.python3.pkgs.dbus-next
  #     ];
  #   }).overrideAttrs
  #     (_oldAttrs: {
  #       pname = "qtile-0.31.0";
  #       version = "0.31.0";
  #       src = pkgs.fetchFromGitHub {
  #         owner = "qtile";
  #         repo = "qtile";
  #         tag = "v0.31.0";
  #         hash = "sha256-EqrvBXigMjevPERTcz3EXSRaZP2xSEsOxjuiJ/5QOz0=";
  #       };
  #     });
  # qtile-extras = pkgs.python3.pkgs.qtile-extras.override {
  #   qtile = qtile;
  # };
  pyEnv = pkgs.python3.withPackages (p: [
    p.qtile
    # qtile-extras
    p.iwlib
    p.ipython
  ]);
in
{
  imports = [
    ../lib/wayland.nix
  ];

  environment.sessionVariables.XDG_CURRENT_DESKTOP = "qtile";
  services.greetd.enable = true;

  security.pam.services.swaylock = { };
  security.pam.services.swaylock.fprintAuth = true;

  # swaylock on lock.target (sleep, loginctl lock-session); sway machines
  # use noctalia's own lock screen instead (configs/desktops/sway/default.nix).
  # From nixpkgs/nixos/modules/services/system/systemd-lock-handler.md
  services.systemd-lock-handler.enable = true;

  systemd.user.services.swaylock = {
    description = "Screen locker for Wayland";
    documentation = [ "man:swaylock(1)" ];

    # Requires graphical session
    requisite = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];

    # If swaylock exits cleanly, unlock the session:
    onSuccess = [ "unlock.target" ];

    # When lock.target is stopped, stops this too:
    partOf = [ "lock.target" ];

    # Delay lock.target until this service is ready:
    before = [ "lock.target" ];
    wantedBy = [ "lock.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe' pkgs.swaylock-effects "swaylock";
      # If swaylock crashes, always restart it immediately:
      Restart = "on-failure";
      RestartSec = 0;
    };
  };

  # For greetd, we need a shell script into path, which lets us start qtile.service (after importing the environment of the login shell).
  services.greetd.settings.default_session.command =
    "${pkgs.tuigreet}/bin/tuigreet --remember --cmd ${pkgs.writeScript "startqtile" ''
      #! ${pkgs.bash}/bin/bash

      # first import environment variables from the login manager
      export XDG_DATA_DIRS=/run/current-system/sw/share/gsettings-schemas:$XDG_DATA_DIRS
      systemctl --user unset-environment DISPLAY WAYLAND_DISPLAY
      systemctl --user import-environment XDG_DATA_DIRS PATH
      # then start the service
      exec systemctl --user --wait start qtile.service
    ''}";

  systemd.user.targets.qtile-session = {
    description = "Qtile compositor session";
    documentation = [ "man:systemd.special(7)" ];
    bindsTo = [ "graphical-session.target" ];
    wants = [ "graphical-session-pre.target" ];
    after = [ "graphical-session-pre.target" ];
  };

  environment.systemPackages = [
    pkgs.swaylock-effects # also for the $mod+F11 binding in qtile.py
    pkgs.copyq
    (pkgs.writers.writeDashBin "qtile-debug-shell" { } ''
      ${pyEnv}/bin/ipython "$@"
    '')
  ];

  systemd.user.services.qtile = {
    description = "Qtile - Wayland window manager";
    documentation = [ "man:qtile(5)" ];
    bindsTo = [ "graphical-session.target" ];
    wants = [ "graphical-session-pre.target" ];
    after = [ "graphical-session-pre.target" ];
    # We explicitly unset PATH here, as we want it to be set by
    # systemctl --user import-environment in startqtile
    environment.PATH = lib.mkForce null;
    environment.PYTHONPATH = lib.mkForce null;
    environment.PYTHONTRACEMALLOC = "1";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pyEnv}/bin/qtile start -b wayland -c /etc/qtile.py";
      Restart = "on-failure";
      RestartSec = 1;
      TimeoutStopSec = 10;
    };
  };

  environment.etc."qtile.py".source = ./qtile.py;

  programs.xwayland.enable = true;
  environment.variables.DISPLAY = ":1";
  systemd.user.services.xwayland-satellite = {
    wantedBy = [ "graphical-session.target" ];
    after = [ "qtile.service" ];
    serviceConfig = {
      RestartSec = 5;
      Restart = "always";
      ExecStart = "${pkgs.xwayland-satellite}/bin/xwayland-satellite";
    };
  };

  systemd.user.services.copyq = {
    wantedBy = [ "graphical-session.target" ];
    after = [ "qtile.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${pkgs.copyq}/bin/copyq";
    };
  };
}
