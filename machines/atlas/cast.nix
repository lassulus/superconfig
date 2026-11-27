# Livestream of atlas' screen to https://cast.lassul.us (Owncast on
# neoprism, configs/cast.nix), switched on and off in Home Assistant
# (configs/hass/atlas-cast.nix) through atlas-cast-control.
#
# atlas has no monitor in the data center: sway shows everything on
# HEADLESS-1 (3840x2160), which has no KMS connector, so KMS capture
# (gpu-screen-recorder) sees nothing. wf-recorder grabs that output through
# wlr-screencopy, like Sunshine, as DMA-BUFs on the GPU sway renders on
# (the RX 6800 XT), and encodes H.264 there with VA-API (its VCN encoder,
# not the shader cores), so games keep the CPU. Audio is the default
# sink's monitor (Sunshine's sink, where the
# games play) of the games user's PipeWire, as AAC. RTMP goes over
# retiolum to neoprism.
{
  config,
  pkgs,
  self,
  ...
}:
let
  user = config.users.users.games;
  neoprism = self.inputs.kartei.hosts.neoprism.nets.retiolum.ip4.addr;
  # services.owncast.rtmp-port of neoprism (configs/cast.nix keeps the
  # default); not read from neoprism's config, that would evaluate it
  rtmpPort = 1935;
  port = config.lass.servicePorts.atlas-cast-control;

  # wf-recorder stamps audio by counting samples. When its audio thread
  # stalls, the lost samples shift all later audio earlier (one stall put the
  # sound 8.5 s ahead of the picture). The patch fills such gaps with silence.
  wf-recorder = pkgs.wf-recorder.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./wf-recorder-audio-gaps.patch ];
  });

  cast = pkgs.writeShellScript "atlas-cast" ''
    # the stream key ends up on the command line, readable by atlas' local
    # users
    key=$(< "$CREDENTIALS_DIRECTORY/stream-key")
    # the games session's Wayland socket and PipeWire
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    # g=60: a keyframe every second, Owncast's lowest latency level cuts
    # 1 s HLS segments and passthrough can only cut at keyframes.
    # -D: a frame every 1/60 s, not only on screen damage (constant rate
    # for viewers); the render node of the GPU sway runs on (the RX 6800
    # XT, machines/atlas/config.nix), a DMA-BUF from it can't be encoded
    # on another GPU. Resolved: wf-recorder compares the path with sway's
    # device and falls back to a broken hwupload (no DMA-BUF) when they
    # differ as strings
    exec ${wf-recorder}/bin/wf-recorder -o HEADLESS-1 -D -r 60 \
      -c h264_vaapi -d "$(readlink -f /dev/dri/by-path/pci-0000:03:00.0-render)" \
      -F scale_vaapi=w=1920:h=1080:format=nv12 \
      -p bitrate=6000k -p g=60 \
      --audio=@DEFAULT_MONITOR@ -C aac \
      -m flv -f "rtmp://${neoprism}:${toString rtmpPort}/live/$key"
  '';
in
{
  imports = [ ../../configs/atlas-cast-vars.nix ];

  lass.ports."8086" = "atlas-cast-control";
  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];

  # Owncast's stream key: its admin -> Configuration -> Server Setup ->
  # Stream Keys
  clan.core.vars.generators.atlas-cast = {
    prompts.stream-key = {
      description = "Owncast stream key for atlas' livestream to cast.lassul.us";
      type = "hidden";
      persist = true;
    };
  };

  # Off at boot (nothing wants it), started and stopped by
  # atlas-cast-control. In the games user's session: its Wayland socket
  # and its PipeWire. Retried while switched on, e.g. when sway crashes or
  # neoprism is not reachable.
  systemd.services.atlas-cast = {
    description = "Livestream of the screen to cast.lassul.us";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startLimitIntervalSec = 0;
    environment = {
      WAYLAND_DISPLAY = "wayland-1";
    };
    serviceConfig = {
      ExecStart = cast;
      User = user.name;
      LoadCredential = [
        "stream-key:${config.clan.core.vars.generators.atlas-cast.files.stream-key.path}"
      ];
      # wf-recorder finishes the stream on SIGINT
      KillSignal = "SIGINT";
      TimeoutStopSec = 10;
      Restart = "always";
      RestartSec = 5;
    };
  };

  # atlas-cast-control may start and stop atlas-cast, nothing else
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (
        action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "atlas-cast.service" &&
        (action.lookup("verb") == "start" || action.lookup("verb") == "stop") &&
        subject.user == "atlas-cast-control"
      )
        return polkit.Result.YES;
    });
  '';

  # HTTP for Home Assistant on acheron, over retiolum, with the shared
  # bearer token of configs/atlas-cast-vars.nix
  systemd.services.atlas-cast-control = {
    description = "Home Assistant's switch for the livestream to cast.lassul.us";
    wantedBy = [ "multi-user.target" ];
    path = [ config.systemd.package ];
    serviceConfig = {
      ExecStart = "${
        pkgs.writers.writePython3 "atlas-cast-control" { flakeIgnore = [ "E501" ]; } ./cast-control.py
      } ${toString port} %d/token atlas-cast.service";
      LoadCredential = [
        "token:${config.clan.core.vars.generators.atlas-cast-control.files.token.path}"
      ];
      # a fixed name for the polkit rule above
      User = "atlas-cast-control";
      Group = "atlas-cast-control";
      Restart = "always";
      RestartSec = 2;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    };
  };
  users.users.atlas-cast-control = {
    isSystemUser = true;
    group = "atlas-cast-control";
  };
  users.groups.atlas-cast-control = { };
}
