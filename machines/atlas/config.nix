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
    ../../configs/bluetooth.nix
    ../../configs/network-manager.nix
    ../../configs/retiolum.nix
    ../../configs/steam.nix
    ./llm.nix
    self.wrapperModules.workspace-manager
  ];

  # the root fs is xerxes', installed with 25.05
  system.stateVersion = "25.05";

  lass.workspace-manager.enable = true;

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  # slopulus on coaxmetal manages atlas; merges with the keys from configs/default.nix
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdxrE1taDjoPXX5aoz63u9vy48avCmniEmGnkpb0y3C hermes@coaxmetal"
  ];

  # The desktop runs as a separate games user, not lass: no password (greetd
  # logs it in, there is nothing to unlock), not in wheel. It gets lass's ssh
  # keys, so `sunray games@atlas` can approve pairings in its session.
  users.users.games = {
    isNormalUser = true;
    extraGroups = [
      "audio"
      "bluetooth"
      "dialout"
      "fuse"
      "input"
      "networkmanager"
      "pipewire"
      "tor"
      "video"
    ];
    openssh.authorizedKeys.keys = config.users.users.mainUser.openssh.authorizedKeys.keys;
  };
  # Sunshine runs in the games session and reads its server key
  clan.core.vars.generators.sunshine-server.files."key.pem".owner =
    lib.mkForce config.users.users.games.name;

  # Autostart straight into sway: greetd logs the games user in on boot with no
  # prompt and execs sway (a login shell so the wrapped sway + session env from
  # programs.sway are on PATH). initial_session makes it a real user session
  # (logind class user, not greeter), so polkit treats processes of the user
  # (noctalia's shutdown button) as local and active. default_session runs
  # the same command after sway exits, so there is no greeter (that session
  # is class greeter again until the next boot).
  # Virtual screen: without any output sway aborts when a window maps (sway
  # issue 8811, TV off), and sunray needs a screen to stream.
  services.greetd =
    let
      session = {
        command = "${lib.getExe pkgs.bash} --login -c 'WLR_BACKENDS=drm,libinput,headless WLR_HEADLESS_OUTPUTS=1 sway'";
        user = config.users.users.games.name;
      };
    in
    {
      enable = true;
      settings.initial_session = session;
      settings.default_session = session;
    };
  environment.etc."sway/config.d/virtual-screen.conf".text = ''
    output HEADLESS-1 mode 1920x1080
  '';

  # Always on (home gaming/build box, LAN via the fiber card): no idle lock,
  # suspend or poweroff
  systemd.user.services.swayidle.enable = false;
  # no screen lock either: not before sleep, on loginctl lock-session or via
  # the sway lock keybindings
  lass.noctalia.settings.lockscreen.enabled = false;
}
