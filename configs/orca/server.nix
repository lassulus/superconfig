# Headless Orca runtime (https://onorca.dev), reachable over retiolum.
# Agents, terminals and worktrees run as the orca user; log in as orca to
# set up agents and to clone repos.
# Pairing URL for a client (Settings → Remote Orca Servers → Add Server):
#   journalctl -u orca-server | grep 'Pairing URL'
{
  self,
  config,
  pkgs,
  ...
}:
let
  inherit (self.packages.${pkgs.system}) orca;
  port = 6768;
in
{
  users.users.orca = {
    isNormalUser = true;
    home = "/home/orca";
    createHome = true;
    group = "users";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      self.keys.ssh.barnacle.public
      self.keys.ssh.yubi_pgp.public
      self.keys.ssh.termux_massulus.public
      self.keys.ssh.yubi1.public
      self.keys.ssh.yubi2.public
      self.keys.ssh.solo2.public
      self.keys.ssh.ignavia.public
      self.keys.ssh.phonetpm_massulus.public
      self.keys.ssh.massulus.public
    ];
    packages = [
      orca
      pkgs.omp
      # GitHub issues/PRs in the work item lists.
      pkgs.gh
    ];
  };

  systemd.services.orca-server = {
    description = "Orca headless runtime";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Terminals and agents started by Orca inherit this, so give them the
    # same tools as an interactive login of the orca user.
    path = [
      "/run/wrappers"
      "/etc/profiles/per-user/orca"
      "/run/current-system/sw"
    ];
    serviceConfig = {
      ExecStart = "${orca}/bin/orca serve --port ${toString port} --pairing-address ${config.networking.hostName}.r";
      Restart = "on-failure";
      RestartSec = 10;
      User = "orca";
      Group = "users";
      WorkingDirectory = "/home/orca";
    };
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];
}
