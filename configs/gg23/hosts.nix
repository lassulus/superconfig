# Fixed LAN addresses in gg23, handed out by acheron's DHCP server
# (../gg23.nix). The audio hub (./audio/hub.nix) sends to the rooms over
# these, so their audio does not go through tinc.
{
  styx = {
    # et0, ex-router
    ip4 = "10.42.0.3";
    mac = "3c:7c:3f:7e:e2:39";
  };
  shodan = {
    # wlp3s0
    ip4 = "10.42.0.5";
    mac = "60:67:20:69:66:e4";
  };
  icarus = {
    # Wi-Fi
    ip4 = "10.42.0.6";
    mac = "84:3a:4b:9b:c1:cc";
  };
}
