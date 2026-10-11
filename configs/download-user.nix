{ self, ... }:
{
  users.users.download = {
    isNormalUser = true;
    home = "/home/download";
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
      self.keys.ssh.xerxes.public
      self.keys.ssh.ignavia.public
      self.keys.ssh.phonetpm_massulus.public
      self.keys.ssh.massulus.public
      self.inputs.kartei.users.makefu.pubkey
    ];
  };

  fileSystems."/home/download/yellow" = {
    device = "/var/download";
    fsType = "none";
    options = [
      "bind"
      "ro"
      "nofail"
      "x-systemd.automount"
    ];
  };
}
