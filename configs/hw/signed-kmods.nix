# Out-of-tree kernel modules installed through the kernel's modules_install,
# imported (not as a module) by the hardware configs that load them.
#
# Since NixOS/nixpkgs#571181 the kernel signs modules deterministically and
# the module aggregator (pkgs/os-specific/linux/kmod/aggregator.nix) expects
# a <module>.ko.cer next to every out-of-tree module. modules_install writes
# it; these packages' own installPhase copies the bare .ko, so the system
# build fails with "cat: ...ko.cer: No such file or directory".
#
# Drop each entry once nixpkgs installs it that way:
# - acpi_call: NixOS/nixpkgs#575394
# - framework-laptop-kmod: NixOS/nixpkgs#575818 (merged)
# - tp_smapi: no upstream fix yet
{ lib, kernelPackages }:
let
  inherit (kernelPackages) kernel kernelModuleMakeFlags;
  modulesInstallFlags = dir: [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=${dir}"
    "DEPMOD=true"
  ];
in
{
  # As in NixOS/nixpkgs#575394: its Makefile's install target runs
  # modules_install.
  acpi_call = kernelPackages.acpi_call.overrideAttrs (old: {
    makeFlags = old.makeFlags ++ modulesInstallFlags "misc";
    installPhase = null;
    postInstall = ''
      install -D -m755 examples/turn_off_gpu.sh $out/bin/test_discrete_video_off.sh
    '';
  });

  # As in NixOS/nixpkgs#575818.
  framework-laptop-kmod = kernelPackages.framework-laptop-kmod.overrideAttrs (old: {
    makeFlags = old.makeFlags ++ modulesInstallFlags "extra";
    installPhase = null;
    installTargets = [ "modules_install" ];
  });

  # Same place as before. hdaps.ko keeps its old file name hdapsd.ko:
  # modprobe goes by file name, so it doesn't shadow the in-tree hdaps
  # driver.
  tp_smapi = kernelPackages.tp_smapi.overrideAttrs {
    installPhase = ''
      runHook preInstall

      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M="$PWD" \
        ${lib.escapeShellArgs (kernelModuleMakeFlags ++ modulesInstallFlags "kernel/drivers/firmware")} \
        modules_install
      cd $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/firmware
      for f in hdaps.ko*; do
        mv "$f" "hdapsd''${f#hdaps}"
      done

      runHook postInstall
    '';
  };
}
