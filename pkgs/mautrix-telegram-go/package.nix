{
  lib,
  buildGoModule,
  fetchFromGitHub,
  versionCheckHook,
}:

# The Go (bridgev2) rewrite of mautrix-telegram; nixpkgs still only has the
# Python 0.15.3 as pkgs.mautrix-telegram. Based on the open nixpkgs PR
# https://github.com/NixOS/nixpkgs/pull/510662 (pkgs/by-name/ma/mautrix-telegram-go),
# drop this once nixpkgs has it. Built with goolm (pure-Go olm) like our other
# bridges instead of the insecure libolm.
buildGoModule (finalAttrs: {
  pname = "mautrix-telegram";
  # only v26.04-v26.09 migrate a Python bridge (0.15.x) database in place,
  # later releases refuse it, so styx has to run v26.09 once before them
  version = "26.11";
  tag = "v0.2611.0";

  src = fetchFromGitHub {
    owner = "mautrix";
    repo = "telegram";
    inherit (finalAttrs) tag;
    hash = "sha256-z3jfjQyh47scBjHNThLn5DluSSS4fT21NAibWyD5Iqc=";
  };

  vendorHash = "sha256-byvTXR7gy6b/TIVfJ8bwMC/D9vqn6iwjoxBE1gkBNBc=";

  tags = [ "goolm" ];

  subPackages = [ "cmd/mautrix-telegram" ];
  ldflags = [
    "-X"
    "main.Tag=${finalAttrs.tag}"
  ];

  # as in the nixpkgs PR
  doCheck = false;

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    homepage = "https://github.com/mautrix/telegram";
    description = "Matrix-Telegram puppeting bridge";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "mautrix-telegram";
  };
})
