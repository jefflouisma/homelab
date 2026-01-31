# PowerSpec G913 - Main Homelab Host Configuration
# MSI MAG X870E Tomahawk WiFi | Ryzen 9 9900X3D | RTX 5080 | 64GB DDR5

{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    # Hardware-specific modules
    ../../modules/hardware/nvidia-blackwell.nix
    ../../modules/hardware/realtek-5gbe.nix
    
    # Service modules
    ../../modules/services/kubernetes.nix
    
    # Common profiles
    ../../modules/profiles/server.nix
  ];

  # === System Identity ===
  networking.hostName = "g913";
  system.stateVersion = "24.11";  # Don't change after install

  # === Boot Configuration ===
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = [ "uinput" ];  # Virtual gamepad for Fenrir streaming
  };

  # === Timezone & Locale ===
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  # === User Configuration ===
  users.users.jeff = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" "video" "render" "input" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDgvSzqGpOgL+duV9ZQ91HMYz42AngZnZPaP9fH56+1M1qFQ/ab+1QRdnKdtzRKNzcudVxQcP9OWrcwMhopUZuGT1/uixh02a/j7fk+oSiFb7BZh7Ktl7j4G4P6oDCZ0tH3IW5uQlSTOT6aYuRWa6GWUOMl3tnuP/MNZ9E3XGFWUmgsMUypVXeNf/vdXPHBon9CELUbj6Mn/IzAjrC6aWAm2ZQKlL57BsSBQxa8TtA0LryTZPacjbgKMDjb+bjgx7ab7FrsiSTgEa40DBYR9OiWBxzcD1en0GspTWcM7th1taLbAP4T9q9r+UVcNP8d8+HsIXihF0Lxpkx6+l/nsLH0Vfi1zejicysii8oua5RjN/uGzxoHZ4tKWELW0/aUdPOINVnOKwmMxMHPxkKii8vkphRqEMeE2GVDF0OZxtj+nCFFgXFACE71SrlhJSyo3rwc0NZoOtm70UBquVjQn0DF2p/M/KCjBbXNRxgbo+44UWkdL0OTTLhbhoylOJmBQ5r9559alZ3xBKdE5hnpqrSWIvqs86vfMTIiSlnxmHA6bOgif8zBuyQVGRMBP1o/W+bmTz3fanmwt64oeafCet+1/ieDDzi9x2FITBVI6/wZChtrBwvXZZTCCbExIv23i6tx1LynGZLQfvNot3JX1qn9pCbPwZTpC2t8TuTAEHouBw== jefflouisma@me.com"
    ];
  };

  # === Networking ===
  # Primary: Realtek RTL8126 5GbE (PCI 07:00.0 -> enp7s0)
  # Fallback: USB network adapter (enp17s0u1u4) - temporary for initial setup
  networking = {
    useDHCP = false;
    defaultGateway = "192.168.1.254";
    nameservers = [ "192.168.1.254" "1.1.1.1" "8.8.8.8" ];
    
    interfaces = {
      # Realtek 5GbE - Static IP (primary)
      enp7s0 = {
        useDHCP = false;
        ipv4.addresses = [{ address = "192.168.1.10"; prefixLength = 24; }];
      };
      
      # USB Network Adapter - DHCP (fallback for initial setup)
      enp17s0u1u4 = {
        useDHCP = true;
      };
    };
    
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22     # SSH
        6443   # Kubernetes API
        80     # HTTP
        443    # HTTPS
      ];
    };
  };

  # === Base Packages ===
  environment.systemPackages = with pkgs; [
    # System utilities
    vim
    git
    htop
    tmux
    curl
    wget
    
    # Kubernetes tooling
    kubectl
    kubernetes-helm
    k9s
    
    # Hardware diagnostics
    pciutils
    usbutils
    ethtool
    nvtopPackages.nvidia
    
    # Networking
    iperf3
  ];

  # === SSH Server ===
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };
}
