{
  generateProtobufCode,
  jsDeps,
  version,
  zitadelRepo,
}:

{
  lib,
  stdenv,
  callPackage,

  grpc-gateway,
  nodejs,
  pnpmConfigHook,
  protoc-gen-grpc-web,
}:

let
  # console/buf.gen.yaml (`buf generate ../proto --include-imports
  # --include-wkt` upstream), run against protoImage. It needs protoc-gen-js
  # 4.0.2 to match the google-protobuf runtime of console/package.json.
  consoleProtobufGenerated = generateProtobufCode {
    pname = "zitadel-console";
    inherit version;
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-grpc-web
      (callPackage ./protoc-gen-js.nix { })
    ];
    workDir = "console";
    bufArgs = "--include-imports --include-wkt";
    outputPath = "src/app/proto/generated";
  };
in
stdenv.mkDerivation {
  pname = "zitadel-console";
  inherit version;

  src = zitadelRepo;

  inherit (jsDeps) pnpmDeps;
  pnpmWorkspaces = [
    "@zitadel/client"
    "@zitadel/console"
    "@zitadel/proto"
  ];

  nativeBuildInputs = [
    nodejs
    jsDeps.pnpm
    pnpmConfigHook
  ];

  env.NODE_OPTIONS = "--max-old-space-size=8192";

  preBuild = ''
    cp -r ${jsDeps.protoPackageGenerated}/* packages/zitadel-proto/
    mkdir -p console/src/app/proto
    cp -r ${consoleProtobufGenerated} console/src/app/proto/generated
    chmod -R u+w packages/zitadel-proto console/src/app/proto
  '';

  # The `build` scripts of the client package and the console, in the order
  # nx.json's targetDefaults run them.
  buildPhase = ''
    runHook preBuild

    pushd packages/zitadel-client
    pnpm run build
    popd

    pushd console
    pnpm run build
    popd

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r console/dist/console "$out"
    runHook postInstall
  '';

  meta = {
    description = "Management console for the ZITADEL identity and access management platform";
    homepage = "https://zitadel.com/";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
