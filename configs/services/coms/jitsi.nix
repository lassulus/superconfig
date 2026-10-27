{ self, ... }:
{
  imports = [ ./coturn.nix ];

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
    4443
    10000
  ];
  networking.firewall.allowedUDPPorts = [ 10000 ];
}
