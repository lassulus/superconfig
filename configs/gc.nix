{ config, lib, ... }:
{
  nix.gc = {
    automatic =
      !(
        lib.elem config.networking.hostName [
          "aergia"
          "ignavia"
          "mors"
          "coaxmetal"
        ]
        || config.boot.isContainer
      );
    options = "--delete-older-than 15d";
  };
}
