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
  version = "0-unstable-2026-11-09";

  src = fetchgit {
    url = "https://tangled.org/aly.codes/tg";
    rev = "b30015edbd8394ec38b5f6338c5ad7a6cbbfe6d5";
    hash = "sha256-LGpaW2I0zMdM5GryaFl+6nC7KJ3P+nWDQa26YTM+24A=";
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
