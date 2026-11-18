# Log every new NAT mapping of a LAN host's tinc UDP flow (source port 655),
# with the port the masquerade picked. After an uplink flap or a conntrack
# flush the LAN hosts get new ports, which peers behind other NATs must
# learn before direct UDP works again. With this in VictoriaLogs a stuck
# retiolum pair can be traced to the rebind without SSH.
{ pkgs, ... }:
{
  systemd.services.retiolum-nat-log = {
    description = "Log NAT mappings of the LAN's tinc UDP flows";
    wantedBy = [ "multi-user.target" ];
    after = [ "nftables.service" ];
    path = [
      pkgs.conntrack-tools
      pkgs.gnused
    ];
    script = ''
      watch() {
        conntrack -E -e NEW -f "$1" -p udp --orig-port-src 655 -s "$2" 2>&1 |
          sed -u -E 's/.*\[NEW\] udp +[0-9]+ [0-9]+ src=([^ ]+) dst=([^ ]+) sport=655 dport=([0-9]+).* dport=([0-9]+).*/nat: \1:655 -> \2:\3 masqueraded to port \4/'
      }
      watch ipv4 10.42.0.0/24 &
      watch ipv6 fd42:7d6a::/64 &
      wait -n
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
    };
  };
}
