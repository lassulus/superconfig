# Fall back to a USB-tethered phone when the Vodafone uplink (et0) is dead.
#
# wan-failover pings out of et0. After a few failures it puts a low-metric
# default route via the phone in front of et0's and points dnsmasq at the
# phone's resolver (an unprovisioned Vodafone cable modem hijacks DNS to its
# activation portal). Once et0 answers again for a while, it removes that route
# and dnsmasq goes back to et0's resolvers.
{ pkgs, ... }:
let
  resolvFile = "/run/wan-failover/resolv.conf";
in
{
  # The phone's own DHCP/RA routes stay behind et0 (metric 1024); only
  # wan-failover promotes it.
  systemd.network.networks."40-usb-tether" = {
    matchConfig.Driver = "cdc_ncm rndis_host";
    DHCP = "yes";
    linkConfig.RequiredForOnline = "no";
    dhcpV4Config.RouteMetric = 2048;
    ipv6AcceptRAConfig.RouteMetric = 2048;
  };

  # dnsmasq polls this file and reloads its upstreams when it changes.
  services.dnsmasq.settings.resolv-file = resolvFile;
  systemd.tmpfiles.rules = [ "d /run/wan-failover 0755 root root -" ];

  systemd.services.wan-failover = {
    description = "Fail over from et0 to a USB-tethered phone";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
    path = [
      pkgs.iproute2
      pkgs.iputils
      pkgs.conntrack-tools
      pkgs.systemd
      pkgs.gawk
      pkgs.coreutils
      pkgs.diffutils
    ];
    script = ''
      set +e # one failing command must not drop us back to et0 via restart
      down_after=3 # failed checks before switching to the phone
      up_after=6   # good checks before switching back to et0
      # gateway of the first route ("default [nhid N] via GW ...")
      via='{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'

      phone_iface() {
        for i in /sys/class/net/*; do
          case "$(basename "$(readlink -f "$i/device/driver")")" in
            cdc_ncm|rndis_host) basename "$i"; return ;;
          esac
        done
      }

      et0_ok() {
        ping -q -c1 -W2 -I et0 1.1.1.1 >/dev/null 2>&1 ||
          ping -q -c1 -W2 -I et0 9.9.9.9 >/dev/null 2>&1
      }

      # DNS servers networkd learned on a link, as resolv.conf. resolvectl
      # wraps long lists onto indented lines, so strip only the
      # "Link N (iface):" prefix, not everything up to the first colon.
      write_resolv() {
        resolvectl dns "$1" 2>/dev/null | sed -E 's/^Link [0-9]+ \([^)]*\)://' | tr -s ' ' '\n' |
          awk 'NF && !/%/ { print "nameserver " $0 }' > ${resolvFile}.new
        if [ -s ${resolvFile}.new ] && ! cmp -s ${resolvFile}.new ${resolvFile}; then
          mv ${resolvFile}.new ${resolvFile}
          echo "dns via $1: $(awk '{print $2}' ${resolvFile} | tr '\n' ' ')"
        else
          rm -f ${resolvFile}.new
        fi
      }

      use_phone() {
        local gw4 gw6
        gw4=$(ip -4 route show default dev "$1" proto dhcp | awk "$via")
        gw6=$(ip -6 route show default dev "$1" proto ra | awk "$via")
        [ -n "$gw4" ] && ip -4 route replace default via "$gw4" dev "$1" metric 100
        [ -n "$gw6" ] && ip -6 route replace default via "$gw6" dev "$1" metric 100
        resolvectl default-route et0 no
        write_resolv "$1"
      }

      use_et0() {
        while ip -4 route del default metric 100 2>/dev/null; do :; done
        while ip -6 route del default metric 100 2>/dev/null; do :; done
        resolvectl default-route et0 yes
        write_resolv et0
      }

      mode=et0 fails=0 oks=0
      use_et0
      while :; do
        phone=$(phone_iface)
        if et0_ok; then fails=0 oks=$((oks + 1)); else oks=0 fails=$((fails + 1)); fi

        if [ "$mode" = et0 ] && [ -n "$phone" ] && [ "$fails" -ge "$down_after" ]; then
          echo "et0 down, switching to $phone"
          mode=phone
          use_phone "$phone"
          conntrack -F >/dev/null 2>&1 || true
        elif [ "$mode" = phone ] && { [ "$oks" -ge "$up_after" ] || [ -z "$phone" ]; }; then
          echo "switching back to et0"
          mode=et0
          use_et0
          conntrack -F >/dev/null 2>&1 || true
        elif [ "$mode" = phone ]; then
          use_phone "$phone" # follow gateway/DNS changes, replugs
        else
          write_resolv et0
        fi
        sleep 10
      done
    '';
  };
}
