# Package overrides for the phone massulus (droidNixConfigurations.massulus),
# to keep its closure small. CI builds the overridden packages on aarch64.
final: prev: {
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

  # services.pipewire: only the pipe sink to the droid-nix app and the pulse
  # server; no ALSA, bluetooth, cameras, desktop or network audio
  pipewire-phone =
    (prev.pipewire.override {
      bluezSupport = false;
      enableSystemd = false;
      ffadoSupport = false;
      raopSupport = false;
      rocSupport = false;
      vulkanSupport = false;
      x11Support = false;
      zeroconfSupport = false;
    }).overrideAttrs
      (old: {
        # later -D options win
        mesonFlags =
          old.mesonFlags
          ++ map (o: "-D${o}=disabled") [
            "alsa"
            "avb"
            "compress-offload"
            "dbus"
            "ebur128"
            "echo-cancel-webrtc"
            "ffmpeg"
            "fftw"
            "gstreamer"
            "gstreamer-device-provider"
            "jack"
            "libcamera"
            "libmysofa"
            "libpulse"
            "libusb"
            "logind"
            "lv2"
            "opus"
            "pipewire-alsa"
            "pipewire-v4l2"
            "pw-cat"
            "pw-cat-ffmpeg"
            "selinux"
            "sndfile"
            "udev"
            "v4l2"
          ];
      });

  wireplumber-phone = prev.wireplumber.override { pipewire = final.pipewire-phone; };

  # mpv for the terminal (--vo=tct, audio through pipewire-phone): no
  # desktop, disc or hardware decoding support, no yt-dlp
  mpv-phone =
    (prev.mpv-unwrapped.override {
      pipewire = final.pipewire-phone;
      ffmpeg = final.ffmpeg-phone;
      libplacebo = prev.libplacebo.override { vulkanSupport = false; };
      alsaSupport = false;
      archiveSupport = false;
      bluraySupport = false;
      cacaSupport = false;
      cddaSupport = false;
      cmsSupport = false;
      drmSupport = false;
      dvbinSupport = false;
      dvdnavSupport = false;
      jackaudioSupport = false;
      javascriptSupport = false;
      openalSupport = false;
      pulseSupport = false;
      rubberbandSupport = false;
      sdl2Support = false;
      sixelSupport = false;
      vaapiSupport = false;
      vapoursynthSupport = false;
      vdpauSupport = false;
      vulkanSupport = false;
      waylandSupport = false;
      x11Support = false;
      zimgSupport = false;
    }).overrideAttrs
      (old: {
        # umpv is a python script (python3: 137 MiB)
        postFixup = old.postFixup + ''
          rm $out/bin/umpv $out/share/applications/umpv.desktop
        '';
      });

  # decoders and network streams for mpv-phone; no encoders, devices or
  # hardware acceleration
  ffmpeg-phone = prev.ffmpeg-headless.override {
    withAlsa = false;
    withAom = false;
    withBluray = false;
    withDrm = false;
    withMp3lame = false;
    withOpenapv = false;
    withOpencl = false;
    withOpenjpeg = false;
    withOpenmpt = false;
    withRist = false;
    withSpeex = false;
    withSrt = false;
    withSsh = false;
    withSvtav1 = false;
    withTheora = false;
    withV4l2 = false;
    withVaapi = false;
    withVidStab = false;
    withVpx = false;
    withVulkan = false;
    withWebp = false;
    withX264 = false;
    withX265 = false;
    withXvid = false;
    withZvbi = false;
  };
}
