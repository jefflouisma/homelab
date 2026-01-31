# Hardware configuration for PowerSpec G913
# Discovered from Harvester host via SSH on 2026-01-31
#
# Motherboard: MSI MAG X870E TOMAHAWK WIFI (MS-7E59)
# CPU: AMD Ryzen 9 9900X3D 12-Core Processor
# GPU: NVIDIA RTX 5080 [10de:2c02]
# NIC: Realtek RTL8126 5GbE [10ec:8126]
# NVMe: Samsung SSD 990 EVO Plus 2TB
# RAM: 64GB DDR5

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # === CPU: AMD Ryzen 9 9900X3D ===
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  
  # === Early Boot Modules ===
  boot.initrd.availableKernelModules = [
    "nvme"          # Samsung 990 EVO Plus NVMe
    "xhci_pci"      # USB 3.x controller
    "ahci"          # AMD SATA controller
    "usbhid"        # USB HID devices
    "usb_storage"   # USB mass storage
    "sd_mod"        # SCSI disk
    "r8169"         # Realtek 5GbE (RTL8126)
  ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # === Disk Layout: Samsung 990 EVO Plus 2TB ===
  # Current Harvester layout (adjust for clean NixOS install):
  #   nvme0n1p1:  64MB  - EFI System Partition
  #   nvme0n1p2:  50MB  - /oem (Harvester specific)
  #   nvme0n1p3:   8GB  - Recovery/State
  #   nvme0n1p4:  15GB  - COS-State
  #   nvme0n1p5: 558GB  - /usr/local
  #   nvme0n1p6: 1.3TB  - /var/lib/harvester/defaultdisk (Longhorn)
  #
  # Recommended NixOS layout:
  #   nvme0n1p1:   1GB  - EFI (/boot)
  #   nvme0n1p2: 1.8TB  - Root ext4 or btrfs (/)
  #   Swap: Use zram or swapfile (64GB RAM = minimal swap needed)
  
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";  # Or "btrfs" for snapshots
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # === Swap (zram recommended for 64GB RAM) ===
  zramSwap = {
    enable = true;
    memoryPercent = 25;  # 16GB compressed swap
  };

  # === Platform ===
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
