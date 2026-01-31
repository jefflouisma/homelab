# Vanilla Kubernetes Module (services.kubernetes)
# Single-node cluster for Barleta homelab

{ config, lib, pkgs, ... }:

let
  masterIP = "192.168.1.10";  # Adjust to your static IP
  clusterCIDR = "10.244.0.0/16";
  serviceCIDR = "10.96.0.0/12";
in {
  # === Container Runtime ===
  virtualisation.containerd.enable = true;

  # === Kubernetes Cluster ===
  services.kubernetes = {
    # Single-node: both master and node roles
    roles = [ "master" "node" ];
    
    # Master address (for kubeconfig)
    masterAddress = masterIP;
    
    # API Server configuration
    apiserver = {
      securePort = 6443;
      advertiseAddress = masterIP;
      
      # Allow privileged containers (needed for Fenrir/NVIDIA)
      extraOpts = "--allow-privileged=true";
      
      # Service account signing
      serviceAccountKeyFile = "/var/lib/kubernetes/secrets/service-account.key";
      serviceAccountSigningKeyFile = "/var/lib/kubernetes/secrets/service-account.key";
    };
    
    # Controller Manager
    controllerManager = {
      extraOpts = "--cluster-cidr=${clusterCIDR}";
    };
    
    # Kubelet configuration
    kubelet = {
      kubeconfig.server = "https://${masterIP}:6443";
      
      # Container runtime
      containerRuntime = "remote";
      containerRuntimeEndpoint = "unix:///run/containerd/containerd.sock";
      
      # Allow privileged pods (NVIDIA device plugins)
      extraOpts = "--allowed-unsafe-sysctls=net.*";
    };
    
    # Scheduler
    scheduler.enable = true;
    
    # Flannel CNI (simple, works out of the box)
    # Replace with Cilium if needed via addon
    flannel.enable = true;
    
    # etcd (embedded single-node)
    etcd = {
      enable = true;
      servers = [ "https://${masterIP}:2379" ];
    };
  };

  # === CoreDNS ===
  services.coredns = {
    enable = true;
    # Config will be auto-generated
  };

  # === Firewall Rules ===
  networking.firewall.allowedTCPPorts = [
    6443   # Kubernetes API
    2379   # etcd client
    2380   # etcd peer
    10250  # Kubelet API
    10251  # kube-scheduler
    10252  # kube-controller-manager
  ];

  # === kubectl configuration ===
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
    stern  # Log aggregation
  ];

  # === kubeconfig for root user ===
  environment.etc."kubernetes/admin.conf".source = "/var/lib/kubernetes/cluster-admin.conf";
  
  environment.shellAliases = {
    k = "kubectl";
    kgp = "kubectl get pods -A";
    kgs = "kubectl get svc -A";
  };
}
