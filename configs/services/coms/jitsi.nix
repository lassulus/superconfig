{ self, ... }:
{

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
      stunServers = [
        # - https://www.kuketz-blog.de/jitsi-meet-server-einstellungen-fuer-einen-datenschutzfreundlichen-betrieb/
        { urls = "turn:turn.matrix.org:3478?transport=udp"; }
        { urls = "turn:turn.matrix.org:3478?transport=tcp"; }
      ];
    };
    interfaceConfig = {
      SHOW_JITSI_WATERMARK = false;
      SHOW_WATERMARK_FOR_GUESTS = false;
      GENERATE_ROOMNAMES_ON_WELCOME_PAGE = false;
      DISABLE_PRESENCE_STATUS = true;
      DEFAULT_REMOTE_DISPLAY_NAME = "Fellow Nixer";
    };
  };

  # Disable AWS harvester (not needed) and configure NAT harvester
  # so clients can establish media connections through NAT
  services.jitsi-videobridge.extraProperties = {
    "org.ice4j.ice.harvest.DISABLE_AWS_HARVESTER" = "true";
    "org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS" = "0.0.0.0";
    "org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS" = "95.217.192.59";
  };

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
    4443
    10000
  ];
  networking.firewall.allowedUDPPorts = [ 10000 ];
}
