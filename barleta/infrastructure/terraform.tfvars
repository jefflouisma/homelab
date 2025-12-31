# Barleta Infrastructure - Terraform Variables

# Harvester kubeconfig
harvester_kubeconfig = "~/.kube/harvester.yaml"

# Network configuration
cluster_network_name = "mgmt"
vlan_id              = 0

# IP Configuration
gateway     = "192.168.1.254"
dns_servers = ["192.168.1.254", "8.8.8.8"]

# FreeIPA VM (only VM needed - requires systemd)
freeipa_ip = "192.168.1.212/24"

# All other workloads run natively on Harvester's RKE2 cluster
