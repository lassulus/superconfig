# Living room TV on styx: Kodi with the Jellyfin add-on straight on DRM/GBM
# (HDMI to the TV). Its sound goes over ROC to the audio hub on acheron
# (./audio/hub.nix), which shows it as the "TV" source in Home Assistant's
# routing matrix. Home Assistant's Kodi integration talks to the web server
# (./tv-hass.nix), and tv-play (./tv-play.py) plays video links (YouTube,
# ...) it gets from there. The Jellyfin add-on is signed in as Jellyfin user
# `media` before Kodi starts; which libraries to sync is asked on the TV at
# the first start.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  jellyfin = pkgs.kodi-gbm.packages.jellyfin;
  # inputstream.adaptive plays the HLS streams from tv-play
  kodi = pkgs.kodi-gbm.withPackages (p: [
    jellyfin
    p.inputstream-adaptive
  ]);
  # Kodi adds add-ons that aren't in its own addon-manifest.xml disabled
  # (AddonDatabase.cpp, SyncInstalled), so these are switched on before every
  # start; Python modules work while disabled
  enabledAddons = [
    "plugin.video.jellyfin"
    "inputstream.adaptive"
  ];
  password = config.clan.core.vars.generators.kodi.files.password.path;
  jellyfinServer = "https://flix.lassul.us";
  jellyfinPassword = config.clan.core.vars.generators.kodi-jellyfin.files.password.path;
  # Sessions and devices in Jellyfin's dashboard show this name
  deviceName = "TV (styx)";
  # The sound reaches the speakers after two ROC hops (styx -> acheron ->
  # styx, 30 ms target latency each) plus the graph quanta and ALSA on both
  # ends, ~80 ms that Kodi can't see past the roc-tv sink. A negative
  # display latency makes Kodi show each frame that much later. Estimated,
  # not measured: tune on the TV (Kodi's per-video audio offset shows how
  # far off it is; the TV's own picture delay works against this).
  advancedSettings = pkgs.writeText "advancedsettings.xml" ''
    <advancedsettings version="1.0">
      <video>
        <latency>
          <delay>-80</delay>
        </latency>
      </video>
      <jsonrpc>
        <tcpport>${toString config.lass.servicePorts.kodi-jsonrpc}</tcpport>
      </jsonrpc>
    </advancedsettings>
  '';
in
{
  lass.ports = {
    "8082" = "kodi";
    # JSON-RPC over TCP/websocket, which Home Assistant's Kodi integration
    # uses for push updates; unauthenticated, so only acheron may connect
    "9090" = "kodi-jsonrpc";
    # tv-play, for Home Assistant on acheron
    "8083" = "tv-play";
  };

  users.users.media = {
    isSystemUser = true;
    group = "media";
    home = "/var/lib/media";
    createHome = true;
    extraGroups = [
      "video"
      "render"
      "input"
      "pipewire"
    ];
  };
  users.groups.media = { };

  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.intel-media-driver ];
  };

  # The TV (Hisense, 2015, HDMI 1.4: 4K at up to 30 Hz) is on HDMI-A-2. Kodi
  # on GBM only starts on a connected output and doesn't follow hotplug, so
  # the output is forced on with the TV's own EDID (base64 of
  # /sys/class/drm/card0-HDMI-A-2/edid) and stays up while switch.tv has the
  # TV off. Kernel parameters: takes a reboot. The EDID prefers 4K at 30 Hz,
  # Kodi runs at 1080p 60 Hz instead (videoscreen.screenmode below).
  hardware.display = {
    edid.packages = [
      (pkgs.runCommand "edid-tv" { } ''
        mkdir -p $out/lib/firmware/edid
        base64 -d > $out/lib/firmware/edid/tv.bin <<'EOF'
        AP///////wAgoy8AAQAAAAwZAQOAc0F4Cs90o1dMsCMJSEwhCACBwIFAgYABAQEBAQEBAQEBBHQA
        MPJwWoCwWIoAUB10AAAeAjqAGHE4LUBYLEUAUB10AAAeAAAA/ABISVNFTlNFCiAgICAgAAAA/QAy
        Sw9FHgAKICAgICAgAXICAzNxT19eXQECBAUQERMUHyAhIikJBwcVB1BXBwCDAQAA4gD5bQMMACAA
        ODwgAGABAgNmIVCwUQAbMEBwNgBWAFMAAB4BHYAYcRwWIFgsJQDEjiEAAJ4BHQByUdAeIG4oVQDE
        jiEAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsQ==
        EOF
      '')
    ];
    outputs."HDMI-A-2" = {
      edid = "tv.bin";
      mode = "e";
    };
  };

  # Kodi's audio, sent to the hub's roc-tv source
  services.pipewire.extraConfig.pipewire."10-tv"."context.modules" = [
    {
      name = "libpipewire-module-roc-sink";
      args = {
        # acheron on the gg23 LAN
        "remote.ip" = "10.42.0.1";
        "remote.source.port" = 10004;
        "remote.repair.port" = 10005;
        "remote.control.port" = 10006;
        "fec.code" = "disable";
        "sink.name" = "roc-tv";
        "sink.props" = {
          "node.description" = "TV to the audio hub (acheron)";
          # A network sink has no clock, and Kodi opens its stream with
          # PW_STREAM_FLAG_DRIVER (AESinkPipewire.cpp), so without a real
          # driver Kodi's stream would drive the graph but never trigger it:
          # the audio isn't consumed and the video crawls behind the stalled
          # audio clock. The dummy driver (system clock) wins on priority.
          "node.group" = "pipewire.dummy";
        };
      };
    }
  ];

  # Web server (JSON-RPC) settings and the add-on's device name are enforced
  # in Kodi's settings files before every start, the rest stays Kodi's own
  # state. The Jellyfin login only happens when the stored token is missing
  # or rejected; an unreachable server leaves everything as it is.
  # tty1 belongs to Kodi. A getty there conflicting with Kodi doesn't work:
  # every switch-to-configuration starts the getty again, which stops Kodi.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;
  systemd.services.kodi = {
    wantedBy = [
      "multi-user.target"
      "pipewire.service"
    ];
    bindsTo = [ "pipewire.service" ];
    wants = [ "network-online.target" ];
    after = [
      "pipewire.service"
      "network-online.target"
      "systemd-user-sessions.service"
    ];
    environment = {
      PIPEWIRE_RUNTIME_DIR = "/run/pipewire";
      PIPEWIRE_NODE = "roc-tv";
    };
    path = [
      pkgs.xmlstarlet
      pkgs.curl
      pkgs.jq
      pkgs.sqlite
    ];
    preStart = ''
      userdata=$HOME/.kodi/userdata
      addon=$userdata/addon_data/plugin.video.jellyfin
      setting() {
        mkdir -p "$(dirname "$1")"
        [ -e "$1" ] || echo '<settings version="2"></settings>' > "$1"
        xmlstarlet ed -L \
          -d "/settings/setting[@id='$2']" \
          -s /settings -t elem -n setting -v "$3" \
          -s '$prev' -t attr -n id -v "$2" \
          "$1"
      }
      setting "$userdata/guisettings.xml" services.webserver true
      setting "$userdata/guisettings.xml" services.webserverport ${toString config.lass.servicePorts.kodi}
      setting "$userdata/guisettings.xml" services.webserverauthentication true
      setting "$userdata/guisettings.xml" services.webserverusername kodi
      setting "$userdata/guisettings.xml" services.webserverpassword "$(cat ${password})"
      # WWWWWHHHHHRRR.RRRRR + progressive, see Kodi's DisplaySettings.cpp
      setting "$userdata/guisettings.xml" videoscreen.screenmode 0192001080060.00000pstd
      # JSON-RPC over TCP on all interfaces, not just localhost
      setting "$userdata/guisettings.xml" services.esallinterfaces true
      ln -sfn ${advancedSettings} "$userdata/advancedsettings.xml"
      # inserted when Kodi hasn't seen them yet, so they are on from their
      # first start; the database itself only exists after Kodi's first start
      for db in "$userdata"/Database/Addons*.db; do
        if [ -e "$db" ]; then
          for id in ${lib.escapeShellArgs enabledAddons}; do
            sqlite3 "$db" "INSERT INTO installed (addonID, enabled, installDate) VALUES ('$id', 1, datetime('now')) ON CONFLICT (addonID) DO UPDATE SET enabled = 1"
          done
        fi
      done
      setting "$addon/settings.xml" deviceNameOpt true
      setting "$addon/settings.xml" deviceName ${lib.escapeShellArg deviceName}
      # flix has no Kodi Sync Queue plugin; with this on, the add-on asks to
      # install it at every start. Kodi runs all the time and gets library
      # changes over the websocket.
      setting "$addon/settings.xml" kodiCompanion false
      # the add-on's device id; Jellyfin ties the token to it
      [ -s "$addon/jellyfin_guid" ] || tr -d '\n' < /proc/sys/kernel/random/uuid > "$addon/jellyfin_guid"
      # same header as the add-on (jellyfin/http.py), values URL-encoded
      auth="MediaBrowser Client=Kodi, Device=${lib.strings.escapeURL deviceName}, DeviceId=$(cat "$addon/jellyfin_guid"), Version=${jellyfin.version}"
      token=$(jq -r '.Servers[0].AccessToken // empty' "$addon/data.json" 2>/dev/null || true)
      status=
      if [ -n "$token" ]; then
        status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          -H "Authorization: $auth, Token=$token" ${jellyfinServer}/System/Info || true)
      fi
      if [ -z "$token" ] || [ "$status" = 401 ] || [ "$status" = 403 ]; then
        if public=$(curl -sf --max-time 10 ${jellyfinServer}/System/Info/Public) &&
          login=$(jq -n --rawfile pw ${jellyfinPassword} '{Username: "media", Pw: ($pw | rtrimstr("\n"))}' |
            curl -sf --max-time 10 -X POST --data-binary @- \
              -H 'Content-Type: application/json' -H "Authorization: $auth" \
              ${jellyfinServer}/Users/AuthenticateByName); then
          # what the add-on itself stores after a login (database/__init__.py)
          jq -n --argjson public "$public" --argjson login "$login" \
            --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
              Servers: [{
                Id: $public.Id,
                Name: $public.ServerName,
                address: "${jellyfinServer}",
                UserId: $login.User.Id,
                AccessToken: $login.AccessToken,
                DateLastAccessed: $date,
                Users: [{ Id: $login.User.Id, IsSignedInOffline: true }]
              }]
            }' > "$addon/data.json.tmp"
          mv "$addon/data.json.tmp" "$addon/data.json"
        else
          echo "Jellyfin login as media at ${jellyfinServer} failed, the add-on will ask on the TV" >&2
        fi
      fi
    '';
    # no logind session (no PAMName), so Kodi's power menu can't shut down
    # styx; the groups above give it the GPU, input devices and pipewire
    serviceConfig = {
      User = "media";
      ExecStart = "${kodi}/bin/kodi --standalone --audio-backend=pipewire";
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";
      Restart = "always";
      RestartSec = 2;
      # Kodi exits with 143 on SIGTERM
      SuccessExitStatus = 143;
    };
  };

  # video links from Home Assistant: yt-dlp resolves them, Kodi plays the
  # stream; yt-dlp runs here so the stream URLs fit styx's address; ffmpeg
  # joins the video and audio tracks of livestreams
  systemd.services.tv-play = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.yt-dlp
      pkgs.ffmpeg-headless
    ];
    serviceConfig = {
      ExecStart = "${
        pkgs.writers.writePython3 "tv-play" { flakeIgnore = [ "E501" ]; } ./tv-play.py
      } ${toString config.lass.servicePorts.tv-play} http://127.0.0.1:${toString config.lass.servicePorts.kodi}/jsonrpc %d/kodi-password /run/tv-play/play.m3u";
      LoadCredential = [ "kodi-password:${password}" ];
      DynamicUser = true;
      # play.m3u for Kodi (user media) to read
      RuntimeDirectory = "tv-play";
      RuntimeDirectoryMode = "0755";
      Restart = "always";
      RestartSec = 2;
    };
  };

  clan.core.vars.generators.kodi = {
    files.password.owner = "media";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/password"
    '';
  };

  clan.core.vars.generators.kodi-jellyfin = {
    prompts.password = {
      description = "Password of the Jellyfin user media (flix.lassul.us), which Kodi on styx signs in as";
      type = "hidden";
      persist = true;
    };
    files.password.owner = "media";
  };

  networking.firewall.interfaces = {
    et0.allowedTCPPorts = [ config.lass.servicePorts.kodi ];
    retiolum.allowedTCPPorts = [ config.lass.servicePorts.kodi ];
  };
  # Home Assistant on acheron (./tv-hass.nix), via the LAN
  networking.firewall.extraInputRules = ''
    iifname "et0" ip saddr 10.42.0.1 tcp dport { ${toString config.lass.servicePorts.kodi-jsonrpc}, ${toString config.lass.servicePorts.tv-play} } accept
  '';
}
