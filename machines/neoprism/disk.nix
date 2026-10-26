{ lib, ... }:
{
  disko.imageBuilder.extraRootModules = [
    "zfs"
  ];
  disko.tests.extraConfig = {
    services.mingetty.autologinUser = "root";
  };
  disko.devices = {
    disk =
      (lib.genAttrs
        [
          "/dev/nvme0n1"
          "/dev/nvme1n1"
        ]
        (disk: {
          type = "disk";
          device = disk;
          imageSize = "3G";
          content = {
            type = "gpt";
            partitions = {
              boot = {
                size = "1M";
                type = "EF02";
              };
              ESP = {
                size = "1G";
                content = {
                  type = "mdraid";
                  name = "boot";
                };
              };
              zfs = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "zroot";
                };
              };
            };
          };
        })
      )
      // {
        hdd1 = {
          type = "disk";
          device = "/dev/sda";
          content = {
            type = "zfs";
            pool = "tank";
          };
        };
      };
    mdadm = {
      boot = {
        type = "mdadm";
        level = 1;
        metadata = "1.0";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        mode = "mirror";
        mountpoint = "/";
        rootFsOptions = {
          acltype = "posixacl";
          xattr = "sa";
        };
        datasets = {
          reserved = {
            type = "zfs_fs";
            options.refreservation = "1G";
          };
          pairprogramming = {
            type = "zfs_fs";
            mountpoint = "/home/pairprogramming";
            options = {
              canmount = "noauto";
            };

          };
        };
      };
      tank = {
        type = "zpool";
        datasets = {
          reserved = {
            type = "zfs_fs";
            options.refreservation = "1G";
          };
          containers = {
            type = "zfs_fs";
            mountpoint = "/var/lib/containers";
            options = {
              canmount = "noauto";
            };
          };
          home = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              canmount = "noauto";
            };
          };
          srv = {
            type = "zfs_fs";
            mountpoint = "/srv";
            options = {
              canmount = "noauto";
            };
          };
          libvirt = {
            type = "zfs_fs";
            mountpoint = "/var/lib/libvirt";
            options = {
              canmount = "noauto";
            };
          };
          # Radicle seed storage on the tank pool, hard-capped at 80G (allow-all
          # seeding has no built-in byte quota; the ZFS quota bounds it). Create
          # on an existing host with:
          #   zfs create -o mountpoint=/var/lib/radicle -o canmount=noauto -o quota=80G tank/radicle
          radicle = {
            type = "zfs_fs";
            mountpoint = "/var/lib/radicle";
            options = {
              canmount = "noauto";
              quota = "80G";
            };
          };
          # encrypted = {
          #   type = "zfs_fs";
          #   options = {
          #     canmount = "noauto";
          #     mountpoint = "none";
          #     encryption = "aes-256-gcm";
          #     keyformat = "passphrase";
          #     keylocation = "prompt";
          #   };
          # };
          # "encrypted/download" = {
          #   type = "zfs_fs";
          #   mountpoint = "/var/download";
          #   options = {
          #     canmount = "noauto";
          #   };
          # };
        };
      };
    };
  };
}
