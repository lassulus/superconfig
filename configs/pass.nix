{
  pkgs,
  self,
  ...
}:

{
  users.users.mainUser.packages = with pkgs; [
    self.packages.${pkgs.system}.passmenu
    self.packages.${pkgs.system}.pass
    gnupg
    (pkgs.writers.writeDashBin "unlock" ''
      set -efu
      HOST=$1

      pw=$(pass show "admin/$HOST/luks")
      torify sshn root@$(pass "hosts/$HOST/initrd/hostname") "echo $pw > /crypt-ramfs/passphrase"
    '')
  ];

  programs.gnupg.agent.enable = true;
  systemd.tmpfiles.rules = [
    "L+ /home/lass/.password-store - - - - sync/pwstore"
  ];

  # native messaging host of the passkey-firefox add-on (installed in our
  # firefox by tools/firefox): passkeys of this store, through pass. A user
  # tmpfiles rule, so a missing ~/.mozilla is created as lass, not root.
  systemd.user.tmpfiles.users.mainUser.rules = [
    "L+ %h/.mozilla/native-messaging-hosts/passkey_firefox.json - - - - ${
      self.packages.${pkgs.system}.passkey-firefox-host
    }/lib/mozilla/native-messaging-hosts/passkey_firefox.json"
  ];
}
