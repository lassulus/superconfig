{ config, pkgs, ... }:
let
  cbaseUser = "lassulus";
  cbaseHost = "tunnel.c-base.org";
  remoteHost = "ai.cbrp3.c-base.org";
  port = 11434;
  sshKey = config.clan.core.vars.generators.c-base-ai-tunnel.files."id_ed25519".path;
  knownHosts = pkgs.writeText "c-base-ai-tunnel-known_hosts" ''
    tunnel.c-base.org ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKDknNl4M2WZChp1N/eRIpem2AEOceGIqvjo0ptBuwxUn0w0B8MGTVqoI+pnUVypORJRoNrLPOAkmEVr32BDN3E=
    tunnel.c-base.org ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDgTvns7Gh4smL6kyau2TpVz35z5rJgmI7B/nSYKr/nD203ZJIkZkwHe/yHCz1AwTjx0/tg75lxrz5fGZLATAlS/gXsf97T+2m9XkXRShva5t8WJNUxktOySLv8X68VKYqN3GPgdi2p+4A1yAZvIERIHCS7fJ5wvbe41Z+vABxeVQ1aR48Q0YQ4v4q9KlpoRvU5U9QdHjVZxHkIu5GeMcD+uh54eEvbwdk0sYcF5/fO+tsz0yS3uyMnGOq718UMWHRLiubCJCPefz7FlGBRfbAFArIp7QF7BMWox6YZIk1aCDfB+0U/Tk8Mhp0B4twq5xRaTqOSkHl9QuBUvrKjR0S9
  '';
in
{
  lass.ports.${toString port} = "c-base-ai-tunnel";

  clan.core.vars.generators.c-base-ai-tunnel = {
    files."id_ed25519" = {
      owner = "c-base-tunnel";
      mode = "0400";
    };
    files."id_ed25519.pub".secret = false;
    runtimeInputs = with pkgs; [ openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "neoprism c-base ai tunnel" -f "$out/id_ed25519"
    '';
  };

  users.users.c-base-tunnel = {
    isSystemUser = true;
    group = "c-base-tunnel";
    home = "/var/lib/c-base-tunnel";
    createHome = true;
    shell = pkgs.bashInteractive;
  };
  users.groups.c-base-tunnel = { };

  services.autossh.sessions = [
    {
      name = "c-base-ai";
      user = "c-base-tunnel";
      monitoringPort = 0;
      extraArguments = builtins.concatStringsSep " " [
        "-N"
        "-o ServerAliveInterval=30"
        "-o ServerAliveCountMax=3"
        "-o ExitOnForwardFailure=yes"
        "-o StrictHostKeyChecking=yes"
        "-o UserKnownHostsFile=${knownHosts}"
        "-o IdentitiesOnly=yes"
        "-i ${sshKey}"
        "-L *:${toString port}:${remoteHost}:${toString port}"
        "${cbaseUser}@${cbaseHost}"
      ];
    }
  ];

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];
}
