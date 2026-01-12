# Homelab V2 - IaC Orchestration
# Usage: make <target> ENV=<barleta|homepractice|homeprod>

ENV = barleta
ANSIBLE_DIR = $(ENV)/ansible
TF_INFRA_DIR = $(ENV)/infrastructure
TF_K8S_DIR = $(ENV)/kubernetes

.PHONY: help init plan apply destroy clean

help:
	@echo "Homelab V1 - Infrastructure as Code"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Environments: barleta (Harvester-based)"
	@echo ""
	@echo "Targets:"
	@echo "  init              - Initialize Terraform"
	@echo "  plan              - Plan infrastructure changes"
	@echo "  apply             - Apply infrastructure (create VMs)"
	@echo "  destroy           - Destroy infrastructure"
	@echo "  clean             - Clean temporary files"
	@echo ""
	@echo "Utilities:"
	@echo "  fenrir-ip         - Get Moonlight proxy IP for Apple TV"
	@echo "  argocd-sync       - Trigger ArgoCD sync"
	@echo ""
	@echo "Note: Fenrir is deployed via GitOps (ArgoCD). Commit and push to deploy."

# Terraform Infrastructure
init:
	cd $(TF_INFRA_DIR) && terraform init

plan:
	cd $(TF_INFRA_DIR) && terraform plan

apply:
	cd $(TF_INFRA_DIR) && terraform apply -auto-approve

destroy:
	cd $(TF_INFRA_DIR) && terraform destroy -auto-approve

clean:
	find . -name "*.tfstate.backup" -delete
	find . -name ".terraform.lock.hcl" -delete
	rm -rf */.terraform

# Utility Commands
.PHONY: fenrir-ip argocd-sync

fenrir-ip:
	@echo "Moonlight Proxy IP (use this in Apple TV):"
	@kubectl get svc moonlight-proxy -n house -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "LoadBalancer IP not yet assigned"
	@echo ""

argocd-sync:
	@echo "Triggering ArgoCD sync for all apps..."
	kubectl patch application barleta-root -n argocd --type merge -p '{"operation": {"initiatedBy": {"username": "admin"}, "sync": {}}}'
