{
  # Hetzner storage box; what gets backed up is declared next to each service
  # (lass.backup.state).
  lass.backup = {
    repo = "u550643@u550643.your-storagebox.de:/./neoprism";
    sshPort = 23;
    knownHosts = ''
      [u550643.your-storagebox.de]:23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs
    '';
  };
}
