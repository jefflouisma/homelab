# NVIDIA RTX 5080 (Blackwell Architecture) Driver Module
# Requires nixos-unstable channel for 570+ driver series
#
# Display: AMD Radeon iGPU [1002:13c0] on motherboard
# Compute: NVIDIA RTX 5080 [10de:2c02] for containers/streaming

{ config, lib, pkgs, ... }:

{
  # === Firmware ===
  hardware.enableAllFirmware = true;
  hardware.firmware = [ pkgs.linux-firmware ];

  # === AMD iGPU for Display Output ===
  # AMD Radeon embedded on MSI MAG X870E Tomahawk WiFi
  services.xserver.videoDrivers = [ "amdgpu" "nvidia" ];
  
  hardware.amdgpu = {
    initrd.enable = true;  # Load early for console
  };

  # === NVIDIA Driver Configuration (Compute Only) ===
  hardware.nvidia = {
    # Required for Wayland/GBM compositors (Wolf/Fenrir streaming)
    modesetting.enable = true;
    
    # Power management (disable for server workloads)
    powerManagement.enable = false;
    powerManagement.finegrained = false;
    
    # Use proprietary driver (required for Blackwell sm_120)
    open = false;
    
    # Enable nvidia-settings GUI tool
    nvidiaSettings = true;
    
    # Driver package - production for stability
    package = config.boot.kernelPackages.nvidiaPackages.production;
    
    # Primary GPU is AMD, NVIDIA is secondary (for compute)
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
      # AMD iGPU is primary (display)
      amdgpuBusId = "PCI:121:0:0";  # 79:00.0 in hex = 121
      # NVIDIA is secondary (compute/containers)
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # === Graphics Stack ===
  hardware.graphics = {
    enable = true;
    enable32Bit = true;  # For 32-bit apps/games
  };

  # === Container GPU Passthrough ===
  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.docker = {
    enable = true;
    enableNvidia = true;
  };

  # === Verification Package ===
  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia
    cudaPackages.cudatoolkit
  ];
}
