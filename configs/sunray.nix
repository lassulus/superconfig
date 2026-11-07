# Host side of tools/sunray: Sunshine runs in the sway session, and
# `sunray-pin` approves a client's PIN through Sunshine's local API, so only
# clients that can ssh in get paired.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = config.lass.servicePorts;
  password = "\${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunray-password";

  sunray-pin = pkgs.writeShellApplication {
    name = "sunray-pin";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      # usage: sunray-pin <pin> <client name>
      api() {
        printf 'user = "sunray:%s"\n' "$(cat "${password}")" |
          curl -sfk -K - "https://127.0.0.1:${toString ports.sunshine-web}/api/pin" "$@"
      }
      # wait for the client's `moonlight pair` to reach Sunshine; the newest
      # pending request is ours
      until id=$(api | jq -er '.pairings[-1].id'); do
        sleep 0.5
      done
      if ! api --json "$(jq -nc --arg id "$id" --arg pin "$1" --arg name "$2" \
        '{pairing_id: $id, pin: $pin, name: $name}')" | jq -e .status >/dev/null; then
        # a pending request blocks the next attempt until it is cancelled
        api -X DELETE --json "$(jq -nc --arg id "$id" '{pairing_id: $id}')" >/dev/null || true
        echo "sunray-pin: pairing failed" >&2
        exit 1
      fi
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

  # Only what pairing and streaming need; the web UI stays local.
  networking.firewall.allowedTCPPorts = [
    ports.sunshine-https
    ports.sunshine
    ports.sunshine-rtsp
  ];
  networking.firewall.allowedUDPPorts = [
    ports.sunshine-video
    ports.sunshine-control
    ports.sunshine-audio
  ];

  environment.systemPackages = [ sunray-pin ];

  services.sunshine = {
    enable = true;
    # started with sway-session.target below instead
    autoStart = false;
    settings = {
      capture = "wlr";
      origin_web_ui_allowed = "pc";
      lan_encryption_mode = 2;
      wan_encryption_mode = 2;
    };
    applications.apps = [
      {
        name = "Desktop";
        image-path = "desktop.png";
      }
    ];
  };

  systemd.user.services.sunshine = {
    # sway only reaches this target after importing WAYLAND_DISPLAY/SWAYSOCK
    wantedBy = [ "sway-session.target" ];
    partOf = [ "sway-session.target" ];
    after = [ "sway-session.target" ];
    # API credentials for sunray-pin, created once
    preStart = ''
      if [ ! -s "${password}" ]; then
        pw=$(${pkgs.coreutils}/bin/head -c 24 /dev/urandom | ${pkgs.coreutils}/bin/base64)
        ${lib.getExe config.services.sunshine.package} --creds sunray "$pw"
        (umask 077 && printf '%s\n' "$pw" > "${password}")
      fi
    '';
  };

  # Sunshine injects mouse/keyboard through uinput; hand it to the user of the
  # active session.
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
  '';
}
