# Declarative Disk Partitioning for PowerSpec G913
# Uses disko (github:nix-community/disko) for reproducible disk setup
#
# Samsung SSD 990 EVO Plus 2TB
# Layout:
#   - 1GB EFI System Partition (/boot)
#   - Remaining: Root partition (ext4)
#   - Swap: zram (defined in hardware-configuration.nix)

{ lib, ... }:

{
  disko.devices = {
    disk = {
      nvme = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";  # EFI System Partition
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "fmask=0077" "dmask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [ "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
