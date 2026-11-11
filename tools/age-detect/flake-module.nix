{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # ykman only names the YubiKey (serial -> yubi1/yubi2), after SE, TPM,
      # phonetpm and gpg. Its python3 keeps apple-sdk and llvm at runtime on
      # darwin (~1.4 GiB), so reference it by store path without context
      # and let nix substitute it on first use.
      yubikey-manager = builtins.unsafeDiscardStringContext pkgs.yubikey-manager.outPath;
      lazy-ykman = pkgs.writeShellScriptBin "ykman" ''
        [ -e ${yubikey-manager} ] || nix-store --realise ${yubikey-manager} >/dev/null
        exec ${yubikey-manager}/bin/ykman "$@"
      '';
    in
    {
      packages.age-detect =
        (pkgs.writeShellApplication {
          name = "age-detect";
          runtimeInputs =
            with pkgs;
            [
              age
              age-plugin-yubikey
              age-plugin-fido2-hmac
              age-plugin-tpm
              lazy-ykman
              libfido2
            ]
            ++ (pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.age-plugin-se
            ]);
          text = builtins.readFile ./age-detect;
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
