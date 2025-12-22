# Homelab V2 - IaC Orchestration
# Usage: make <target> ENV=<homepractice|homeprod>

ENV ?= homepractice
ANSIBLE_DIR = $(ENV)/ansible
TF_INFRA_DIR = $(ENV)/infrastructure
TF_K8S_DIR = $(ENV)/kubernetes

.PHONY: help init plan apply destroy configure-network bootstrap-k3s deploy-k8s full-deploy clean

help:
	@echo "Homelab V2 - Infrastructure as Code"
	@echo ""
	@echo "Usage: make <target> ENV=<homepractice|homeprod>"
	@echo ""
	@echo "Targets:"
	@echo "  init              - Initialize Terraform"
	@echo "  plan              - Plan infrastructure changes"
	@echo "  apply             - Apply infrastructure (create VMs)"
	@echo "  destroy           - Destroy infrastructure"
	@echo "  configure-network - Configure OPNsense networking (Ansible)"
	@echo "  bootstrap-k3s     - Bootstrap K3s cluster (Ansible)"
	@echo "  deploy-k8s        - Deploy Kubernetes layer (Terraform)"
	@echo "  setup-vpn         - Configure WireGuard VPN (Ansible)"
	@echo "  full-deploy       - Full deployment pipeline"
	@echo "  clean             - Clean temporary files"

# Terraform Infrastructure
init:
	cd $(TF_INFRA_DIR) && terraform init

plan:
	cd $(TF_INFRA_DIR) && terraform plan

apply:
	cd $(TF_INFRA_DIR) && terraform apply -auto-approve

destroy:
	cd $(TF_INFRA_DIR) && terraform destroy -auto-approve

# Ansible Configuration
configure-network:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/opnsense-configure.yml -e "opnsense_password=$(OPNSENSE_PASSWORD)"

bootstrap-k3s:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/k3s-bootstrap.yml

setup-vpn:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/wireguard-setup.yml -e "opnsense_password=$(OPNSENSE_PASSWORD)"

# Kubernetes Layer (runs Terraform on K3s node via Ansible)
cleanup-k8s:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/k8s-cleanup.yml

deploy-k8s:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/k8s-deploy.yml

# Full Pipeline
full-deploy: apply
	@echo "Waiting 60s for VMs to boot..."
	@sleep 60
	$(MAKE) configure-network ENV=$(ENV)
	@echo "Waiting 30s for network to stabilize..."
	@sleep 30
	$(MAKE) bootstrap-k3s ENV=$(ENV)
	@echo "Waiting 30s for K3s to initialize..."
	@sleep 30
	$(MAKE) deploy-k8s ENV=$(ENV)
	@echo ""
	@echo "=== Deployment Complete ==="
	@echo "Environment: $(ENV)"
	@echo "Kubeconfig: ./kubeconfig-$(ENV).yaml"

clean:
	find . -name "*.tfstate.backup" -delete
	find . -name ".terraform.lock.hcl" -delete
	rm -rf */.terraform
