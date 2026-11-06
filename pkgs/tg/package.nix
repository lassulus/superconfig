{
  lib,
  stdenv,
  buildGoModule,
  fetchgit,
  installShellFiles,
}:

# Terminal client for Tangled (like gh for GitHub): Hermes and agentd open
# and update their superconfig PRs on tangled.org with it. Built from the
# tangled.org source; the GitHub mirror's flake lags behind.
buildGoModule {
  pname = "tg";
  version = "0-unstable-2026-11-06";

  src = fetchgit {
    url = "https://tangled.org/aly.codes/tg";
    rev = "b62e0dceadb6efaf7f9e6f6193ac05ddeeeb8b86";
    hash = "sha256-N2tD4Mh+fl3+EE2rcxYR6MEV4EYZat3G9xYT4Cb7nO8=";
  };

  proxyVendor = true;
  vendorHash = "sha256-CdtyEv4P2ZdWlVSh/RJyfNEXdrTDjhJivITya1w081A=";
  subPackages = [ "cmd/tg" ];
  ldflags = [
    "-s"
    "-w"
  ];
  # the tests need git and a network
  doCheck = false;

  nativeBuildInputs = [ installShellFiles ];
  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd tg \
      --bash <($out/bin/tg completion bash) \
      --fish <($out/bin/tg completion fish) \
      --zsh <($out/bin/tg completion zsh)
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Terminal client for Tangled";
    homepage = "https://tangled.org/aly.codes/tg";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.unix;
    mainProgram = "tg";
  };
}
