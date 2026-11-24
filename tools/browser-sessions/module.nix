# The browser-sessions gateway (services.browser-sessions-gateway: the
# page, the login, the sessions and their tokens, proxying the links) and
# the session hosts (services.browser-sessions: the backend that the gateway
# drives over the network, and the session units it starts). Session i of a
# host runs in browser-session@i.service: Xorg (neko's dummy setup),
# pulseaudio, openbox, Firefox with the browser-mcp extension, neko and
# browser-mcp's HTTP server, as a dynamic user. Its home with the Firefox
# profile is the unit's StateDirectory, which outlives restarts and reboots
# until the backend cleans it when the session is killed; sockets, the X
# display and caches stay in the unit's private /tmp.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.browser-sessions;
  gateway = config.services.browser-sessions-gateway;
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
      // reopen the previous tabs on every start, also after a crash or a
      // reboot, without the about:sessionrestore page (-1: never); a stop
      // (idle, move) ends Firefox like a crash
      lockPref("browser.startup.page", 3);
      lockPref("browser.sessionstore.resume_from_crash", true);
      lockPref("browser.sessionstore.max_resumed_crashes", -1);
      // the session store keeps session cookies and form data of every
      // site, and nothing clears them at the end
      lockPref("browser.sessionstore.privacy_level", 0);
      lockPref("privacy.sanitize.sanitizeOnShutdown", false);
      lockPref("privacy.clearOnShutdown.cookies", false);
      lockPref("privacy.clearOnShutdown.sessions", false);
      lockPref("privacy.clearOnShutdown_v2.cookiesAndStorage", false);
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
        # a lock left by a crash or reboot names a dead pid that may now be
        # someone else's; only this loop runs Firefox on the profile
        rm -f "$HOME/profile/lock" "$HOME/profile/.parentlock"
        ${lib.getExe firefox} --no-remote --profile "$HOME/profile"
        sleep 1
      done &
      wait -n
      exit 1
    '';
  };

  # browser-session-export@ and -import@: tar the state of a stopped
  # session into <backend state>/transfer/<i>.tar, or extract that file into
  # it, as the session's own user, so moves between hosts need no root and
  # the files belong to the user of the new host. systemd opens the file.
  transferUnit = description: command: stdio: {
    inherit description;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = command;
      StandardError = "journal";
      DynamicUser = true;
      User = "browser-session-%i";
      StateDirectory = "browser-session/%i";
      StateDirectoryMode = "0700";
      PrivateNetwork = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectProc = "invisible";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      UMask = "0077";
    }
    // stdio;
  };
  transferFile = "/var/lib/browser-sessions/transfer/%i.tar";

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

  # the gateway and the backend are network servers without privileges;
  # the backend's polkit rule lets it drive the session units
  hardening = {
    User = "browser-sessions";
    Group = "browser-sessions";
    StateDirectoryMode = "0700";
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
in
{
  options.services.browser-sessions-gateway = {
    enable = lib.mkEnableOption "the gateway of the shared browser sessions";
    url = lib.mkOption {
      type = lib.types.str;
      example = "https://browser.example.org";
      description = "Public base URL of the gateway, without a trailing slash.";
    };
    listen = lib.mkOption {
      type = lib.types.str;
      example = "127.0.0.1:8949";
      description = "Address the gateway listens on.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "File with the token (at least 32 bytes) the gateway sends to the backends.";
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
    stopAfterMinutes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        Minutes without any request (an open viewer counts as one) after
        which a session's unit is stopped, keeping its profile, until the
        next request starts it again. 0 never stops one.
      '';
    };
    backends = lib.mkOption {
      description = "The session hosts by name: their backend's base URL and number of slots.";
      example = {
        atlas = {
          url = "http://10.243.1.3:8950";
          slots = 8;
        };
      };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption { type = lib.types.str; };
            slots = lib.mkOption { type = lib.types.ints.positive; };
          };
        }
      );
    };
  };

  options.services.browser-sessions = {
    enable = lib.mkEnableOption "a host of shared browser sessions, driven by the browser-sessions gateway";
    listen = lib.mkOption {
      type = lib.types.str;
      example = "0.0.0.0:8950";
      description = "Address the backend listens on for the gateway.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "File with the token the gateway sends (services.browser-sessions-gateway.tokenFile).";
    };
    publicAddress = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 address WebRTC clients reach the slots' UDP ports at (neko's NAT 1:1 address).";
    };
    privateAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        IPv4 address of this host that publicAddress forwards the UDP ports
        to. neko's UDP mux listens only there, so it answers the forwarded
        checks from the socket they arrived on.
      '';
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

  config = lib.mkMerge [
    (lib.mkIf (gateway.enable || cfg.enable) {
      users.users.browser-sessions = {
        isSystemUser = true;
        group = "browser-sessions";
      };
      users.groups.browser-sessions = { };
    })

    (lib.mkIf gateway.enable {
      systemd.services.browser-sessions-gateway = {
        description = "Gateway of the shared browser sessions";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = hardening // {
          ExecStart = "${lib.getExe packages.browser-sessions} -gateway ${
            pkgs.writeText "browser-sessions-gateway.json" (
              builtins.toJSON {
                inherit (gateway) listen url backends;
                stop_after_minutes = gateway.stopAfterMinutes;
                state_dir = "/var/lib/browser-sessions";
                token_file = "/run/credentials/browser-sessions-gateway.service/token";
                oidc_issuer = gateway.oidc.issuer;
                oidc_client_id_file = "/run/credentials/browser-sessions-gateway.service/oidc-client-id";
              }
            )
          }";
          StateDirectory = "browser-sessions";
          LoadCredential = [
            "token:${gateway.tokenFile}"
            "oidc-client-id:${gateway.oidc.clientIdFile}"
          ];
        };
      };

      # the sessions with their tokens and the cookie key
      lass.backup.state.browser-sessions.folders = [ "/var/lib/browser-sessions" ];
    })

    (lib.mkIf cfg.enable {
      # the backend may start, stop and clean (delete the state of) the
      # session units and start their export and import, nothing else;
      # systemctl clean refs the unit to wait for the cleaning
      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          var unit = action.lookup("unit"), verb = action.lookup("verb");
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == "browser-sessions" &&
              ((/^browser-session@[0-9]+\.service$/.test(unit) &&
                ["start", "stop", "clean", "ref"].indexOf(verb) >= 0) ||
               (/^browser-session-(export|import)@[0-9]+\.service$/.test(unit) && verb == "start"))) {
            return polkit.Result.YES;
          }
        });
      '';
      # systemd's D-Bus policy lets only root call CleanUnit; polkit above
      # still limits it to the session units
      services.dbus.packages = [
        (pkgs.writeTextDir "share/dbus-1/system.d/browser-sessions.conf" ''
          <busconfig>
            <policy user="browser-sessions">
              <allow send_destination="org.freedesktop.systemd1"
                     send_interface="org.freedesktop.systemd1.Manager"
                     send_member="CleanUnit"/>
            </policy>
          </busconfig>
        '')
      ];

      systemd.services.browser-sessions = {
        description = "Backend of the shared browser sessions";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = hardening // {
          ExecStart = "${lib.getExe packages.browser-sessions} -backend ${
            pkgs.writeText "browser-sessions.json" (
              builtins.toJSON {
                inherit (cfg) listen;
                state_dir = "/var/lib/browser-sessions";
                token_file = "/run/credentials/browser-sessions.service/token";
                unit = "browser-session@%d.service";
                export_unit = "browser-session-export@%d.service";
                import_unit = "browser-session-import@%d.service";
                systemctl = "${config.systemd.package}/bin/systemctl";
                slots = map (s: { inherit (s) neko mcp; }) cfg.slots;
              }
            )
          }";
          # the slots' env files with the secrets the gateway sent
          StateDirectory = "browser-sessions";
          LoadCredential = "token:${cfg.tokenFile}";
        };
      };

      # sessions are user data: the slots' secrets and the session homes
      # (DynamicUser keeps them under /var/lib/private)
      lass.backup.state.browser-sessions.folders = [
        "/var/lib/browser-sessions"
        "/var/lib/private/browser-session"
      ];

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
          HOME = "/var/lib/browser-session/%i";
          XDG_CACHE_HOME = "/tmp/cache";
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
          NEKO_WEBRTC_UDPMUX_IPS = cfg.privateAddress;
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
          # /var/lib/private/browser-session/<i>, owned by the instance's user
          StateDirectory = "browser-session/%i";
          StateDirectoryMode = "0700";
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

      systemd.services."browser-session-export@" =
        transferUnit "Write the state of the stopped browser session %i to a tar"
          "${lib.getExe pkgs.gnutar} -c -C %S/browser-session/%i ."
          { StandardOutput = "truncate:${transferFile}"; };
      systemd.services."browser-session-import@" =
        transferUnit "Fill the state of the stopped browser session %i from a tar"
          "${lib.getExe pkgs.gnutar} -x --no-same-owner -C %S/browser-session/%i"
          { StandardInput = "file:${transferFile}"; };
    })
  ];
}
