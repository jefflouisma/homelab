# Server Profile - Common settings for headless servers

{ config, lib, pkgs, ... }:

{
  # === Nix Settings ===
  nix = {
    settings = {
      # Enable flakes and new CLI
      experimental-features = [ "nix-command" "flakes" ];
      
      # Garbage collection
      auto-optimise-store = true;
      
      # Trusted users for remote builds
      trusted-users = [ "root" "@wheel" ];
    };
    
    # Automatic garbage collection
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # === Allow unfree packages (NVIDIA drivers, etc.) ===
  nixpkgs.config.allowUnfree = true;

  # === Documentation ===
  documentation = {
    enable = true;
    man.enable = true;
    nixos.enable = true;
  };

  # === Security ===
  security = {
    # Sudo without password for wheel group (adjust as needed)
    sudo.wheelNeedsPassword = false;
    
    # PAM settings
    pam.loginLimits = [
      { domain = "*"; type = "soft"; item = "nofile"; value = "65536"; }
      { domain = "*"; type = "hard"; item = "nofile"; value = "65536"; }
    ];
  };

  # === Systemd Journal ===
  services.journald = {
    extraConfig = ''
      SystemMaxUse=1G
      MaxRetentionSec=1week
    '';
  };

  # === Time Sync ===
  services.timesyncd.enable = true;

  # === Console ===
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # === Performance Tuning ===
  boot.kernel.sysctl = {
    # Network performance
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";
    
    # File handles
    "fs.file-max" = 2097152;
    "fs.inotify.max_user_watches" = 524288;
    
    # Kubernetes requirements
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };

  # === Load bridge module for Kubernetes ===
  boot.kernelModules = [ "br_netfilter" "overlay" ];
}
