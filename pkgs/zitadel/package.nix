# Based on nixpkgs PR 561044 (https://github.com/NixOS/nixpkgs/pull/561044,
# zitadel 4.17.3), without the separate Login V2 app.
{
  stdenv,
  buildGoModule,
  callPackage,
  fetchFromGitHub,
  lib,

  buf,
  cacert,
  dart-sass,
  grpc-gateway,
  protoc-gen-connect-go,
  protoc-gen-go,
  protoc-gen-go-grpc,
  protoc-gen-validate,
  statik,
}:

let
  version = "4.19.5";
  zitadelRepo = fetchFromGitHub {
    owner = "zitadel";
    repo = "zitadel";
    tag = "v${version}";
    hash = "sha256-FFXsoBlbNTFT1FSxs/IomqTrtNGqsxq9Ck5TSDpSWHM=";
  };
  goModulesHash = "sha256-8/TkV1JTKNSIknzEPbTDWzcOZQ6jCEkc6vSLLhdLYrs=";

  # protoc plugins inside the repository (`go install ./internal/protoc/...`
  # upstream)
  buildZitadelProtocGen =
    name:
    buildGoModule {
      pname = "protoc-gen-${name}";
      inherit version;

      src = zitadelRepo;

      proxyVendor = true;
      vendorHash = goModulesHash;

      subPackages = [ "internal/protoc/protoc-gen-${name}" ];

      doCheck = false;
    };

  protoc-gen-authoption = buildZitadelProtocGen "authoption";
  protoc-gen-zitadel = buildZitadelProtocGen "zitadel";

  # Descriptor set of proto/. buf fetches the dependencies pinned in
  # proto/buf.lock from the Buf Schema Registry, so this is the one
  # fixed-output step; the code generators run offline against it.
  protoImage = stdenv.mkDerivation {
    pname = "zitadel-proto-image";
    inherit version;

    src = zitadelRepo;

    nativeBuildInputs = [
      buf
      cacert
    ];

    buildPhase = ''
      runHook preBuild
      HOME=$TMPDIR buf build proto -o image.binpb
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp image.binpb $out
      runHook postInstall
    '';

    outputHashMode = "flat";
    outputHash = "sha256-vsVaGO6ewwCMkK1Qh/8/JZblwICnszmfZxXAPFIAdOk=";
  };

  generateProtobufCode =
    {
      pname,
      version,
      nativeBuildInputs ? [ ],
      bufArgs ? "",
      workDir ? ".",
      outputPath,
    }:
    stdenv.mkDerivation {
      pname = "${pname}-buf-generated";
      inherit version;

      src = zitadelRepo;

      nativeBuildInputs = nativeBuildInputs ++ [ buf ];

      buildPhase = ''
        runHook preBuild
        cd ${workDir}
        HOME=$TMPDIR buf generate ${protoImage}#format=binpb ${bufArgs}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        cp -r ${outputPath} $out
        runHook postInstall
      '';
    };

  jsDeps = callPackage ./javascript.nix { inherit protoImage version zitadelRepo; };

  # the `generate-stubs` target of apps/api/project.json
  protobufGenerated = generateProtobufCode {
    pname = "zitadel";
    inherit version;
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-authoption
      protoc-gen-connect-go
      protoc-gen-go
      protoc-gen-go-grpc
      protoc-gen-validate
      protoc-gen-zitadel
    ];
    outputPath = ".artifacts";
  };
in
buildGoModule (finalAttrs: {
  pname = "zitadel";
  inherit version;

  src = zitadelRepo;

  nativeBuildInputs = [
    dart-sass
    statik
  ];

  postPatch = ''
    substituteInPlace internal/api/ui/login/static/resources/generate.go \
      --replace-fail "pnpm sass" "sass"
  '';

  proxyVendor = true;
  vendorHash = goModulesHash;
  ldflags = [
    "-s"
    "-w"
    "-X 'github.com/zitadel/zitadel/cmd/build.version=${version}'"
  ];

  # The other Go packages are docs snippets and test helpers.
  subPackages = [ "." ];

  # The generate-stubs, generate-statik, generate-assets and build-console
  # targets of apps/api/project.json.
  preBuild = ''
    # zitadel warns on every invocation without a build date
    ldflags+=" -X github.com/zitadel/zitadel/cmd/build.date=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"

    mkdir -p pkg/grpc
    cp -r ${protobufGenerated}/grpc/github.com/zitadel/zitadel/pkg/grpc/* pkg/grpc
    mkdir -p openapi/v2/zitadel
    cp -r ${protobufGenerated}/grpc/zitadel/ openapi/v2/zitadel

    go generate internal/api/ui/login/static/resources/generate.go
    go generate internal/api/ui/login/statik/generate.go
    go generate internal/notification/statik/generate.go
    go generate internal/statik/generate.go

    mkdir -p apps/docs/content/apis/assets
    go run internal/api/assets/generator/asset_generator.go \
      -directory=internal/api/assets/generator/ \
      -assets=apps/docs/content/apis/assets/assets.mdx

    find internal/api/ui/console/static -mindepth 1 ! -name gitkeep -delete
    cp -r ${finalAttrs.passthru.console}/* internal/api/ui/console/static
  '';

  doCheck = false;

  installPhase = ''
    runHook preInstall
    install -Dm755 $GOPATH/bin/zitadel $out/bin/zitadel
    runHook postInstall
  '';

  passthru = {
    console = callPackage (import ./console.nix {
      inherit
        generateProtobufCode
        jsDeps
        version
        zitadelRepo
        ;
    }) { };
    inherit protoImage;
    inherit (jsDeps) pnpmDeps;
  };

  meta = {
    description = "Identity and access management platform";
    homepage = "https://zitadel.com/";
    downloadPage = "https://github.com/zitadel/zitadel/releases";
    changelog = "https://github.com/zitadel/zitadel/releases/tag/v${version}";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    license = lib.licenses.agpl3Only;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    mainProgram = "zitadel";
  };
})
