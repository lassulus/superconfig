{ config, pkgs, ... }:
let
  domain = "turn.lassul.us";
  minPort = 49152;
  maxPort = 49999;
in
{
  # STUN/TURN for jitsi.lassul.us. Clients get the servers and short-lived
  # credentials (TURN REST, HMAC over the shared secret) from Prosody's
  # mod_external_services (XEP-0215), see the prosody block below.
  clan.core.vars.generators.coturn = {
    # coturn's preStart reads it as turnserver; prosody gets it via
    # LoadCredential as root.
    files.secret.owner = "turnserver";
    runtimeInputs = [ pkgs.pwgen ];
    script = ''
      pwgen -s 64 1 | tr -d '\n' > $out/secret
    '';
  };

  services.coturn = {
    enable = true;
    realm = domain;
    use-auth-secret = true;
    static-auth-secret-file = config.clan.core.vars.generators.coturn.files.secret.path;
    cert = "/var/lib/acme/${domain}/fullchain.pem";
    pkey = "/var/lib/acme/${domain}/key.pem";
    min-port = minPort;
    max-port = maxPort;
    no-cli = true;
    # Never relay into local or overlay networks (retiolum 10.243.0.0/16 and
    # 42::/16, yggdrasil 200::/7).
    extraConfig = ''
      no-multicast-peers
      denied-peer-ip=0.0.0.0-0.255.255.255
      denied-peer-ip=10.0.0.0-10.255.255.255
      denied-peer-ip=10.243.0.0-10.243.255.255
      denied-peer-ip=100.64.0.0-100.127.255.255
      denied-peer-ip=127.0.0.0-127.255.255.255
      denied-peer-ip=169.254.0.0-169.254.255.255
      denied-peer-ip=172.16.0.0-172.31.255.255
      denied-peer-ip=192.168.0.0-192.168.255.255
      denied-peer-ip=::1
      denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
      denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
      denied-peer-ip=42::-42:ffff:ffff:ffff:ffff:ffff:ffff:ffff
      denied-peer-ip=200::-3ff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
    '';
  };

  # nginx fetches the cert, coturn reads it through its own group.
  services.nginx.virtualHosts.${domain}.enableACME = true;
  security.acme.certs.${domain} = {
    group = "turnserver";
    reloadServices = [ "coturn.service" ];
  };
  users.groups.turnserver.members = [ "nginx" ];

  services.prosody.virtualHosts.${config.services.jitsi-meet.hostName}.extraConfig = ''
    external_service_secret = Credential("coturn-secret")
    external_services = {
      { type = "stun", host = "${domain}", port = 3478 },
      { type = "turn", host = "${domain}", port = 3478, transport = "udp", secret = true, ttl = 86400, algorithm = "turn" },
      { type = "turn", host = "${domain}", port = 3478, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" },
      { type = "turns", host = "${domain}", port = 5349, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" },
    }
  '';
  systemd.services.prosody.serviceConfig.LoadCredential = [
    "coturn-secret:${config.clan.core.vars.generators.coturn.files.secret.path}"
  ];

  networking.firewall.allowedTCPPorts = [
    3478
    5349
  ];
  networking.firewall.allowedUDPPorts = [
    3478
    5349
  ];
  networking.firewall.allowedTCPPortRanges = [
    {
      from = minPort;
      to = maxPort;
    }
  ];
  networking.firewall.allowedUDPPortRanges = [
    {
      from = minPort;
      to = maxPort;
    }
  ];
}
