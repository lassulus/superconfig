# Package overrides for the phone massulus (droidNixConfigurations.massulus),
# to keep its closure small. CI builds the overridden packages on aarch64.
_final: prev: {
  # icu4c (40 MiB) only came in via nix's boost
  boost189 = prev.boost189.override { enableIcu = false; };

  # aws-crt-cpp and the aws-c-* libraries (8 MiB) are only for s3:// stores
  nix = prev.nix.overrideScope (
    _: scope: { nix-store = scope.nix-store.override { withAWS = false; }; }
  );

  # not named gitMinimal: overriding that would rebuild everything that uses
  # git at build time
  git-phone =
    (prev.gitMinimal.override {
      # translations (14 MiB)
      nlsSupport = false;
    }).overrideAttrs
      (old: {
        # git-sh-i18n.sh keeps a dead reference to gettext (25 MiB) even
        # with NO_GETTEXT
        postPatch = old.postPatch + ''
          substituteInPlace git-sh-i18n.sh --replace-fail ${prev.gettext} /no-gettext
        '';
        # Each helper binary carries its own copy of libgit (3 MiB each), and
        # bin/ has copies of libexec/git-core/ binaries.
        postInstall = old.postInstall + ''
          rm -r $out/libexec/git-core/{git-imap-send,git-http-push,git-daemon,git-http-backend,git-shell,scalar} \
            $out/bin/{git-http-backend,git-shell,scalar} $out/share/{git-gui,gitk}
          ln -sf ../libexec/git-core/git $out/bin/git
        '';
        # the test suite runs the removed helpers
        doInstallCheck = false;
      });
}
