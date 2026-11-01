{
  imports = [
    ./knot.nix
    ./pds.nix
  ];

  # The web UI is tangled.org's (knot.nix); keep old links working
  services.nginx.virtualHosts."git.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    globalRedirect = "tangled.org";
  };
}
