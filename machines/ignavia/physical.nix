{
  self,
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disk.nix
    self.inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
  ];

  services.fprintd.enable = true;
  services.fwupd.enable = true;
  services.fwupd.extraRemotes = [ "lvfs-testing" ];
  # Might be necessary once to make the update succeed
  # services.fwupd.uefiCapsuleSettings.DisableCapsuleUpdateOnDisk = true;
  # we need fwupd 1.9.7 to downgrade the fingerprint sensor firmware
  # we only need to downgrade the firmware once, so we can remove this once we have done that
  # services.fwupd.package = (import (builtins.fetchTarball {
  #   url = "https://github.com/NixOS/nixpkgs/archive/bb2009ca185d97813e75736c2b8d1d8bb81bde05.tar.gz";
  #   sha256 = "sha256:003qcrsq5g5lggfrpq31gcvj82lb065xvr7bpfa8ddsw8x4dnysk";
  # }) {
  #   inherit (pkgs) system;
  # }).fwupd;

  networking.hostId = "deadbeef";

  boot.loader.grub = {
    enable = true;
    device = "/dev/nvme0n1";
    efiSupport = true;
    efiInstallAsRemovable = true;
    # The ESP is only 1 GiB (see disk.nix); without a cap GRUB keeps every
    # generation's kernel+initrd (~50-90 MiB each) until /boot fills and
    # deploys fail. ~10 generations fits with headroom.
    configurationLimit = 10;
  };

  hardware.graphics.enable = true;
  hardware.acpilight.enable = true;
  boot.kernelModules = [
    # DDC/CI: expose /dev/i2c-* so ddcutil can drive external monitor brightness
    "i2c-dev"
    # what hardware.framework.enableKmod loads, see below
    "cros_ec"
    "cros_ec_lpcs"
  ];

  # nixos-hardware's framework-laptop-kmod lacks the module certificate the
  # module aggregator needs, see configs/hw/signed-kmods.nix.
  hardware.framework.enableKmod = false;
  boot.extraModulePackages = [
    (import ../../configs/hw/signed-kmods.nix {
      inherit lib;
      inherit (config.boot) kernelPackages;
    }).framework-laptop-kmod
  ];

  # Use latest kernel for better Strix Point GPU support. The MT7925 BT init
  # regression fix (e3ac0d9f1a20) landed upstream in 7.0.10.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # MT7925 WiFi roam freezes (list_add corruption -> kernel BUG at
  # lib/list_debug.c:32, 10 hard freezes 2026-07-03..07-07): generic
  # mt76_sta_add() re-ran mt76_wcid_init() on a wcid the mt7925 sta_add
  # had already published, so the rx/txs softirq could link it into
  # sta_poll_list right before the second INIT_LIST_HEAD self-looped it.
  # Fixed upstream in 7.1.3 by 20b126920a25 ("wifi: mt76: add wcid
  # publish check in mt76_sta_add") - keep kernel >= 7.1.3.

  # amdgpu.mes=0 (old RDNA3+ MES ring-hang workaround) was removed here:
  # since kernel ~7.x the parameter no longer exists ("amdgpu: unknown
  # parameter 'mes' ignored") and the GPU has been stable without it.

  boot.initrd.availableKernelModules = [
    "nvme"
    "thunderbolt"
    "xhci_pci"
    "usbhid"
  ];

  # IO latency tuning. The whole system (/, /home, /nix) lives on one
  # btrfs-on-LUKS-on-NVMe device, so bulk writes (downloads, builds) can starve
  # latency-sensitive reads — e.g. launching a terminal stalls for seconds.
  # Three independent causes, three fixes:

  # 1. NVMe defaults to scheduler "none" (FIFO, no read/write fairness), so a
  #    read queues behind up to nr_requests (1023) writes. mq-deadline gives
  #    reads deadline priority over bulk writes.
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme0n1", ATTR{queue/scheduler}="mq-deadline"
    # ddcutil needs user access to the DP AUX i2c buses for DDC/CI
    ACTION=="add|change", SUBSYSTEM=="i2c-dev", KERNEL=="i2c-*", MODE="0660", GROUP="i2c"
  '';

  # 2. Default dirty-page limits are ratio-based: ~6.2 GB background / ~12.4 GB
  #    hard on 62 GB RAM. Writes pool in RAM then flush in multi-GB bursts that
  #    flood the queue and freeze everything (PSI full IO). Small fixed byte
  #    limits make writeback continuous instead of bursty.
  boot.kernel.sysctl."vm.dirty_bytes" = 268435456; # 256 MiB
  boot.kernel.sysctl."vm.dirty_background_bytes" = 67108864; # 64 MiB

  # 3. dm-crypt funnels all IO through the kcryptd workqueue, a serialization
  #    point under load. AES-NI is present so inline crypto is cheap — bypass
  #    the queues to cut crypt-layer latency. Device name from disk.nix.
  boot.initrd.luks.devices.aergia1.bypassWorkqueues = true;

  # MT7925 wifi stability. The dominant cause of the "drops every few
  # minutes" was a dual-manager conflict (systemd-networkd AND NM both
  # running DHCP on the wifi) - fixed in configs/network-manager.nix by
  # handing wifi solely to NM. The remainder below addresses a *separate*,
  # secondary mt7925 firmware bug: the card intermittently tears the link
  # down during scans (wpa_supplicant "reason=3 locally_generated=1" next
  # to "Reject scan trigger since one is already pending"; iwd shows it
  # mid-roam) - a driver bug with no fix below the kernel. We need
  # aggressive roaming (event with ~100 APs) so we cannot disable the scans
  # that trigger it; we only cut how often it fires. When it does fire, NM
  # re-associates on its own in a few seconds (a gateway-ping watchdog was
  # tried and removed: bornhack's gateway drops ICMP, so it false-fired and
  # bounced a working link every 90 s).
  #
  # 1. Stay on the default wpa_supplicant backend. iwd roams well but
  #    busy-loops at 100% CPU in this dense ~100-AP environment (it chokes
  #    on the flood of HE-capability beacons) and wedged the link hard
  #    enough to need a driver reload - not usable here.
  #
  # 2. Kill NIC power management. powersave and PCIe ASPM both let the
  #    firmware abort/miss a scan mid-connection on this chip; disabling
  #    both is the most-reported mt7925 stability mitigation.
  networking.networkmanager.wifi.powersave = false;
  boot.extraModprobeConfig = "options mt7925e disable_aspm=1";
}
