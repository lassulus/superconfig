{
  lib,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/ssh-redirect.nix
    ../../configs/retiolum.nix
    ../../configs/mailserver.nix
    ../../configs/roundcube.nix
    ../../configs/gsm-wiki.nix
    ../../configs/pair-programming.nix
    ../../configs/nginx.nix
    ../../configs/services/matrix
    ../../configs/services/matrix/proxy.nix
    ../../configs/services/matrix/cinny.nix
    ../../configs/services/matrix/bridges/mautrix-whatsapp.nix
    ../../configs/services/matrix/bridges/mautrix-signal.nix
    ../../configs/services/matrix/bridges/heisenbridge.nix
    ../../configs/services/matrix/bridges/mautrix-telegram.nix
    ../../configs/services/matrix/bridges/mautrix-discord.nix

    ../../configs/services/pad
    ../../configs/services/paint
    ../../configs/services/ntfy
    ../../configs/services/paperless

    ../../configs/hass/proxy.nix
    ../../configs/hermes-proxy.nix
    ../../configs/crit-proxy.nix

    # sync-containers
    ../../configs/services/flix/container-host.nix
    ../../configs/services/radio/container-host.nix
    ../../configs/hotdog-host.nix

    # irc bots
    ../../configs/mumble-reminder.nix

    # other containers
    ../../configs/riot.nix

    # proxying of services
    ../../configs/services/radio/proxy.nix
    ../../configs/services/flix/proxy.nix
    ../../configs/services/coms/jitsi.nix

    # dns
    ../../configs/dns/knot.nix

    # video strreaming
    ../../configs/cast.nix

    # c-base ollama tunnel
    ../../configs/c-base-ai-tunnel.nix

    # debug stuff
    ../../configs/websites/mergebot.lassul.us.nix

    # autoupdates
    ../../configs/autoupdate.nix

    # vaultwarden
    ../../configs/vaultwarden.nix

    # download user
    ../../configs/download-user.nix

    # caldav calendar
    ../../configs/radicale.nix

    # lassul.us website
    ../../configs/websites/lassulus.nix

    # where.is.lassul.us (location from home-assistant on a map)
    ../../configs/websites/where.is.lassul.us

    # wallpaper.lassul.us (realwallpaper rendered on demand)
    ../../configs/websites/wallpaper.lassul.us.nix

    # paste + cyberlocker
    ../../configs/paste

    # document signing
    ../../configs/docuseal.nix

    # timeful availability polls (when.lassul.us)
    ../../configs/timeful.nix

    # request-and-approve booking page (book.lassul.us)
    ../../configs/book.nix

    # backups
    ./backup.nix

    # IPFS
    ../../configs/services/flix/ipfs.nix

    # n2n supernode (n2n.lassul.us)
    ../../configs/n2n-supernode.nix

    # zitadel SSO IdP (id.lassul.us)
    ../../configs/zitadel.nix
    # "Your own provider" logins for zitadel (byoidc.lassul.us)
    ../../configs/byoidc.nix

    # ATProto PDS (pds.lassul.us)
    ../../configs/services/git

    # radicle public seed (radicle.lassul.us)
    ../../configs/radicle.lassul.us.nix
    # radicle identity + node for this machine (/var/lib/rad)
    ../../configs/rad.nix

    # self-hosted iroh relay (relay.lassul.us)
    ../../configs/iroh-relay

    # parley federated IRC-speaking chat (parley.lassul.us)
    ../../configs/parley.nix

    # nixpkgs PR triage dashboard (review.lassul.us)
    ../../configs/nixpkgs-triage.nix

    # binary cache (cache.lassul.us, niks3.lassul.us)
    ../../configs/nix-cache.nix
  ];

  # lassul.us shouldn't be the default vhost here (nginx.nix already sets one)
  services.nginx.virtualHosts."lassul.us" = {
    default = lib.mkForce false;
  };

  # riot VM (HFOS): fresh libvirt guest on a dedicated bridged public IP.
  # Bridged onto ext-br with its own Hetzner MAC, so libvirt manages no
  # firewall rules for it -> no nat-chain race, no restart-iptables hack (cf. hfos.nix).
  virtualisation.libvirtd.enable = true;
  security.polkit.enable = true;
  users.users.riot = {
    isNormalUser = true;
    extraGroups = [ "libvirtd" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCwcI8EKqUwYVd4IlnTTaNY3qVMDe2M1sVPMdWaTJ8FnAXixBcZozFHyJ9bvGn6c/vFGBEACZk6QCxC2+sTxbaodCOUIyhAtxqAGO7jINmGrVWjg2NW8qBi+e+ekr2+jlhizxgMPgMcbawuazpMzrozi6sfJfRelJRqe6TxrK/SBO+V5pf8v2ubAfHHF6bJrqAykC247d2NmsHEyM/nGOOb2AlJx2vrK1FbFWr2fBAvnhJww9wqrfDYSM6+oRF/vrYKkT9cU8yjtCkyaJZTqRufF2pzc9a0X3Z4LHEIUykAl2aVmi5Wzh8CZj3qCeVb9Ju0ZGQIa5pvG5CbH5SUJOr9y6zhTx1xbqL+JYGkJqgHPMOCFiNIvWnFaNlnvFf4C9KcTf/VMOEvNdDklpjoWm+ptuQIciAhWKuUHd/6MqaRjmlvUqjl49EkRvYOGn9vasKt66MYrtfvbZ3tcqh5w9EEKhrcygiUXhIJzhu2s1BseAVRLjCsQ24BNbzrYiCO+vuk8/hdeHB1rP6Sas2v7jvYb3zQd647OTq+HrZWN8aCjCs5h8Y0QxrQzsLru0zKDRaNDlbSshNBAw7PzSXQAf9fISH7v6sC4nstf5jk+87ua/7xjWG4NYp5Y9FMFCsuE3XVmUCAbauq18RmN6V4s2TxCEs9bxONO0Vba4zwPnvMlw== cardno:000619250765"
    ];
  };
  # the only forwarding the VM needs: accept traffic to/from its public IP.
  networking.firewall.extraForwardRules = ''
    ip daddr 95.217.192.52 accept
    ip saddr 95.217.192.52 accept
  '';

  # not defined by any module
  lass.backup.state.bot-home = {
    folders = [ "/home/bot" ];
    exclude = [
      "/home/bot/.cache"
      "/home/bot/.nix-defexpr"
      "/home/bot/.nix-profile"
    ];
  };

  # tank/radicle (radicle seed storage) is created by disko at install; on an
  # already-provisioned host it must be created before deploying:
  #   zfs create -o mountpoint=/var/lib/radicle -o quota=80G tank/radicle
  # nofail keeps a missing dataset from failing local-fs.target -> emergency
  # mode (which has no network and bricks the box).
  fileSystems."/var/lib/radicle".options = [ "nofail" ];

  # Fleet-wide safety net: this box is headless (Hetzner, console only via
  # KVM), so a failed critical target must never strand us at the emergency
  # shell. With emergency mode disabled systemd keeps booting instead of
  # dropping to a console -> network + sshd still come up, so a bad deploy
  # (e.g. a missing dataset, as happened once) leaves the box reachable to
  # fix and redeploy rather than bricked. Mirrors nixpkgs' headless profile.
  # Note: we intentionally do NOT auto-roll-back to the previous generation;
  # our config is pulled from git by system.autoUpgrade, so a rollback would
  # just re-pull the same broken config on the next run (a rollback loop).
  systemd.enableEmergencyMode = false;

  system.stateVersion = "24.05";
}
