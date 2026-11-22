# The browser-sessions gateway and the session units it starts. Session i
# runs in browser-session@i.service: Xorg (neko's dummy setup), pulseaudio,
# openbox, Firefox with the browser-mcp extension, neko and browser-mcp's
# HTTP server, as a dynamic user whose home is the unit's private /tmp, so
# systemd deletes the profile when the session stops.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.browser-sessions;
  packages = self.packages.${pkgs.stdenv.hostPlatform.system};
  neko = packages.neko;

  firefox = pkgs.wrapFirefox pkgs.firefox-devedition-unwrapped {
    nativeMessagingHosts = [ packages.browser-mcp ];
    extraPolicies = {
      Extensions.Install = [ "${packages.browser-mcp-extension}/browser-mcp@lassul.us.xpi" ];
      DisableAppUpdate = true;
      DisableFirefoxStudies = true;
      DisableTelemetry = true;
      DontCheckDefaultBrowser = true;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
    };
    extraPrefs = ''
      // the extension is unsigned
      lockPref("xpinstall.signatures.required", false);
      lockPref("browser.aboutwelcome.enabled", false);
      lockPref("browser.tabs.closeWindowWithLastTab", false);
      lockPref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
    '';
  };

  # every normal window maximized and undecorated, like neko's firefox image
  openboxConfig = pkgs.writeText "openbox.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_config xmlns="http://openbox.org/3.4/rc">
      <applications>
        <application type="normal">
          <decor>no</decor>
          <maximized>true</maximized>
          <focus>yes</focus>
        </application>
      </applications>
    </openbox_config>
  '';

  xorgModules = lib.concatMapStringsSep "," (p: "${p}/lib/xorg/modules") [
    pkgs.xorg-server
    neko.xf86-video-dummy
    neko.xf86-input-neko
    pkgs.xf86-input-void
  ];

  session = pkgs.writeShellApplication {
    name = "browser-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.xorg-server
      pkgs.pulseaudio
      pkgs.openbox
      neko
      packages.browser-mcp
    ];
    text = ''
      # Xorg only creates the socket directory as root
      mkdir -p "$HOME/profile" "$XDG_RUNTIME_DIR" /tmp/.X11-unix
      # -nolisten local: no abstract X socket, which every session's
      # network namespace would share
      Xorg "$DISPLAY" -config ${neko.src}/runtime/xorg.conf -modulepath ${xorgModules} \
        -noreset -nolisten tcp -nolisten local -logfile /tmp/xorg.log &
      for _ in $(seq 100); do
        [ -S "/tmp/.X11-unix/X''${DISPLAY#:}" ] && break
        sleep 0.1
      done
      pulseaudio -n -F ${neko.src}/runtime/default.pa --log-target=stderr --log-level=error \
        --disallow-module-loading --disallow-exit --exit-idle-time=-1 &
      openbox --config-file ${openboxConfig} &
      neko serve &
      browser-mcp --http "$BROWSER_MCP_HTTP" --x11 &
      # Firefox comes back when someone closes its last window
      while true; do
        ${lib.getExe firefox} --no-remote --profile "$HOME/profile"
        sleep 1
      done &
      wait -n
      exit 1
    '';
  };

  # neko permissions of both roles; neko's defaults fill in missing fields,
  # so all are set
  profile = {
    is_admin = false;
    can_login = true;
    can_connect = true;
    can_watch = true;
    can_share_media = false;
    can_see_inactive_cursors = true;
  };
in
{
  options.services.browser-sessions = {
    enable = lib.mkEnableOption "shared browser sessions behind the browser-sessions gateway";
    url = lib.mkOption {
      type = lib.types.str;
      example = "https://browser.example.org";
      description = "Public base URL of the gateway, without a trailing slash.";
    };
    listen = lib.mkOption {
      type = lib.types.str;
      example = "0.0.0.0:8950";
      description = "Address the gateway listens on.";
    };
    idleTimeout = lib.mkOption {
      type = lib.types.str;
      example = "24h";
      description = "A session nobody is connected to ends after this long (Go duration).";
    };
    oidc = {
      issuer = lib.mkOption {
        type = lib.types.str;
        description = "OIDC issuer for the management page; every user it lets log in may create sessions.";
      };
      clientIdFile = lib.mkOption {
        type = lib.types.str;
        description = "File with the client id of a public (PKCE) client whose redirect URI is <url>/callback.";
      };
    };
    publicAddress = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 address WebRTC clients reach the slots' UDP ports at (neko's NAT 1:1 address).";
    };
    screen = lib.mkOption {
      type = lib.types.str;
      default = "1280x720@30";
      description = "Screen size and frame rate of the sessions, one of the modes in neko's xorg.conf.";
    };
    slots = lib.mkOption {
      description = "One entry per possible parallel session: its localhost ports and its WebRTC UDP port.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            neko = lib.mkOption { type = lib.types.port; };
            mcp = lib.mkOption { type = lib.types.port; };
            webrtc = lib.mkOption { type = lib.types.port; };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.browser-sessions = {
      isSystemUser = true;
      group = "browser-sessions";
    };
    users.groups.browser-sessions = { };

    # the gateway may start and stop the session units, nothing else
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "browser-sessions" &&
            /^browser-session@[0-9]+\.service$/.test(action.lookup("unit")) &&
            ["start", "stop"].indexOf(action.lookup("verb")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services.browser-sessions = {
      description = "Gateway of the shared browser sessions";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe packages.browser-sessions} -config ${
          pkgs.writeText "browser-sessions.json" (
            builtins.toJSON {
              inherit (cfg) listen url;
              state_dir = "/var/lib/browser-sessions";
              oidc_issuer = cfg.oidc.issuer;
              oidc_client_id_file = "/run/credentials/browser-sessions.service/oidc-client-id";
              idle_timeout = cfg.idleTimeout;
              unit = "browser-session@%d.service";
              systemctl = "${config.systemd.package}/bin/systemctl";
              slots = map (s: { inherit (s) neko mcp; }) cfg.slots;
            }
          )
        }";
        User = "browser-sessions";
        Group = "browser-sessions";
        StateDirectory = "browser-sessions";
        StateDirectoryMode = "0700";
        LoadCredential = "oidc-client-id:${cfg.oidc.clientIdFile}";
        Restart = "on-failure";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      };
    };

    environment.etc = lib.listToAttrs (
      lib.imap0 (
        i: s:
        lib.nameValuePair "browser-session/${toString i}.env" {
          text = ''
            NEKO_SERVER_BIND=127.0.0.1:${toString s.neko}
            NEKO_WEBRTC_UDPMUX=${toString s.webrtc}
            BROWSER_MCP_HTTP=127.0.0.1:${toString s.mcp}
          '';
        }
      ) cfg.slots
    );

    systemd.services."browser-session@" = {
      description = "Shared browser session %i";
      environment = {
        HOME = "/tmp/home";
        XDG_RUNTIME_DIR = "/tmp/run";
        DISPLAY = ":1";
        PULSE_SERVER = "unix:/tmp/pulseaudio.socket";
        NEKO_DESKTOP_SCREEN = cfg.screen;
        NEKO_MEMBER_PROVIDER = "multiuser";
        # the gateway logs controllers in with the admin password, viewers
        # with the user password (EnvironmentFile below)
        NEKO_MEMBER_MULTIUSER_ADMIN_PROFILE = builtins.toJSON (
          profile
          // {
            can_host = true;
            can_access_clipboard = true;
            sends_inactive_cursor = true;
          }
        );
        NEKO_MEMBER_MULTIUSER_USER_PROFILE = builtins.toJSON (
          profile
          // {
            can_host = false;
            can_access_clipboard = false;
            sends_inactive_cursor = false;
          }
        );
        NEKO_SESSION_IMPLICIT_HOSTING = "true";
        NEKO_WEBRTC_NAT1TO1 = cfg.publicAddress;
        NEKO_LEGACY = "false";
        NEKO_SERVER_METRICS = "false";
      };
      serviceConfig = {
        ExecStart = lib.getExe session;
        EnvironmentFile = [
          "/etc/browser-session/%i.env"
          "/var/lib/browser-sessions/slots/%i.env"
        ];
        DynamicUser = true;
        # one user per instance; without User= all instances share one
        User = "browser-session-%i";
        Restart = "on-failure";
        RestartSec = 2;
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        UMask = "0077";
      };
    };
  };
}
