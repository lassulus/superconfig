{
  lib,
  python3Packages,
  fetchurl,
  stdenv,
  autoPatchelfHook,
}:
let
  # Per-platform wheels; versions can differ because upstream stopped shipping
  # macOS wheels after 0.3.44. Maintained by ./update.sh.
  wheels = lib.importJSON ./wheels.json;

  wheel =
    wheels.${stdenv.hostPlatform.system}
      or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");
in
python3Packages.buildPythonPackage {
  pname = "vosk";
  inherit (wheel) version;
  format = "wheel";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/py3/v/vosk/vosk-${wheel.version}-py3-none-${wheel.tag}.whl";
    inherit (wheel) hash;
  };

  # Only the Linux wheels ship ELF libraries; the macOS one is Mach-O.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  dependencies = with python3Packages; [
    cffi
    requests
    tqdm
    srt
    websockets
  ];

  # Skip tests as they require audio files and models
  doCheck = false;

  pythonImportsCheck = [ "vosk" ];

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Offline speech recognition API based on Kaldi and Vosk";
    homepage = "https://alphacephei.com/vosk/";
    license = lib.licenses.asl20;
    platforms = lib.attrNames wheels;
  };
}
