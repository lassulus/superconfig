{
  config,
  lib,
  pkgs,
  ...
}:
{
  # "localhost:631" -> "631"
  lass.ports = lib.genAttrs (map (
    addr: lib.last (lib.splitString ":" addr)
  ) config.services.printing.listenAddresses) (_: "cups");
  services.printing = {
    enable = true;
    browsing = true;
    browsedConf = ''
      BrowseDNSSDSubTypes _cups,_print
      BrowseLocalProtocols all
      BrowseRemoteProtocols all
      CreateIPPPrinterQueues All

      BrowseProtocols all
    '';
  };
  systemd.services.cups.serviceConfig.ExecStartPost = pkgs.writers.writeDash "init-gg23" ''
    lpadmin -x gg23 || :
    lpadmin -i ${./gg23.ppd} -p gg23 -E -v ipp://10.42.0.4
  '';
}
