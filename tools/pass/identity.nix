# age identity detection shared by tools/pass and tools/passless: the age
# plugins the identities need on PATH and a bash snippet defining
# detect_identity.
{
  self,
  pkgs,
  system,
}:
{
  runtimeInputs = [
    pkgs.age-plugin-fido2-hmac
    pkgs.age-plugin-yubikey
    pkgs.age-plugin-tpm
    self.packages.${system}.age-plugin-gpg
    self.packages.${system}.age-detect
    # age-plugin-phone: encrypts to the phonetpm recipient, decrypts via the daemon
    self.packages.${system}.phonetpm
  ]
  ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [
    self.packages.${system}.pinentry-rofi-age
  ])
  ++ (pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.age-plugin-se
  ])
  ++ (pkgs.lib.optionals (!pkgs.stdenv.isDarwin) [
    # Dummy age-plugin-se for Linux (encryption only, no Secure Enclave hardware)
    (pkgs.writeShellScriptBin "age-plugin-se" ''
      exec env PYTHONUNBUFFERED=1 ${
        pkgs.python3.withPackages (ps: [ ps.cryptography ])
      }/bin/python3 ${./age-plugin-se-dummy.py} "$@"
    '')
  ]);

  # detect_identity: sets KEY_TYPE/DETECTED_KEY/IDENTITY_FILE via age-detect
  # and exports PASSAGE_IDENTITIES_FILE when it wrote an identity file. The
  # EXIT trap removes that file, so callers must not exec.
  detectIdentity = ''
    detect_identity() {
      # Always detect available age keys first
      export AGE_DETECT_KEYS_DIR="${
        builtins.path {
          path = self + "/keys";
          name = "keys";
        }
      }"
      eval "$(age-detect)"

      # Set up identity file if detected
      if [[ -n "''${IDENTITY_FILE:-}" ]]; then
        export PASSAGE_IDENTITIES_FILE="$IDENTITY_FILE"
        trap 'rm -f "$IDENTITY_FILE"' EXIT
      fi
    }
  '';
}
