# Realtek RTL8126 5GbE Network Module
# MSI MAG X870E Tomahawk WiFi onboard NIC

{ config, lib, pkgs, ... }:

{
  # === Kernel Driver ===
  # RTL8126 uses r8169 driver (in-kernel since Linux 5.18+)
  # Falls back to r8125 DKMS if issues arise
  boot.kernelModules = [ "r8169" ];

  # === Firmware ===
  hardware.enableRedistributableFirmware = true;

  # === Stability Fix: Disable NIC Offloads ===
  # RTL8125/8126 has known issues with TSO/GSO causing hangs
  # Interface at PCI 07:00.0 -> enp7s0
  systemd.services.realtek-5gbe-fix = {
    description = "Disable TSO/GSO/GRO for Realtek 5GbE stability";
    after = [ "network-pre.target" ];
    before = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for interface to be available
      sleep 2
      
      # Disable offloads on the Realtek 5GbE interface
      if [ -e /sys/class/net/enp7s0 ]; then
        echo "Disabling offloads on enp7s0 (Realtek RTL8126 5GbE)"
        ${pkgs.ethtool}/bin/ethtool -K enp7s0 tso off gso off gro off lro off || true
      fi
    '';
  };

  # === Diagnostic Tools ===
  environment.systemPackages = with pkgs; [
    ethtool
    iperf3
  ];
}
