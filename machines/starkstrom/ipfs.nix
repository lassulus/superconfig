{ config, lib, ... }:
{
  lass.ports = {
    "5001" = "kubo-api";
    "8089" = "kubo-gateway";
  }
  // lib.genAttrs (lib.unique (
    # "/ip4/0.0.0.0/udp/4001/quic-v1" -> "4001", nixpkgs' default Swarm addresses
    map (addr: lib.elemAt (lib.splitString "/" addr) 4) config.services.kubo.settings.Addresses.Swarm
  )) (_: "kubo-swarm");

  # Full kubo (IPFS) node. Data lives under /var/lib/ipfs on the 4 TB root.
  # Uploads are copied into the blockstore (NO filestore/--nocopy on this host).
  services.kubo = {
    enable = true;
    dataDir = "/var/lib/ipfs";
    # No automatic GC: content is pinned on upload and only reclaimed by the
    # explicit `ipfs-gc` command (see ipfs-endpoint.nix).
    settings = {
      Addresses = {
        API = [ "/ip4/127.0.0.1/tcp/${toString config.lass.servicePorts.kubo-api}" ];
        Gateway = [ "/ip4/127.0.0.1/tcp/${toString config.lass.servicePorts.kubo-gateway}" ];
      };
      # Serve only local/pinned blocks -> the public gateway is not an open
      # proxy for arbitrary network CIDs.
      Gateway.NoFetch = true;
      Datastore.StorageMax = "500GB";

      # Make the pins reachable through the public gateways, the way the
      # old node (configs/services/flix/ipfs.nix) was. Measured before
      # this block with ipfs-check against a pinned CID: DHT provider
      # record present, bitswap answering, IPNI record ABSENT -- and every
      # public gateway 504ing on anything larger than a single block,
      # since walking a DAG block by block over bitswap from one peer does
      # not fit their ~30 s request budget.
      #
      # autoclient = DHT client plus IPNI (cid.contact) announcements; the
      # gateways resolve providers through IPNI and can then pull content
      # in bulk. Provide.Strategy pinned keeps the announcements to what
      # is meant to be served; the nixpkgs module's default Reprovider
      # block is the pre-0.40 name and must be nulled or kubo refuses to
      # start.
      Routing.Type = "autoclient";
      Reprovider = null;
      Provide = {
        Strategy = "pinned";
        DHT.Interval = "12h";
      };

      # Room for the gateways' parallel block requests: a 3.9 GB tree is
      # ~15,000 blocks and a gateway fetching one opens many streams.
      Swarm.ConnMgr = {
        LowWater = 100;
        HighWater = 400;
        GracePeriod = "20s";
      };
      Swarm.ResourceMgr = {
        Enabled = true;
        MaxMemory = "2GB";
      };
      Swarm.Transports.Network.TCP = true;
      Swarm.Transports.Network.QUIC = true;
      # No relaying for others; this node has a public address.
      Swarm.RelayClient.Enabled = false;
      Swarm.RelayService.Enabled = false;
    };
  };

  # incoming swarm connections (TCP + QUIC/UDP on 4001)
  networking.firewall.allowedTCPPorts = [ config.lass.servicePorts.kubo-swarm ];
  networking.firewall.allowedUDPPorts = [ config.lass.servicePorts.kubo-swarm ];
}
