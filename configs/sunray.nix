# Host side of tools/sunray: Sunshine runs in the sway session, and
# `sunray-pin` approves a client's PIN through Sunshine's local API, so only
# clients that can ssh in get paired. sunshine.lassul.us
# (configs/sunshine-web.nix) is paired declaratively instead: Sunshine uses
# the sunshine-server cert below, which it knows, and trusts its client cert.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  ports = config.lass.servicePorts;
  password = "\${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunray-password";
  # Sunshine's file_state (paired clients, also the credentials_file)
  state = "\${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine_state.json";

  server = config.clan.core.vars.generators.sunshine-server.files;
  webClient = {
    name = "sunshine.lassul.us";
    # fixed, so the preStart below finds its own entry again
    uuid = "4f0c5a1e-6b2d-4e8a-9c3f-5d7b1a2e8c60";
    cert =
      pkgs.writeText "sunshine-web-client.pem"
        self.nixosConfigurations.neoprism.config.clan.core.vars.generators.sunshine-web-client.files."cert.pem".value;
  };

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
      cert = server."cert.pem".path;
      pkey = server."key.pem".path;
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
    # API credentials for sunray-pin, created once; then trust the
    # sunshine.lassul.us client, keeping every other paired client. Sunshine
    # only reads named_devices from a state file with a root.uniqueid, and
    # rejects a cert that is in there twice.
    preStart = ''
      if [ ! -s "${password}" ]; then
        pw=$(${pkgs.coreutils}/bin/head -c 24 /dev/urandom | ${pkgs.coreutils}/bin/base64)
        ${lib.getExe config.services.sunshine.package} --creds sunray "$pw"
        (umask 077 && printf '%s\n' "$pw" > "${password}")
      fi

      state="${state}"
      [ -s "$state" ] || echo '{}' > "$state"
      tmp=$(${pkgs.coreutils}/bin/mktemp "$state.XXXXXX")
      ${lib.getExe pkgs.jq} \
        --arg name ${webClient.name} \
        --arg uuid ${webClient.uuid} \
        --rawfile cert ${webClient.cert} \
        --arg uniqueid "$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/random/uuid)" \
        '.root.uniqueid //= $uniqueid
        | .root.named_devices = (
          [.root.named_devices[]? | select(.uuid != $uuid and .cert != $cert)]
          + [{name: $name, cert: $cert, uuid: $uuid, enabled: "true"}]
        )' "$state" > "$tmp"
      mv "$tmp" "$state"
    '';
  };

  # Sunshine's server identity, so sunshine.lassul.us knows it without
  # pairing: the shape Sunshine generates itself (RSA 2048, v3 without
  # extensions but the key id, 20 years; no CA flag, which rustls rejects
  # for a server cert). Sunshine runs as the desktop user.
  clan.core.vars.generators.sunshine-server = {
    files."cert.pem".secret = false;
    files."key.pem".owner = config.users.users.mainUser.name;
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      printf '[req]\ndistinguished_name = dn\n[dn]\n' > req.cnf
      openssl req -x509 -config req.cnf -newkey rsa:2048 -nodes -sha256 -days 7300 \
        -subj "/CN=Sunshine Gamestream Host" -keyout "$out/key.pem" -out "$out/cert.pem"
    '';
  };

  # Sunshine injects mouse/keyboard through uinput; hand it to the user of the
  # active session.
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
  '';
}
