{ config, pkgs, ... }:
{
  # jellyfin in the yellow container, forwarded below
  lass.ports = {
    "1900" = "jellyfin-dlna";
    "7359" = "jellyfin-discovery";
    "8096" = "jellyfin";
    "8920" = "jellyfin-https";
  };

  lass.sync-containers3.containers.yellow = {
    sshKey = config.clan.core.vars.generators.yellow-container.files."yellow.sync.key".path;
    startCommand = ''
      export PATH=$PATH:${pkgs.git}/bin
      until ${pkgs.dig.host}/bin/host github.com; do sleep 1; done
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild --refresh --flake github:lassulus/superconfig#yellow switch --no-write-lock-file
    '';
  };
  containers.yellow.bindMounts."/var/lib" = {
    hostPath = "/var/lib/sync-containers3/yellow/state";
    isReadOnly = false;
  };
  containers.yellow.bindMounts."/var/download" = {
    hostPath = "/var/download";
    isReadOnly = false;
  };

  networking.firewall.allowedTCPPorts = [
    config.lass.servicePorts.jellyfin
    config.lass.servicePorts.jellyfin-https
  ];
  networking.firewall.allowedUDPPorts = [
    config.lass.servicePorts.jellyfin-dlna
    config.lass.servicePorts.jellyfin-discovery
  ];
  containers.yellow.forwardPorts = [
    {
      hostPort = config.lass.servicePorts.jellyfin;
      containerPort = 8096;
      protocol = "tcp";
    }
    {
      hostPort = config.lass.servicePorts.jellyfin-https;
      containerPort = 8920;
      protocol = "tcp";
    }
    {
      hostPort = config.lass.servicePorts.jellyfin-dlna;
      containerPort = 1900;
      protocol = "udp";
    }
    {
      hostPort = config.lass.servicePorts.jellyfin-discovery;
      containerPort = 7359;
      protocol = "udp";
    }
  ];

  clan.core.vars.generators.yellow-container = {
    files."yellow.sync.key" = { };
    prompts.key.description = ''
      copy or reference the secret key from the container into here, so we can actually start/sync the container
    '';
    script = ''
      cat "$prompts"/key > "$out"/yellow.sync.key
    '';
  };
}
