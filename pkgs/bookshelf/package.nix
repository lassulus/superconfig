{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  buildDotnetModule,
  dotnetCorePackages,
  sqlite,
  fetchYarnDeps,
  yarnConfigHook,
  yarnBuildHook,
  nodejs-slim,
  nix-update-script,
  writeText,
  # Metadata flavor: true = Hardcover (upstream's :hardcover image),
  # false = Goodreads-style Readarr metadata (upstream's :softcover image).
  hardcover ? true,
}:
let
  rid = dotnetCorePackages.systemToDotnetRid stdenvNoCC.hostPlatform.system;
in
# Built like nixpkgs' sonarr/lidarr: Readarr layout, .NET backend plus yarn
# frontend.
buildDotnetModule (finalAttrs: {
  pname = "bookshelf";
  version = "0-unstable-2026-09-11";

  src = fetchFromGitHub {
    owner = "pennydreadful";
    repo = "bookshelf";
    rev = "3ac41f7e31427684a37138e8e539b7e6c7b73869";
    hash = "sha256-iS4y1mS2B9HgMHfUsbizVwcNp07VDBT/lP6Lh4tFI7o=";
  };

  # Upstream still targets net6.0, which nixpkgs marks insecure; net8.0 builds
  # unchanged. Project references pick their own TargetFrameworks, so a
  # TargetFramework property alone is not enough.
  postPatch = ''
    mv src/NuGet.config NuGet.Config
    sed -i 's|<TargetFrameworks>net6.0</TargetFrameworks>|<TargetFrameworks>net8.0</TargetFrameworks>|' src/*/*.csproj
  '';

  strictDeps = true;
  __structuredAttrs = true; # for the Copyright property that contains spaces

  installPath = "${placeholder "out"}/lib/bookshelf/bin";

  postInstall = ''
    cp -a -- ${finalAttrs.passthru.frontend} "$dotnetInstallPath"/UI
    cp -- ${finalAttrs.passthru.package_info} "$dotnetInstallPath"/../package_info
  '';

  nugetDeps = ./deps.json;

  dotnet-sdk = dotnetCorePackages.sdk_8_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;

  runtimeDeps = [ sqlite ];

  # The flavor is not a build switch: upstream's images only differ in these
  # two variables, read at runtime. METADATA_URL is the default metadata
  # source (a value set in the UI wins), HARDCOVER=true lowers the minimum
  # popularity of the "Standard" metadata profile created on first start.
  makeWrapperArgs = lib.optionals hardcover [
    "--set-default"
    "METADATA_URL"
    "https://hardcover.bookinfo.pro"
    "--set-default"
    "HARDCOVER"
    "true"
  ];

  executables = [ "Readarr" ];

  projectFile = [
    "src/NzbDrone.Console/Readarr.Console.csproj"
    "src/NzbDrone.Mono/Readarr.Mono.csproj"
  ];

  dotnetFlags = [
    "--property:TargetFramework=net8.0"
    "--property:EnableAnalyzers=false"
    "--property:TreatWarningsAsErrors=false"
    # Override defaults in src/Directory.Build.props that use current time.
    "--property:Copyright=Copyright readarr.com (${finalAttrs.meta.license.fullName})"
    "--property:AssemblyVersion=${finalAttrs.versionForDotnet}"
    "--property:AssemblyConfiguration=develop"
    "--property:RuntimeIdentifier=${rid}"
  ];

  passthru = {
    frontend = stdenvNoCC.mkDerivation {
      inherit (finalAttrs) src version;
      pname = "${finalAttrs.pname}-frontend";

      __structuredAttrs = true;
      strictDeps = true;

      nativeBuildInputs = [
        nodejs-slim
        yarnConfigHook
        yarnBuildHook
      ];

      yarnOfflineCache = fetchYarnDeps {
        yarnLock = "${finalAttrs.src}/yarn.lock";
        hash = "sha256-lmtvDXf745fQN67MtZ5muIFyT3e41XYQELHHStgLauQ=";
      };

      yarnBuildFlags = [ "--env=production" ];

      installPhase = ''
        runHook preInstall
        mv _output/UI "$out"
        runHook postInstall
      '';
    };

    package_info = writeText "${finalAttrs.pname}-package_info" (
      lib.generators.toKeyValue { } {
        PackageAuthor = "[NixOS](https://nixos.org)";
        PackageVersion = finalAttrs.version;
        UpdateMethod = "External";
        UpdateMethodMessage = "Bookshelf is managed by Nix. Update it through your system configuration.";
      }
    );

    updateScript = nix-update-script {
      extraArgs = [
        "--flake"
        "--version=branch=develop"
        "--subpackage"
        "frontend"
      ];
    };
  };

  meta = {
    description = "Ebook and audiobook collection manager, maintained fork of Readarr";
    homepage = "https://github.com/pennydreadful/bookshelf";
    license = lib.licenses.gpl3Only;
    mainProgram = "Readarr";
    platforms = [ "x86_64-linux" ];
  };
})
