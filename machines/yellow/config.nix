{
  config,
  pkgs,
  lib,
  ...
}:
let
  torrentport = 56709; # port forwarded in airvpn webinterface
in
{
  clan.core.vars.password-store.secretLocation = "/var/state/secret-vars";

  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/services/flix
    ../../configs/autoupdate.nix
    ../../configs/services/archiver-bot.nix
    ./backup.nix
  ];

  services.transmission.settings.peer-port = torrentport;

  lass.sync-containers3.inContainer = {
    enable = true;
    pubkey = builtins.readFile ./facts/yellow.sync.pub;
  };

  networking.useHostResolvConf = false;
  networking.useNetworkd = true;
  networking.resolvconf.enable = false;
  # we need to set a namserver here that can be also be reached from the transmission network namespace
  environment.etc."resolv.conf".text = ''
    options edns0
    nameserver 1.1.1.1
  '';
  services.resolved.enable = lib.mkForce false;

  systemd.services."netns@" = {
    description = "%I network namespace";
    before = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iproute2}/bin/ip netns add %I";
      ExecStop = "${pkgs.iproute2}/bin/ip netns del %I";
    };
  };

  systemd.services.transmission-netns = {
    bindsTo = [ "netns@transmission.service" ];
    after = [ "netns@transmission.service" ];
    path = [
      pkgs.iproute2
      pkgs.wireguard-tools
      pkgs.gnused
      pkgs.gawk
    ];
    script = ''
      set -efux
      until ${pkgs.dig.host}/bin/host europe.vpn.airdns.org; do sleep 1; done

      ip link del t2 || :
      ip -n transmission link set lo up
      ip link add airvpn type wireguard
      ip -n transmission link del airvpn || :
      ip link set airvpn netns transmission
      ip -n transmission addr add 10.176.43.231/32 dev airvpn
      ip -n transmission addr add fd7d:76ee:e68f:a993:41b3:846b:d271:30d8/128 dev airvpn
      # The transmission netns has no route until the tunnel is up, so wg must
      # not resolve the endpoint from inside it: recent wireguard-tools resolve
      # in the current netns, which stalls the deploy on ~70s of DNS retries.
      # Resolve here in the main netns and hand wg a numeric Endpoint.
      conf=$(wg-quick strip ${config.clan.core.vars.generators.airvpn.files."airvpn.conf".path})
      ep=$(printf '%s\n' "$conf" | sed -n 's/^Endpoint *= *//p')
      ephost=''${ep%:*}
      epport=''${ep##*:}
      epip=$(${pkgs.dig.host}/bin/host "$ephost" | awk '/has address/ { print $NF; exit }')
      ip netns exec transmission wg syncconf airvpn \
        <(printf '%s\n' "$conf" | sed "s|$ephost:$epport|$epip:$epport|")
      ip -n transmission link set airvpn up
      ip -n transmission route add default dev airvpn
      ip -6 -n transmission route add default dev airvpn
      ip link add t1 type veth peer name t2

      ip -n transmission link del t1 || :
      ip link set t1 netns transmission

      ip addr add 128.0.0.2/30 dev t2
      ip addr add fdb4:3310:947::1/64 dev t2
      ip link set t2 up
      ip -n transmission addr add 128.0.0.1/30 dev t1
      ip -n transmission addr add fdb4:3310:947::2/64 dev t1
      ip -n transmission link set t1 up
      ip -n transmission route add 42:0:ce16::3110/16 via fdb4:3310:947::1 dev t1
    '';
    serviceConfig = {
      RemainAfterExit = true;
      Type = "oneshot";
    };
  };

  clan.core.vars.generators.airvpn = {
    files."airvpn.conf" = { };
    prompts.config.description = ''
      login into https://airvpn.org/ goto https://airvpn.org/generator/
      generate a wireguard config
      paste the config here
    '';
    runtimeInputs = with pkgs; [ coreutils ];
    script = ''
      cat "$prompts"/config > "$out"/airvpn.conf
    '';
  };

  # so we can forward traffic from the transmission network namespace
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  systemd.services.transmission = {
    after = [ "transmission-netns.service" ];
    wants = [ "transmission-netns.service" ];
    bindsTo = [ "netns@transmission.service" ];
    serviceConfig = {
      NetworkNamespacePath = "/var/run/netns/transmission";
      # https://github.com/NixOS/nixpkgs/issues/258793
      RootDirectoryStartOnly = lib.mkForce false;
      RootDirectory = lib.mkForce "";
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
      # increase file descriptor limit to handle many torrents/peers
      LimitNOFILE = 65536;
    };
  };
  clan.core.vars.generators.yellow-container = {
    files."yellow.sync.key" = { };
    files."yellow.sync.pub".secret = false;
    runtimeInputs = with pkgs; [
      coreutils
      openssh
    ];
    script = ''
      ssh-keygen -t ed25519 -N "" -f "$out"/yellow.sync.key
      mv "$out"/yellow.sync.key.pub "$out"/yellow.sync.pub
    '';
  };
}
