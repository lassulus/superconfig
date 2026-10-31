{
  self,
  config,
  lib,
  ...
}:
{
  imports = [
    ./coturn.nix
    ./jitsi-moderators.nix
  ];

  lass.ports =
    lib.genAttrs (map toString config.services.prosody.httpPorts) (_: "prosody-http")
    // lib.genAttrs (map toString config.services.prosody.httpsPorts) (_: "prosody-https")
    // {
      # prosody's c2s and s2s defaults
      "5222" = "prosody-c2s";
      "5269" = "prosody-s2s";
      # ice tcp and udp, defaults of nixpkgs' jitsi-videobridge module
      "4443" = "jitsi-videobridge-tcp";
      "10000" = "jitsi-videobridge";
      # the bridge's private REST API and jicofo's, on localhost
      "8080" = "jitsi-videobridge-rest";
      "8888" = "jicofo-rest";
    };

  # jitsi-meet 1.0.8792 is marked insecure in nixpkgs; secureify via overlay
  # rather than nixpkgs.config.permittedInsecurePackages (which doesn't
  # list-merge across modules and gets clobbered).
  nixpkgs.overlays = [
    (_final: prev: {
      jitsi-meet = self.lib.secureify prev.jitsi-meet;
    })
  ];
  services.jitsi-meet = {
    enable = true;
    hostName = "jitsi.lassul.us";
    config = {
      enableWelcomePage = true;
      requireDisplayName = true;
      analytics.disabled = true;
    };
    interfaceConfig = {
      SHOW_JITSI_WATERMARK = false;
      SHOW_WATERMARK_FOR_GUESTS = false;
      GENERATE_ROOMNAMES_ON_WELCOME_PAGE = false;
      DISABLE_PRESENCE_STATUS = true;
      DEFAULT_REMOTE_DISPLAY_NAME = "Fellow Nixer";
    };
  };

  # The public IP sits directly on the interface, so the bridge needs neither
  # the AWS nor a STUN mapping harvester (the default STUN host is dead).
  services.jitsi-videobridge.extraProperties."org.ice4j.ice.harvest.DISABLE_AWS_HARVESTER" = "true";
  services.jitsi-videobridge.nat.harvesterAddresses = [ ];

  # The bridge otherwise suspends forwarded video (incl. screen shares not on
  # stage) when its bandwidth estimate for a receiver is low; with
  # trust-bwe=false it forwards everything selected and never pauses an
  # active screen share.
  services.jitsi-videobridge.config.videobridge.cc.trust-bwe = false;

  services.prosody.checkConfig = false;

  services.nginx.virtualHosts."meet.lassul.us" = {
    enableACME = true;
    addSSL = true;
    locations."/".return = "301 https://jitsi.lassul.us$request_uri";
  };

  networking.firewall.allowedTCPPorts = [
    config.lass.servicePorts.jitsi-videobridge-tcp
  ];
  networking.firewall.allowedUDPPorts = [ config.lass.servicePorts.jitsi-videobridge ];
}
