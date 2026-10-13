{
  stdenv,
  lib,
  fetchFromGitHub,
  fetchurl,
  nix-update-script,
  cmake,
  pkg-config,
  unzip,
  libX11,
  glfw,
  glew,
  fftw,
  fftwFloat,
  volk,
  zstd,
  libpulseaudio,
  orc,

  # Sources
  airspy_source ? true,
  airspy,
  airspyhf_source ? true,
  airspyhf,
  audio_source ? true,
  bladerf_source ? stdenv.hostPlatform.isLinux,
  libbladeRF,
  file_source ? true,
  hackrf_source ? true,
  hackrf,
  hermes_source ? true,
  hl2_source ? true,
  kiwisdr_source ? true,
  limesdr_source ? true,
  limesuite,
  network_source ? true,
  plutosdr_source ? stdenv.hostPlatform.isLinux,
  libiio,
  libad9361,
  rfspace_source ? true,
  rtl_sdr_source ? true,
  rtl-sdr-osmocom,
  libusb1,
  rtl_tcp_source ? true,
  sdrplay_source ? false,
  sdrplay,
  sdrpp_server_source ? true,
  soapy_source ? true,
  soapysdr-with-plugins,
  spectran_http_source ? true,
  spyserver_source ? true,
  usrp_source ? false,
  uhd,
  boost,

  # Sinks
  audio_sink ? true,
  rtaudio,
  mpeg_adts_sink ? false, # downloads lame at build time - disable for now
  network_sink ? true,
  portaudio_sink ? false,
  portaudio,

  # Decoders
  atv_decoder ? true,
  ch_extravhf_decoder ? false, # requires itpp/mbe libraries
  ch_tetra_demodulator ? true,
  dab_decoder ? false,
  falcon9_decoder ? false,
  ft8_decoder ? true,
  kg_sstv_decoder ? false,
  m17_decoder ? false,
  codec2,
  meteor_demodulator ? true,
  pager_decoder ? true,
  radio ? true,
  weather_sat_decoder ? false,

  # Misc
  discord_presence ? true,
  frequency_manager ? true,
  iq_exporter ? true,
  recorder ? true,
  rigctl_client ? true,
  rigctl_server ? true,
  scanner ? true,
  noise_reduction ? true,
}:

let
  # ETSI TETRA codec - pre-fetched to avoid network access during build
  etsiCodec = fetchurl {
    url = "http://www.etsi.org/deliver/etsi_en/300300_300399/30039502/01.03.01_60/en_30039502v010301p0.zip";
    hash = "sha256-H+GMR3PIzLUu8jyltKCwhBs41U3dXZx9huuLBg8TLzk=";
    # etsi.org answers 403 to curl's default user agent
    curlOptsList = [
      "-A"
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    ];
  };
in
stdenv.mkDerivation (_finalAttrs: {
  pname = "sdrpp-brown";

  version = "0-unstable-2026-08-12";

  src = fetchFromGitHub {
    owner = "sannysanoff";
    repo = "SDRPlusPlusBrown";
    rev = "5fca05446b3f985ab49c7c3c257980aaf2ec34fe";
    hash = "sha256-CYiw61DaosK7xMpCmwjy18AEcASJgsIhI+T4NtsLUrM=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
  ]
  ++ lib.optional ch_tetra_demodulator unzip;

  buildInputs = [
    glfw
    glew
    fftw
    fftwFloat
    volk
    zstd
    orc
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux libX11
  ++ lib.optional stdenv.hostPlatform.isLinux libpulseaudio
  ++ lib.optional airspy_source airspy
  ++ lib.optional airspyhf_source airspyhf
  ++ lib.optional bladerf_source libbladeRF
  ++ lib.optional hackrf_source hackrf
  ++ lib.optional limesdr_source limesuite
  ++ lib.optionals rtl_sdr_source [
    rtl-sdr-osmocom
    libusb1
  ]
  ++ lib.optional sdrplay_source sdrplay
  ++ lib.optional soapy_source soapysdr-with-plugins
  ++ lib.optionals plutosdr_source [
    libiio
    libad9361
  ]
  ++ lib.optionals usrp_source [
    uhd
    boost
  ]
  ++ lib.optional (audio_source || audio_sink) rtaudio
  ++ lib.optional portaudio_sink portaudio
  ++ lib.optional (dab_decoder || m17_decoder) codec2;

  # Pre-place the ETSI codec in the build directory so CMake doesn't try to download it
  preConfigure = lib.optionalString ch_tetra_demodulator ''
    mkdir -p build/decoder_modules/ch_tetra_demodulator/etsi_codec
    cp ${etsiCodec} build/decoder_modules/ch_tetra_demodulator/etsi_codec/etsi_tetra_codec.zip
  '';

  cmakeFlags = [
    # Sources
    (lib.cmakeBool "OPT_BUILD_AIRSPYHF_SOURCE" airspyhf_source)
    (lib.cmakeBool "OPT_BUILD_AIRSPY_SOURCE" airspy_source)
    (lib.cmakeBool "OPT_BUILD_AUDIO_SOURCE" audio_source)
    (lib.cmakeBool "OPT_BUILD_BLADERF_SOURCE" bladerf_source)
    (lib.cmakeBool "OPT_BUILD_FILE_SOURCE" file_source)
    (lib.cmakeBool "OPT_BUILD_HACKRF_SOURCE" hackrf_source)
    (lib.cmakeBool "OPT_BUILD_HERMES_SOURCE" hermes_source)
    (lib.cmakeBool "OPT_BUILD_HL2_SOURCE" hl2_source)
    (lib.cmakeBool "OPT_BUILD_KIWISDR_SOURCE" kiwisdr_source)
    (lib.cmakeBool "OPT_BUILD_LIMESDR_SOURCE" limesdr_source)
    (lib.cmakeBool "OPT_BUILD_NETWORK_SOURCE" network_source)
    (lib.cmakeBool "OPT_BUILD_PLUTOSDR_SOURCE" plutosdr_source)
    (lib.cmakeBool "OPT_BUILD_RFSPACE_SOURCE" rfspace_source)
    (lib.cmakeBool "OPT_BUILD_RTL_SDR_SOURCE" rtl_sdr_source)
    (lib.cmakeBool "OPT_BUILD_RTL_TCP_SOURCE" rtl_tcp_source)
    (lib.cmakeBool "OPT_BUILD_SDRPLAY_SOURCE" sdrplay_source)
    (lib.cmakeBool "OPT_BUILD_SDRPP_SERVER_SOURCE" sdrpp_server_source)
    (lib.cmakeBool "OPT_BUILD_SOAPY_SOURCE" soapy_source)
    (lib.cmakeBool "OPT_BUILD_SPECTRAN_HTTP_SOURCE" spectran_http_source)
    (lib.cmakeBool "OPT_BUILD_SPYSERVER_SOURCE" spyserver_source)
    (lib.cmakeBool "OPT_BUILD_USRP_SOURCE" usrp_source)

    # Sinks
    (lib.cmakeBool "OPT_BUILD_AUDIO_SINK" audio_sink)
    (lib.cmakeBool "OPT_BUILD_MPEG_ADTS_SINK" mpeg_adts_sink)
    (lib.cmakeBool "OPT_BUILD_NETWORK_SINK" network_sink)
    (lib.cmakeBool "OPT_BUILD_NEW_PORTAUDIO_SINK" portaudio_sink)

    # Decoders
    (lib.cmakeBool "OPT_BUILD_ATV_DECODER" atv_decoder)
    (lib.cmakeBool "OPT_BUILD_CH_EXTRAVHF_DECODER" ch_extravhf_decoder)
    (lib.cmakeBool "OPT_BUILD_CH_TETRA_DEMODULATOR" ch_tetra_demodulator)
    (lib.cmakeBool "OPT_BUILD_DAB_DECODER" dab_decoder)
    (lib.cmakeBool "OPT_BUILD_FALCON9_DECODER" falcon9_decoder)
    (lib.cmakeBool "OPT_BUILD_FT8_DECODER" ft8_decoder)
    (lib.cmakeBool "OPT_BUILD_KG_SSTV_DECODER" kg_sstv_decoder)
    (lib.cmakeBool "OPT_BUILD_M17_DECODER" m17_decoder)
    (lib.cmakeBool "OPT_BUILD_METEOR_DEMODULATOR" meteor_demodulator)
    (lib.cmakeBool "OPT_BUILD_PAGER_DECODER" pager_decoder)
    (lib.cmakeBool "OPT_BUILD_RADIO" radio)
    (lib.cmakeBool "OPT_BUILD_WEATHER_SAT_DECODER" weather_sat_decoder)

    # Misc
    (lib.cmakeBool "OPT_BUILD_DISCORD_PRESENCE" discord_presence)
    (lib.cmakeBool "OPT_BUILD_FREQUENCY_MANAGER" frequency_manager)
    (lib.cmakeBool "OPT_BUILD_IQ_EXPORTER" iq_exporter)
    (lib.cmakeBool "OPT_BUILD_RECORDER" recorder)
    (lib.cmakeBool "OPT_BUILD_RIGCTL_CLIENT" rigctl_client)
    (lib.cmakeBool "OPT_BUILD_RIGCTL_SERVER" rigctl_server)
    (lib.cmakeBool "OPT_BUILD_SCANNER" scanner)
    (lib.cmakeBool "OPT_BUILD_NOISE_REDUCTION_LOGMMSE" noise_reduction)
  ];

  env.NIX_CFLAGS_COMPILE = "-fpermissive";

  hardeningDisable = lib.optional stdenv.cc.isClang "format";

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--version=branch"
      "--version-regex"
      "(0-unstable-.*)"
      "--system"
      "x86_64-linux"
    ];
  };

  meta = {
    description = "SDR++ Brown Edition - Cross-Platform SDR Software with KiwiSDR support";
    homepage = "https://github.com/sannysanoff/SDRPlusPlusBrown";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "sdrpp";
  };
})
