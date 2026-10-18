{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # Prometheus exporter for the ARRIS TG3442DE "Vodafone Station":
      # DOCSIS channel power/SNR/lock and router status from its web UI.
      packages.vodafone-station-exporter =
        (pkgs.writeShellApplication {
          name = "vodafone-station-exporter";
          text = ''
            exec ${
              pkgs.python3.withPackages (p: [
                p.requests
                p.cryptography
              ])
            }/bin/python3 ${./vodafone_station_exporter.py} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
