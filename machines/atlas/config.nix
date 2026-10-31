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
    ../../configs/retiolum.nix
    ../../configs/steam.nix
    self.wrapperModules.workspace-manager
  ];

  # the root fs is xerxes', installed with 25.05
  system.stateVersion = "25.05";

  lass.workspace-manager.enable = true;

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  # Hermes on coaxmetal manages atlas; merges with the keys from configs/default.nix
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdxrE1taDjoPXX5aoz63u9vy48avCmniEmGnkpb0y3C hermes@coaxmetal"
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

  # Power off after 10 minutes without keyboard/mouse input, load or nix
  # builds; ssh sessions don't keep it on. swayidle marks input idle after
  # a minute in %t/idle and neither locks (home gaming/build box) nor suspends
  # (that would beat the poweroff).
  systemd.user.services.swayidle.serviceConfig = {
    ExecStart = lib.mkForce ''
      ${pkgs.swayidle}/bin/swayidle -w \
        timeout 60 '${pkgs.coreutils}/bin/touch %t/idle' resume '${pkgs.coreutils}/bin/rm -f %t/idle'
    '';
    # no stale mark when swayidle dies while idle
    ExecStopPost = "${pkgs.coreutils}/bin/rm -f %t/idle";
  };
  # no screen lock either: not before sleep, on loginctl lock-session or via
  # the sway lock keybindings
  lass.noctalia.settings.lockscreen.enabled = false;
  systemd.services.idle-shutdown = {
    startAt = "minutely";
    path = [
      pkgs.gawk
      pkgs.procps
    ];
    serviceConfig = {
      RuntimeDirectory = "idle-shutdown";
      RuntimeDirectoryPreserve = true;
    };
    script = ''
      count=$(cat /run/idle-shutdown/count 2>/dev/null || echo 0)
      if ls /run/user/*/idle >/dev/null 2>&1 &&
        awk '{ exit !($2 < 0.5) }' /proc/loadavg &&
        ! pgrep -G nixbld >/dev/null; then
        count=$((count + 1))
      else
        count=0
      fi
      echo "$count" >/run/idle-shutdown/count
      if [ "$count" -ge 10 ]; then
        echo "no input, load or nix builds for $count minutes, powering off"
        systemctl poweroff
      fi
    '';
  };
}
