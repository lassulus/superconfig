# Moonlight from anywhere to atlas' Sunshine (configs/sunray.nix). atlas sits
# behind a router we don't control that drops incoming connections, so
# atlas.lassul.us points at neoprism, which forwards Sunshine's ports over
# retiolum to atlas. Moonlight (e.g. on the phone) adds atlas.lassul.us like
# any host; only devices paired with atlas' Sunshine can stream. IPv4 only:
# atlas' Sunshine listens on IPv4, and the name has no AAAA record.
{
  config,
  lib,
  self,
  ...
}:
let
  atlas = self.inputs.kartei.hosts.atlas.nets.retiolum.ip4.addr;
  # Sunshine's port layout, from its base port (configs/sunray.nix keeps the
  # default; offsets as in nixpkgs' sunshine firewall rules). The web UI
  # (base + 1) and the mic (base + 13) stay unforwarded.
  base = config.services.sunshine.settings.port;
  tcp = {
    atlas-sunshine-https = base - 5;
    atlas-sunshine = base;
    atlas-sunshine-rtsp = base + 21;
  };
  udp = {
    atlas-sunshine-video = base + 9;
    atlas-sunshine-control = base + 10;
    atlas-sunshine-audio = base + 11;
  };
  set = ports: "{ ${lib.concatMapStringsSep ", " toString (lib.attrValues ports)} }";
in
{
  lass.ports = lib.mapAttrs' (name: port: lib.nameValuePair (toString port) name) (tcp // udp);

  networking.nftables.tables.atlas-sunshine = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname != "retiolum" fib daddr type local tcp dport ${set tcp} dnat to ${atlas}
        iifname != "retiolum" fib daddr type local udp dport ${set udp} dnat to ${atlas}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # atlas answers neoprism over retiolum, not the client directly
        ip daddr ${atlas} ct status dnat masquerade
      }
    '';
  };
  networking.firewall.extraForwardRules = ''
    # retiolum's MTU is smaller than the clients' links
    ip daddr ${atlas} ct status dnat tcp flags syn tcp option maxseg size set rt mtu
    ip daddr ${atlas} ct status dnat accept
  '';
}
