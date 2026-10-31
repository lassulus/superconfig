{
  config,
  pkgs,
  lib,
  self,
  ...
}:
let

  term = "/run/current-system/sw/bin/kitty";

  # Unified script: switch to workspace and move it to current output
  gotoWorkspace = pkgs.writeShellApplication {
    name = "goto-workspace";
    runtimeInputs = [
      pkgs.sway
      pkgs.jq
    ];
    text = ''
      WS="$1"
      CURRENT_OUTPUT=$(swaymsg -r -t get_outputs | jq -r '.[] | select(.focused == true).name')
      swaymsg workspace "$WS"
      swaymsg move workspace to output "$CURRENT_OUTPUT"
    '';
  };

  # Switch screens by number. mod+F<n> focuses the screen bound to slot n:
  # the output assigned via mod+ctrl+F<n> while one exists (so a bound
  # screen stays reachable after hot-plug renumbering), else the nth
  # output by position (1 = primary, 2 = first secondary, ...).
  # mod+ctrl+F<n> binds the currently focused screen to slot n.
  screenSwitch = pkgs.writeShellApplication {
    name = "sway-screen-switch";
    runtimeInputs = [
      pkgs.sway
      pkgs.jq
      pkgs.coreutils
      pkgs.libnotify
    ];
    text = ''
      MARKS="$HOME/.config/sway-screen-marks"
      mkdir -p "$MARKS"

      if [ "$1" = "mark" ]; then
        SLOT="$2"
        CURRENT=$(swaymsg -r -t get_outputs | jq -r '.[] | select(.focused == true) | .name')
        if [ -n "$CURRENT" ]; then
          echo "$CURRENT" > "$MARKS/$SLOT"
          notify-send "Screen" "F$SLOT -> $CURRENT" 2>/dev/null
        fi
        exit 0
      fi

      MARKED=$(cat "$MARKS/$1" 2>/dev/null || true)

      if [ -n "$MARKED" ]; then
        swaymsg focus output "$MARKED"
        exit 0
      fi

      swaymsg -r -t get_outputs | jq -r 'sort_by(.x, .y) | .[].name' | sed -n "''${1}p" | while read -r TARGET; do
        [ -n "$TARGET" ] && swaymsg focus output "$TARGET"
      done
    '';
  };

  # mod+F<n> = switch to screen slot n, mod+ctrl+F<n> = bind current screen to slot n.
  screenBindings = lib.concatStringsSep "\n" (
    lib.map
      (n: ''
        bindsym $mod+F${toString n} exec ${lib.getExe screenSwitch} ${toString n}
        bindsym $mod+ctrl+F${toString n} exec ${lib.getExe screenSwitch} mark ${toString n}
      '')
      [
        1
        2
        3
        4
        5
        6
        7
        8
        9
      ]
  );

  # Mark a window and jump to it later, per slot. mod+ctrl+<digit> marks
  # the focused window (by container id) into that slot. mod+<digit> jumps
  # to the marked window: if its workspace is hidden it is moved to the
  # current screen, if it is shown on another screen focus switches there.
  # mod+shift+<digit> always brings the marked window's workspace to the
  # current screen. A stale mark (window closed) is dropped with a note.
  windowMark = pkgs.writeShellApplication {
    name = "sway-window-mark";
    runtimeInputs = [
      pkgs.sway
      pkgs.jq
      pkgs.coreutils
      pkgs.libnotify
    ];
    text = ''
      MARKS="$HOME/.config/sway-window-marks"
      mkdir -p "$MARKS"

      if [ "$1" = "mark" ]; then
        SLOT="$2"
        INFO=$(swaymsg -r -t get_tree | jq -r '
          [ .. | objects | select(.type == "con" and .focused == true) ]
          | .[0] // empty
          | [ .id, (.name // "unknown") ] | @tsv')
        if [ -z "$INFO" ]; then
          notify-send "Window" "no window focused" 2>/dev/null
          exit 0
        fi
        IFS=$'\t' read -r ID NAME <<< "$INFO"
        echo "$ID" > "$MARKS/$SLOT"
        notify-send "Window" "slot $SLOT: $NAME" 2>/dev/null
        exit 0
      fi

      SLOT="$1"
      ID=$(cat "$MARKS/$SLOT" 2>/dev/null || true)
      if [ -z "$ID" ]; then
        notify-send "Window" "no window in slot $SLOT" 2>/dev/null
        exit 0
      fi

      # Workspace that currently contains the marked window (empty if it died).
      WS=$(swaymsg -r -t get_tree | jq -r --argjson id "$ID" '
        . as $t
        | [ path(.. | objects | select(.id == $id)) ] | .[0] as $p
        | if $p == null then empty
          else [ range(1; ($p | length) + 1) as $i
                | $t | getpath($p[0:$i])
                | objects | select(.type == "workspace") | .name
          ] | .[0] // empty
          end')
      if [ -z "$WS" ]; then
        rm -f "$MARKS/$SLOT"
        notify-send "Window" "slot $SLOT: marked window is gone" 2>/dev/null
        exit 0
      fi

      # Screen the user is typing on, captured BEFORE the switch: switching
      # a workspace moves seat focus to the target's output, so the
      # focused output after the switch would be the wrong answer.
      CUR=$(swaymsg -r -t get_outputs | jq -r '.[] | select(.focused == true) | .name')
      # Shown on any output? A plain jump only brings the workspace when
      # it is hidden; "bring" always moves it here.
      SHOWN=$(swaymsg -r -t get_workspaces | jq -r --arg ws "$WS" '[.[] | select(.name == $ws) | .visible] | any')
      MOVE=false
      if [ $# -gt 1 ] && [ "$2" = "bring" ]; then
        MOVE=true
      elif [ "$SHOWN" != "true" ]; then
        MOVE=true
      fi
      swaymsg workspace "$WS"
      # Sway 1.12: nameless "move workspace to output <out>" moves the
      # focused (just-switched) workspace. A named first argument is
      # parsed as a container move to a workspace literally named
      # "<ws> to output <out>".
      if [ "$MOVE" = "true" ]; then
        swaymsg move workspace to output "$CUR"
      fi
      swaymsg "[con_id=$ID] focus"
    '';
  };

  # mod+<digit> = jump to window slot, mod+shift+<digit> = bring its
  # workspace here, mod+ctrl+<digit> = mark focused window into slot.
  windowBindings = lib.concatStringsSep "\n" (
    lib.map
      (n: ''
        bindsym $mod+${toString n} exec ${lib.getExe windowMark} ${toString n}
        bindsym $mod+shift+${toString n} exec ${lib.getExe windowMark} ${toString n} bring
        bindsym $mod+ctrl+${toString n} exec ${lib.getExe windowMark} mark ${toString n}
      '')
      [
        1
        2
        3
        4
        5
        6
        7
        8
        9
      ]
  );

in
{
  # Make goto-workspace available system-wide for workspace switching
  environment.systemPackages = [ gotoWorkspace ];

  # Firefox as a persistent systemd user service — starts after workspace-manager
  # so the sway rule to hide the anchor window is already registered
  systemd.user.services.firefox = {
    description = "Firefox Web Browser";
    partOf = [ "sway-session.target" ];
    wantedBy = [ "sway-session.target" ];
    after = [
      "sway-session.target"
      "workspace-manager.service"
    ];
    # Never restart on `nixos-rebuild switch` — that would kill all open
    # browser windows. A new Firefox build is only picked up at the next
    # sway session start.
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe self.packages.${pkgs.system}.firefox;
      Restart = "always";
      RestartSec = 2;
    };
  };
  imports = [
    ../lib/wayland.nix
    ./noctalia.nix
  ];
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    # Do NOT hardcode SWAYSOCK here: sway >=1.11 ignores an inherited value and
    # creates its own per-pid socket (sway-ipc.$uid.$pid.sock). Exporting a
    # fixed path baked a dead socket into the firefox/workspace-manager user
    # services, breaking all swaymsg calls (and thus tab restore). Let sway
    # advertise the real socket; the import-environment below propagates it.
  };

  # Enable realtime scheduling for sway
  security.pam.loginLimits = [
    {
      domain = "@users";
      item = "rtprio";
      type = "-";
      value = 1;
    }
  ];

  # noctalia owns the lock screen. It locks by itself before suspend (holding
  # a logind sleep-delay inhibitor until the lock is up) and on logind's Lock
  # signal (loginctl lock-session, needs XDG_SESSION_ID imported below); the
  # idle timeout and the keybindings ask it to lock over IPC.
  systemd.user.services.swayidle = {
    description = "Idle manager for Wayland";
    documentation = [ "man:swayidle(1)" ];
    partOf = [ "sway-session.target" ];
    wantedBy = [ "sway-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${pkgs.swayidle}/bin/swayidle -w \
          timeout 120 '${lib.getExe' config.lass.noctalia.package "noctalia"} msg session lock' \
          timeout 300 '${lib.getExe' pkgs.systemd "systemctl"} suspend-then-hibernate'
      '';
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  # Keep new windows on the workspace of the process that spawned them instead
  # of the focused one (sway only tracks this for its own `exec`, and only for
  # 60s).
  systemd.user.services.sway-spawn-workspace = {
    description = "Place new windows on their spawning process's workspace";
    partOf = [ "sway-session.target" ];
    wantedBy = [ "sway-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe self.packages.${pkgs.system}.sway-spawn-workspace;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  # Inhibit idle when audio is playing (prevents suspend during calls/music)
  systemd.user.services.sway-audio-idle-inhibit = {
    description = "Inhibit idle when audio is playing";
    partOf = [ "sway-session.target" ];
    wantedBy = [ "sway-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.sway-audio-idle-inhibit}/bin/sway-audio-idle-inhibit";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  systemd.user.services.sway-urgent-rumble = {
    description = "Trigger rumble on urgent windows";
    partOf = [ "sway-session.target" ];
    wantedBy = [ "sway-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "sway-urgent-rumble";
          runtimeInputs = [
            pkgs.sway
            pkgs.jq
            self.packages.${pkgs.system}.gpd-rumble
          ];
          text = ''
            # Find first force-feedback capable device
            FF_DEVICE=""
            for ev in /sys/class/input/event*; do
              if [ -f "$ev/device/capabilities/ff" ] && [ "$(cat "$ev/device/capabilities/ff")" != "0" ]; then
                FF_DEVICE="/dev/input/''${ev##*/}"
                break
              fi
            done

            if [ -z "$FF_DEVICE" ]; then
              echo "No force-feedback device found, exiting"
              exit 0
            fi

            echo "Using force-feedback device: $FF_DEVICE"

            swaymsg -t subscribe -m '["window"]' | \
            jq --unbuffered -r 'select(.change == "urgent" and .container.urgent == true) | "urgent"' | \
            while read -r _; do
              gpd-rumble 200 100 "$FF_DEVICE" &
            done
          '';
        }
      );
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  environment.etc."sway/config".text = ''
    # Default config for sway
    #
    # Copy this to ~/.config/sway/config and edit it to your liking.
    #
    # Read `man 5 sway` for a complete reference.

    ### Variables
    #
    # Logo key. Use Mod1 for Alt.
    set $mod Mod4
    # Home row direction keys, like vim
    set $left h
    set $down j
    set $up k
    set $right l
    # Your preferred terminal emulator
    set $term ${term}
    # Your preferred application launcher
    # Note: pass the final command to swaymsg so that the resulting window can be opened
    # on the original workspace that the command was run on.
    set $menu ${pkgs.dmenu}/bin/dmenu_path | menu | xargs swaymsg exec --

    ### Output configuration
    #
    # Default wallpaper (more resolutions are available in @datadir@/backgrounds/sway/)
    # output * bg @datadir@/backgrounds/sway/Sway_Wallpaper_Blue_1920x1080.png fill
    #
    # Example configuration:
    #
    #   output HDMI-A-1 resolution 1920x1080 position 1920,0
    #
    # You can get the names of your outputs by running: swaymsg -t get_outputs

    # Per-machine output overrides (scale, resolution, position) live here.
    include /etc/sway/config.d/*.conf

    ### Idle configuration
    #
    # Example configuration:
    #
    # exec swayidle -w \
    #          timeout 300 'swaylock -f -c 000000' \
    #          timeout 600 'swaymsg "output * power off"' resume 'swaymsg "output * power on"' \
    #          before-sleep 'swaylock -f -c 000000'
    #
    # This will lock your screen after 300 seconds of inactivity, then turn off
    # your displays after another 300 seconds, and turn your screens back on when
    # resumed. It will also lock your screen before your computer goes to sleep.

    ### Input configuration
    #
    # Example configuration:
    #
      input "2321:21128:HTIX5288:00_0911:5288_Touchpad" {
          tap enabled
      }
      input "2362:628:PIXA3854:00_093A:0274_Touchpad" {
          tap enabled
          click_method clickfinger
      }
    #
    # You can get the names of your inputs by running: swaymsg -t get_inputs
    # Read `man 5 sway-input` for more information about this section.

    ### Key bindings
    #
    # Basics:
    #
        # Start a terminal
        bindsym $mod+Shift+Return exec $term

        # Kill focused window
        bindsym $mod+Shift+c kill

        # Start your launcher
        bindsym $mod+d exec $menu

        # Drag floating windows by holding down $mod and left mouse button.
        # Resize them with right mouse button + $mod.
        # Despite the name, also works for non-floating windows.
        # Change normal to inverse to use left mouse button for resizing and right
        # mouse button for dragging.
        floating_modifier $mod normal

        # Reload the configuration file
        bindsym $mod+Shift+r reload

        # Exit sway (logs you out of your Wayland session)
        bindsym $mod+Shift+e exec swaynag -t warning -m 'You pressed the exit shortcut. Do you really want to exit sway? This will end your Wayland session.' -B 'Yes, exit sway' 'swaymsg exit'
    #
    # Moving around:
    #
        # Move your focus around
        bindsym $mod+Left focus left
        bindsym $mod+Down focus down
        bindsym $mod+Up focus up
        bindsym $mod+Right focus right

        # Move the focused window with the same, but add Shift
        bindsym $mod+Shift+Left move left
        bindsym $mod+Shift+Down move down
        bindsym $mod+Shift+Up move up
        bindsym $mod+Shift+Right move right
    # Layout stuff:
    #
        # Split bindings removed to avoid accidental sub-containers.
        # Use $mod+w to flatten into tabs, $mod+e to toggle split direction.
        bindsym $mod+n split none

        # Switch the current container between different layout styles
        bindsym $mod+s layout stacking
        bindsym $mod+w layout tabbed
        bindsym $mod+e layout toggle split

        # Make the current focus fullscreen
        bindsym $mod+f fullscreen

        # Toggle the current focus between tiling and floating mode
        bindsym $mod+Shift+space floating toggle

        # Swap focus between the tiling area and the floating area
        bindsym $mod+a focus mode_toggle

        # Workspace manager menu
        bindsym $mod+space exec ${lib.getExe self.packages.${pkgs.system}.workspace-menu}

        # Move focus to the parent container
        bindsym $mod+Shift+a focus parent
    #
    # Scratchpad:
    #
        # Sway has a "scratchpad", which is a bag of holding for windows.
        # You can send windows there and get them back later.

        # Move the currently focused window to the scratchpad
        bindsym $mod+Shift+minus move scratchpad

        # Show the next scratchpad window or hide the focused scratchpad window.
        # If there are multiple scratchpad windows, this command cycles through them.
        bindsym $mod+minus scratchpad show
    #
    # Resizing containers:
    #
    mode "resize" {
        # left will shrink the containers width
        # right will grow the containers width
        # up will shrink the containers height
        # down will grow the containers height
        bindsym $left resize shrink width 10px
        bindsym $down resize grow height 10px
        bindsym $up resize shrink height 10px
        bindsym $right resize grow width 10px

        # Ditto, with arrow keys
        bindsym Left resize shrink width 10px
        bindsym Down resize grow height 10px
        bindsym Up resize shrink height 10px
        bindsym Right resize grow width 10px

        # Return to default mode
        bindsym Return mode "default"
        bindsym Escape mode "default"
    }
    bindsym $mod+r mode "resize"

    default_border pixel 1
    default_floating_border none
    smart_borders on

    bindsym $mod+q exec ${pkgs.writers.writeDash "goto_workspace" ''
      set -efux
      WS=$(swaymsg -r -t get_workspaces |
        jq -r '.[].name' |
        menu -p 'Workspace name: '
      )
      if [ -n "$WS" ]; then
        ${lib.getExe gotoWorkspace} "$WS"
      fi
    ''}

    bindsym $mod+Shift+q exec ${pkgs.writers.writeDash "moveto_workspace" ''
      set -efux
      WS=$(swaymsg -r -t get_workspaces |
        jq -r '.[].name' |
        menu -p 'Workspace name: '
      )
      if [ -n "$WS" ]; then
        swaymsg move container to workspace "$WS"
      fi
    ''}

    bindsym $mod+y exec /run/current-system/sw/bin/switch-theme toggle

    bindsym $mod+Tab exec ${pkgs.sway-overfocus}/bin/sway-overfocus split-rw group-rw split-dw group-dw
    bindsym $mod+Escape workspace back_and_forth

    # Screen switching: mod+F<n> jumps to screen n (1 = primary, 2 = first
    # secondary, ...), mod+ctrl+F<n> marks the current screen as the target.
    # While a mark exists, any mod+F<n> jumps to the marked screen.
    ${screenBindings}

    # Window marks: mod+<digit> jumps to the window marked into that slot,
    # mod+shift+<digit> brings its workspace to the current screen,
    # mod+ctrl+<digit> marks the focused window into that slot.
    ${windowBindings}

    # screenlock (noctalia's lock screen)
    bindsym $mod+F11 exec ${lib.getExe' config.lass.noctalia.package "noctalia"} msg session lock
    bindsym $mod+l exec ${lib.getExe' config.lass.noctalia.package "noctalia"} msg session lock

    # kill window (xkill-like)
    mode "kill" {
        bindsym --whole-window button1 kill, mode "default"
        bindsym --whole-window button2 mode "default"
        bindsym --whole-window button3 mode "default"
        bindsym Escape mode "default"
    }
    bindsym $mod+x mode "kill"

    # media buttons
    bindsym XF86AudioMute exec ${pkgs.pulseaudio.out}/bin/pactl -- set-sink-mute @DEFAULT_SINK@ toggle
    bindsym XF86AudioRaiseVolume exec ${pkgs.pulseaudio.out}/bin/pactl -- set-sink-volume @DEFAULT_SINK@ +4%
    bindsym XF86AudioLowerVolume exec ${pkgs.pulseaudio.out}/bin/pactl -- set-sink-volume @DEFAULT_SINK@ -4%

    # brightness keys
    bindsym --locked XF86MonBrightnessDown exec brightnessctl set 5%-
    bindsym --locked XF86MonBrightnessUp exec brightnessctl set 5%+

    # background programs
    exec ${pkgs.copyq}/bin/copyq --start-server
    exec ydotoold
    exec_always pkill kanshi; exec ${pkgs.kanshi}/bin/kanshi


    # theme and env specific stuff
    exec_always ${pkgs.writers.writeDash "dbus-sway-environment" ''
      set -efux
      # XDG_SESSION_TYPE=wayland must be exported here: with DISPLAY set but
      # XDG_SESSION_TYPE unset, Firefox (and other apps) started from the systemd
      # user manager pick the X11/XWayland screencast path, which captures a black
      # screen under sway. Setting it explicitly makes them use the PipeWire portal.
      dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP=sway XDG_SESSION_TYPE=wayland
      systemctl --user set-environment XDG_SESSION_TYPE=wayland
      systemctl --user import-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP XDG_SESSION_ID
      systemctl --user start --no-block sway-session.target
      systemctl --user stop xdg-desktop-portal xdg-desktop-portal-wlr
      systemctl --user start xdg-desktop-portal xdg-desktop-portal-wlr
    ''}

    exec_always ${pkgs.writers.writeDash "gsettings" ''
      set -efux
      export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}:$XDG_DATA_DIRS
      gnome_schema=org.gnome.desktop.interface
      gsettings set $gnome_schema gtk-theme 'adw-gtk3-dark'
    ''}

    # keyboard
    input type:keyboard {
      xkb_layout us
      xkb_variant altgr-intl
      xkb_options caps:hyper
    }

    # Hide the workspace-manager Firefox anchor window. Registered statically
    # here (not just by the daemon at runtime) so the rule exists before the
    # firefox.service starts, otherwise the anchor flashes onto the current
    # workspace and gets captured as a phantom tab.
    for_window [title="^workspace-anchor"] move scratchpad

    # flameshot
    for_window [app_id="flameshot"] border pixel 0, floating enable, fullscreen disable, move absolute position 0 0
    exec ${pkgs.flameshot}/bin/flameshot
  '';

}
