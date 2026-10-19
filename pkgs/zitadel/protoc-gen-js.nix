{
  stdenv,
  gcc14Stdenv,
  lib,
  buildBazelPackage,
  bazel_7,
  fetchFromGitHub,
  cctools,
}:

let
  # fails to build with gcc15, see https://github.com/NixOS/nixpkgs/issues/475586
  buildBazelPackage' =
    if stdenv.cc.isGNU then
      buildBazelPackage.override {
        stdenv = gcc14Stdenv;
      }
    else
      buildBazelPackage;

  # Since 4.0.0 the project resolves its dependencies with bzlmod. Bazel needs
  # the registry in the sandboxed build phase as well, so a checkout of the
  # Bazel Central Registry is pinned.
  registry = fetchFromGitHub {
    owner = "bazelbuild";
    repo = "bazel-central-registry";
    rev = "0f256a72067e42d62bb568cc2619f98deed139e2";
    hash = "sha256-OcMLg0KiAQOJZLH8r+QkeQ9bxcEc4L0dCgyUv5PkLQk=";
  };
in
buildBazelPackage' rec {
  pname = "protoc-gen-js";
  version = "4.0.2";

  src = fetchFromGitHub {
    owner = "protocolbuffers";
    repo = "protobuf-javascript";
    rev = "v${version}";
    hash = "sha256-vFTR7dwquZht4st90bFQ9CJMYBPbL+DWO0uQ3xsXIBU=";
  };

  bazel = bazel_7;
  bazelFlags = [
    "--registry"
    "file://${registry}"
  ];
  bazelTargets = [ "generator:protoc-gen-js" ];
  bazelBuildFlags = lib.optionals stdenv.cc.isClang [
    "--cxxopt=-x"
    "--cxxopt=c++"
    "--host_cxxopt=-x"
    "--host_cxxopt=c++"
  ];
  removeRulesCC = false;

  env = lib.optionalAttrs stdenv.hostPlatform.isDarwin {
    LIBTOOL = "${cctools}/bin/libtool";
  };

  fetchAttrs = {
    # Repositories Bazel generates by inspecting the build host (store paths,
    # host CPU) stay out of the deps tarball; the build phase regenerates them.
    # With bzlmod their names carry the extension prefix (`~` on Bazel 7).
    preInstall = ''
      rm -rf "$bazelOut"/external/*[~+]{host_platform,local_config_*}
    '';

    hash = "sha256-bc+VwWhHzXIblFGYf8gfRTZvAiBY4L9L9texuJlxRYI=";
  };

  buildAttrs.installPhase = ''
    mkdir -p $out/bin
    install -Dm755 bazel-bin/generator/protoc-gen-js $out/bin/
  '';

  meta = {
    description = "Protobuf plugin for generating JavaScript code";
    mainProgram = "protoc-gen-js";
    homepage = "https://github.com/protocolbuffers/protobuf-javascript";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    license = with lib.licenses; [
      asl20
      bsd3
    ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
