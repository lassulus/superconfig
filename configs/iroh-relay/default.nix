let
  domain = "relay.lassul.us";
  # Plain HTTP/WS on loopback only; nginx terminates TLS in front of it.
  httpPort = 3340;
  # QUIC address discovery. Public UDP, and the one part nginx cannot proxy,
  # so the relay reads the ACME cert itself. 7842 is iroh's
  # DEFAULT_RELAY_QUIC_PORT -- clients derive it from the relay url and expect
  # it there, so do not move it without telling every client.
  quicPort = 7842;
  metricsPort = 9096;
  certGroup = "irohrelaycert";

  configFile = (
    pkgs:
    pkgs.writeText "iroh-relay.toml" ''
      enable_relay = true
      http_bind_addr = "127.0.0.1:${toString httpPort}"

      # The whole reason to run our own relay: QAD tells an endpoint its own NAT
      # mapping, which is what makes hole punching work. Without it this is just
      # a data relay and peers never upgrade to direct. Requires TLS.
      enable_quic_addr_discovery = true

      enable_metrics = true
      metrics_bind_addr = "127.0.0.1:${toString metricsPort}"

      [tls]
      hostname = "${domain}"
      quic_bind_addr = "[::]:${toString quicPort}"

      # `Reloading` re-reads the cert from disk periodically, so ACME renewals are
      # picked up without a restart. `LetsEncrypt` is not usable here: it wants to
      # own port 80 for the challenge, which nginx already has.
      cert_mode = "Reloading"
      manual_cert_path = "/var/lib/acme/${domain}/fullchain.pem"
      manual_key_path = "/var/lib/acme/${domain}/key.pem"

      # Serve the relay's HTTP/WS side as plain HTTP so nginx can reverse-proxy
      # it; the cert above is then used only by the QUIC listener. "dangerous"
      # overstates it here: the plaintext hop is loopback, nginx does real TLS on
      # 443, and relayed payloads are already end-to-end encrypted between iroh
      # endpoints -- the relay only ever sees ciphertext.
      dangerous_http_only = true
    ''
  );
in
{
  pkgs,
  ...
}:
{
  lass.ports = {
    ${toString httpPort} = "iroh-relay";
    ${toString quicPort} = "iroh-relay-quic";
    ${toString metricsPort} = "iroh-relay-metrics";
  };

  # Self-hosted iroh relay.
  #
  # A relay supplies the two things a relay-free iroh endpoint cannot get for
  # itself: QUIC address discovery (learning its own NAT mapping) and a
  # signalling path to coordinate hole punching. Measured from a double-NATed
  # host, relayed configs hole-punched to direct in ~80ms with 0 failures over
  # 30 runs, while the relay-free config failed 100% of the time.
  #
  # Running our own also fixes the throughput floor: n0's public relays
  # rate-limit to ~0.9 Mbps, which is fine for keystrokes and miserable for
  # anything larger when hole punching fails.
  #
  # Clients opt in with `RelayMode::Custom`, e.g.
  #   iroh-bench --config dht-selfrelay --relay-url https://relay.lassul.us
  #   dumbpipe listen-tcp --relay-url https://relay.lassul.us   (patched build)

  # nginx owns 80/443 and the ACME challenge, so it fetches the cert and the
  # relay only reads it. A dedicated group keeps that read as narrow as
  # possible; nginx must be a member to serve the vhost. Same pattern as
  # mailserver.nix's `lasscert`.
  security.acme.certs.${domain}.group = certGroup;
  users.groups.${certGroup}.members = [ "nginx" ];

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    # One location covers every route the relay serves: `/relay` (the websocket
    # clients ride), `/ping` and `/generate_204` (net_report latency probes,
    # which is how a client picks its nearest relay out of a map).
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString httpPort}";
      proxyWebsockets = true;
      # Relay connections are long-lived and idle whenever a pair has upgraded
      # to a direct path; nginx's default 60s read timeout would tear them down
      # and force clients back through a reconnect.
      extraConfig = ''
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
      '';
    };
  };

  systemd.services.iroh-relay = {
    description = "iroh relay (${domain})";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nginx.service"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.iroh-relay}/bin/iroh-relay --config-path ${configFile pkgs}";
      Restart = "always";
      RestartSec = 5;

      DynamicUser = true;
      # Read access to /var/lib/acme/${domain}. Works with DynamicUser: systemd
      # adds the transient user to the group at start.
      SupplementaryGroups = [ certGroup ];

      # ProtectSystem=strict only remounts read-only, so reading the cert is
      # still fine.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  # Only the QAD listener needs a hole punched; the relay's HTTP side is
  # reached through nginx on 443, which is already open.
  networking.firewall.allowedUDPPorts = [ quicPort ];
}
