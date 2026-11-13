{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # Prometheus exporter for a FRITZ!Box Cable: DOCSIS channel
      # power/SNR/errors from the web UI, router and connection status via
      # TR-064.
      packages.fritzbox-cable-exporter =
        (pkgs.writeShellApplication {
          name = "fritzbox-cable-exporter";
          text = ''
            exec ${
              pkgs.python3.withPackages (p: [
                p.requests
                p.fritzconnection
              ])
            }/bin/python3 ${./fritzbox_cable_exporter.py} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
