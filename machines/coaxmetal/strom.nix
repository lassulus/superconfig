{
  config,
  pkgs,
  ...
}:
let
  mainUser = config.users.extraUsers.mainUser;

  # Run the launcher + games from the on-disk strom checkout at
  # /home/strom/strom when it exists, else the public github flake (see the
  # STROM_FLAKE selection in strom-session below).
  #
  # Compositor: sway (wlroots) via greetd autologin - NOT cage, and NOT an outer
  # gamescope session. Each game still brings its own gamescope, nested ONCE
  # inside sway.
  #
  # Why sway and not cage: a game's nested gamescope prefers its WAYLAND backend,
  # which needs wlroots protocols that cage (a minimal kiosk compositor) does not
  # expose. Under cage gamescope's wayland backend fails ("Couldn't create
  # Wayland objects") and silently falls back to its SDL backend, whose Vulkan
  # swapchain remake loops and aborts on this RADV RENOIR iGPU
  # (rendervulkan.cpp vulkan_remake_swapchain) - that is what crashed Baba Is You
  # a couple seconds in. sway exposes those protocols, so gamescope inits its
  # wayland backend and never touches the crashing SDL path. (An outer gamescope
  # session instead double-nests gamescope-in-gamescope, which is worse.)
  # Keeping per-game gamescope preserves render resolution/scaling, the in-game
  # exit chord, and bare-tty portability - hence no STROM_NO_GAMESCOPE.
  strom-session = pkgs.writeShellScript "strom-session" ''
    set -u
    # xpadneo owns the Xbox pad's hidraw node, so force SDL (pygame launcher and
    # the games) to read the pad through evdev instead of its HIDAPI backend -
    # same fix as configs/steam.nix, without it SDL finds no controller.
    export SDL_JOYSTICK_HIDAPI_XBOX=0
    # SDL's udev-monitor hotplug does not deliver in this kiosk session, so a pad
    # powered on after the launcher starts is never seen. Force SDL to poll
    # /dev/input instead, which reliably picks up pads as they connect/disconnect.
    export SDL_JOYSTICK_DISABLE_UDEV=1
    # In the kiosk the launcher window may not report input focus, and SDL
    # suppresses joystick (not keyboard) events while unfocused - so allow
    # joystick events regardless of focus.
    export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
    # Resolve the strom flake once: prefer the on-disk checkout at
    # /home/strom/strom (edit + test there before pushing to github), and fall
    # back to the public flake when it is absent. The launcher runs from this
    # ref, and pkgs/launcher resolves each game's ref from STROM_FLAKE too (it
    # sets the default with := so this export wins).
    if [ -d /home/strom/strom ]; then
      STROM_FLAKE=/home/strom/strom
    else
      STROM_FLAKE=github:kraftwerk-gaming/strom
    fi
    export STROM_FLAKE
    # strom-run (the per-game supervisor) needs a delegated cgroup v2 so it can
    # mkdir a child cgroup and cgroup.kill the game tree atomically. The greetd
    # PAM session drops us into a root-owned logind session scope
    # (user-1011.slice/session-cN.scope) that is NOT delegated, so strom-run dies
    # with "could not create cgroup (Permission denied)" and the game never
    # launches. Re-parent into a delegated transient scope under the user manager
    # (user@UID.service, which logind DOES delegate). Wait for the user bus first:
    # on boot the PAM session opens slightly before the user manager's bus socket.
    rd="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    for _ in $(seq 1 50); do
      [ -S "$rd/bus" ] && break
      sleep 0.2
    done
    # Relaunch whenever the couch launcher exits (gamepad B / Esc) so the kiosk
    # never drops to a blank screen. The loop runs inside the delegated scope so
    # every game inherits a writable cgroup; sway stays up (the launcher is just
    # one of its clients) across relaunches.
    #
    # setpriv --ambient-caps=-all: the login session may carry an ambient
    # capability (e.g. cap_wake_alarm) that every child inherits. bwrap refuses
    # to start when it sees capabilities in its permitted set without being
    # setuid ("Unexpected capabilities but not setuid, old file caps config?"),
    # which instant-crashes every sandboxed game. Drop the ambient set for the
    # whole launcher tree so bwrap (and thus each game) starts clean.
    exec ${pkgs.systemd}/bin/systemd-run --user --scope -p Delegate=yes \
      --quiet --collect -- \
      ${pkgs.util-linux}/bin/setpriv --ambient-caps=-all \
      ${pkgs.bash}/bin/bash -c 'while true; do
        ${config.nix.package}/bin/nix run "$STROM_FLAKE#scripts.launcher"
        sleep 2
      done'
  '';

  # Bare wlroots kiosk: no window chrome, every toplevel fullscreen, no idle
  # blanking. Its whole reason to exist over cage is that it exposes the wlroots
  # protocols each game's nested gamescope needs for its wayland backend (see
  # the top-of-file note).
  sway-kiosk = pkgs.writeText "sway-kiosk.conf" ''
    default_border none
    default_floating_border none
    gaps inner 0
    gaps outer 0
    # Fullscreen every toplevel: the launcher grid and each game's gamescope.
    for_window [app_id=".*"] fullscreen enable
    for_window [class=".*"] fullscreen enable
    # No swaybar / no swayidle -> no bar, no DPMS blank (mains-powered kiosk).
    exec ${strom-session}
  '';
in
{
  # Dedicated, unprivileged kiosk user. Gamepad input comes through evdev
  # (input group), audio through the system-wide pipewire socket (pipewire
  # group), and the games need video/audio like any local player.
  users.users.strom = {
    isNormalUser = true;
    extraGroups = [
      "video"
      "audio"
      "input"
      "pipewire"
    ];
  };

  # Let the main user become `strom` without a password. Everything that makes
  # this kiosk a kiosk belongs to that account and is unreachable from outside
  # it: sway owns seat0, XDG_RUNTIME_DIR is 0700, the pad's evdev nodes are
  # ACL'd to strom (js0 alone is world-readable, and SDL2 does not use it), and
  # /home/strom holds both the game state and the /home/strom/strom checkout the
  # launcher resolves STROM_FLAKE from. So testing a game the way a player
  # actually meets it - on the TV, with the pad - means being strom.
  security.sudo.extraConfig = ''
    ${mainUser.name} ALL=(strom) NOPASSWD: ALL
  '';

  # Kiosk autostart: greetd autologins the strom user on tty1 into sway, which
  # runs the couch launcher as its sole fullscreen client. default_session
  # re-runs the same session if sway ever exits.
  services.greetd = {
    enable = true;
    settings =
      let
        session = {
          command = "${pkgs.sway}/bin/sway --config ${sway-kiosk}";
          user = "strom";
        };
      in
      {
        initial_session = session;
        default_session = session;
      };
  };

  # The panel comes up at ~1% backlight, unreadable for a couch setup. Ship
  # brightnessctl + its udev rules (chgrp backlight to the video group, g+w) so
  # any video-group user (strom, lass) can adjust it without root, e.g.
  # `brightnessctl set 100%` / `brightnessctl set 50%`.
  environment.systemPackages = [
    pkgs.brightnessctl
  ];
  services.udev.packages = [ pkgs.brightnessctl ];

  # Force the backlight to maximum on every boot. Ordered after
  # systemd-backlight, which would otherwise restore the last (dim) saved level.
  systemd.services.max-brightness = {
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-backlight@backlight:amdgpu_bl1.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.brightnessctl}/bin/brightnessctl set 100%";
    };
  };
}
