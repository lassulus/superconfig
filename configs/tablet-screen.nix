# Android tablet as a wireless external screen.
#
# A sway headless output is streamed to Moonlight by Sunshine: hardware H.264/
# HEVC/AV1 over UDP, i.e. the game streaming path, ~1 frame of latency on LAN.
# The output exists but stays disabled until a client streams: Sunshine's
# prep-cmd enables it at exactly the resolution/refresh rate the client asks
# for (so pixels map 1:1) and disables it afterwards, which makes sway evacuate
# its workspace back to the real screens.
#
# Touch as a touchpad: Moonlight's "Use the touchscreen as a trackpad" sends
# relative mouse motion, which Sunshine injects through uinput, so dragging
# anywhere on the tablet moves the (single, shared) cursor like a touchpad.
# native_pen_touch is disabled below so absolute touch is never negotiated
# instead.
#
# One-time setup per host:
#   sunshine --creds <user> <password>   # or set them in the web UI
#   open https://<host>:47990, "PIN" page, enter the PIN Moonlight shows
#
# For the least judder, use 5 GHz, keep tablet and host on the same AP, and in
# Moonlight pick HEVC with frame pacing on "Prefer lowest latency". Streaming
# jitter is dominated by the tablet's radio, not by which host NIC is used.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  workspace = "tablet";

  tablet-screen = pkgs.writeShellApplication {
    name = "tablet-screen";
    runtimeInputs = [
      pkgs.sway
      pkgs.jq
    ];
    text = ''
      # wlroots names headless outputs HEADLESS-<n> in creation order and never
      # reuses a name, so the name we get depends on what else created one
      # first. Reserve one per session and remember which it is; the state lives
      # in the runtime dir, so it disappears together with the sway session that
      # owns the output.
      state=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tablet-screen.output

      # sway >=1.11 creates a per-pid IPC socket, and the systemd user manager
      # has not necessarily imported SWAYSOCK yet when sunshine starts or runs a
      # prep-cmd, so find the live socket ourselves.
      if ! swaymsg -t get_version >/dev/null 2>&1; then
        for sock in /run/user/"$(id -u)"/sway-ipc.*.sock; do
          if SWAYSOCK=$sock swaymsg -t get_version >/dev/null 2>&1; then
            export SWAYSOCK=$sock
            break
          fi
        done
      fi

      names() {
        swaymsg -r -t get_outputs | jq -c '[.[].name]'
      }

      exists() {
        names | jq -e --arg o "$1" 'index($o)' >/dev/null
      }

      reserve() {
        if [ -s "$state" ] && exists "$(cat "$state")"; then
          return 0
        fi
        before=$(names)
        swaymsg -- create_output >/dev/null
        output=$(names | jq -r --argjson before "$before" '(. - $before)[0] // empty')
        if [ -z "$output" ]; then
          echo "tablet-screen: sway created no headless output" >&2
          return 1
        fi
        printf '%s\n' "$output" > "$state"
        # Keep the tablet on its own workspace so it never steals a numbered one.
        swaymsg "workspace ${workspace} output $output" >/dev/null
        swaymsg "output $output disable" >/dev/null
      }

      target() {
        reserve
        cat "$state"
      }

      case "''${1-}" in
        reserve)
          reserve
          ;;
        name)
          target
          ;;
        on)
          shift
          # Sunshine exports the client's stream request; a resolution given on
          # the command line wins so the screen can also be used by hand.
          res=''${SUNSHINE_CLIENT_WIDTH:-1920}x''${SUNSHINE_CLIENT_HEIGHT:-1200}
          fps=''${SUNSHINE_CLIENT_FPS:-60}
          scale=1
          while [ $# -gt 0 ]; do
            case $1 in
              --mode)
                res=''${2%%@*}
                [ "''${2#*@}" = "$2" ] || fps=''${2#*@}
                shift 2
                ;;
              --scale)
                scale=$2
                shift 2
                ;;
              *)
                echo "tablet-screen: unknown option $1" >&2
                exit 1
                ;;
            esac
          done
          output=$(target)
          # No position: sway appends an unpositioned output to the right of
          # every other one, which keeps the existing screens (and the order
          # sway-screen-switch counts in) exactly where they are.
          swaymsg "output $output enable mode ''${res}@''${fps}Hz scale $scale" >/dev/null
          ;;
        off)
          # Disable instead of unplug: sway moves the workspace back to a real
          # screen, and the output keeps its name for the next stream.
          if [ -s "$state" ] && exists "$(cat "$state")"; then
            swaymsg "output $(cat "$state") disable" >/dev/null
          fi
          ;;
        status)
          if ! { [ -s "$state" ] && exists "$(cat "$state")"; }; then
            echo "no virtual screen reserved"
            exit 0
          fi
          swaymsg -r -t get_outputs | jq -r --arg o "$(cat "$state")" '
            .[] | select(.name == $o)
            | if .active then
                "\(.name) active \(.current_mode.width)x\(.current_mode.height)@\((.current_mode.refresh / 1000) | floor) scale=\(.scale) position=\(.rect.x),\(.rect.y)"
              else
                "\(.name) disabled"
              end
          '
          ;;
        *)
          echo "usage: tablet-screen reserve|name|on [--mode WxH[@FPS]] [--scale S]|off|status" >&2
          exit 1
          ;;
      esac
    '';
  };

  appsFile = (pkgs.formats.json { }).generate "sunshine-apps.json" {
    env = { };
    apps = [
      {
        name = "Tablet screen";
        prep-cmd = [
          {
            do = "${lib.getExe tablet-screen} on";
            undo = "${lib.getExe tablet-screen} off";
          }
        ];
        auto-detach = "true";
      }
      {
        # Same screen rendered at 1.5x, for reading size on a ~10" panel while
        # still encoding (and displaying) native pixels.
        name = "Tablet screen (HiDPI)";
        prep-cmd = [
          {
            do = "${lib.getExe tablet-screen} on --scale 1.5";
            undo = "${lib.getExe tablet-screen} off";
          }
        ];
        auto-detach = "true";
      }
    ];
  };

  settingsFile = (pkgs.formats.keyValue { }).generate "sunshine.conf" {
    sunshine_name = config.networking.hostName;
    # wlr-screencopy, unlike the kms backend, can also capture an output that
    # has no CRTC behind it - which is exactly what a headless output is.
    capture = "wlr";
    # Make Moonlight emulate a mouse rather than negotiating absolute touch,
    # so the touchscreen acts as a touchpad on the shared cursor.
    native_pen_touch = "disabled";
    file_apps = "${appsFile}";
  };

  # output_name has to be known when sunshine starts, but the headless output's
  # name is only decided when it is created, so reserve it here and pass the
  # name as a command line override (any config key can be overridden that way).
  # Running through the capability wrapper gives sunshine CAP_SYS_NICE for its
  # EGL capture context.
  sunshine-tablet-screen = pkgs.writeShellApplication {
    name = "sunshine-tablet-screen";
    runtimeInputs = [ tablet-screen ];
    text = ''
      output=$(tablet-screen name)
      exec ${config.security.wrapperDir}/sunshine ${settingsFile} "output_name=$output"
    '';
  };
in
{
  lass.ports =
    let
      # offsets from the base port, as in nixpkgs' sunshine firewall rules
      port = offset: toString (config.services.sunshine.settings.port + offset);
    in
    {
      ${port (-5)} = "sunshine-https";
      ${port 0} = "sunshine";
      ${port 1} = "sunshine-web";
      ${port 9} = "sunshine-video";
      ${port 10} = "sunshine-control";
      ${port 11} = "sunshine-audio";
      ${port 13} = "sunshine-mic";
      ${port 21} = "sunshine-rtsp";
    };

  environment.systemPackages = [ tablet-screen ];

  services.sunshine = {
    enable = true;
    openFirewall = true;
    # Started with sway-session.target below instead, which sway only reaches
    # after importing WAYLAND_DISPLAY/SWAYSOCK into the user manager.
    autoStart = false;
    # Not for KMS capture (unused): this is what makes the module build a
    # capability wrapper, whose capability set is replaced below.
    capSysAdmin = true;
  };

  # CAP_SYS_NICE lets sunshine put its EGL capture context on a high priority
  # GPU queue; CAP_SYS_ADMIN would only be needed for KMS capture.
  security.wrappers.sunshine.capabilities = lib.mkForce "cap_sys_nice+p";

  systemd.user.services.sunshine = {
    wantedBy = [ "sway-session.target" ];
    partOf = [ "sway-session.target" ];
    after = [ "sway-session.target" ];
    # Fails while sway is not up yet (no IPC socket to create the output on);
    # the module's Restart=on-failure retries until the session exists.
    serviceConfig.ExecStart = lib.mkForce (lib.getExe sunshine-tablet-screen);
  };

  # Mouse/keyboard injection goes through /dev/uinput; hand it to the user of
  # the active session (hardware.uinput, pulled in by services.sunshine, only
  # sets up the uinput group).
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
  '';
}
