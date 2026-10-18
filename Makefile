TASK_TMP ?= /Volumes/4TB_Drive/tmp/homelab-rosefish
export TMPDIR := /Volumes/4TB_Drive/tmp/
export GOTMPDIR := $(TASK_TMP)/go-tmp
export GOCACHE := $(TASK_TMP)/go-cache
export GOMODCACHE := $(TASK_TMP)/go-mod
export CARGO_TARGET_DIR := $(TASK_TMP)/target
export KUBECACHEDIR := $(TASK_TMP)/kube-cache
export PYTHONDONTWRITEBYTECODE := 1

.PHONY: help prepare validate test test-go test-rust test-loader build status fenrir-ip argocd-sync

help:
	@echo "validate       Check manifests and script syntax"
	@echo "test           Run Go race/vet and Rust format/clippy/tests"
	@echo "test-loader    Test ingestion against a configured PostgreSQL fixture"
	@echo "build          Build Go components and moonlight-mcp outside the checkout"
	@echo "status         Show Argo, pod, and persistent-volume health"
	@echo "fenrir-ip      Show the Moonlight address for Apple TV"
	@echo "argocd-sync    Request a root Argo sync"

prepare:
	@case "$(TASK_TMP)" in /Volumes/4TB_Drive/tmp/?*) ;; *) echo "TASK_TMP must be under /Volumes/4TB_Drive/tmp/" >&2; exit 1;; esac
	@mkdir -p "$(GOTMPDIR)" "$(GOCACHE)" "$(GOMODCACHE)" "$(KUBECACHEDIR)" "$(TASK_TMP)/bin"

validate: prepare
	python3 scripts/validate-project.py
	python3 -m unittest discover -s barleta/apps/house/fenrir/images/emudeck -v

test: test-go test-rust

test-go: prepare
	cd fenrir && go test -race ./... && go vet ./...

test-rust: prepare
	cargo fmt --manifest-path moonlight-mcp/Cargo.toml --check
	cargo clippy --locked --manifest-path moonlight-mcp/Cargo.toml --all-targets -- -D warnings
	cargo test --locked --manifest-path moonlight-mcp/Cargo.toml --all-targets

test-loader: prepare
	@test -n "$$PGHOST" -a -n "$$PGUSER" -a -n "$$PGPASSWORD" -a -n "$$PGDATABASE" || { echo "Set PGHOST, PGUSER, PGPASSWORD and PGDATABASE for an isolated PostgreSQL fixture" >&2; exit 1; }
	python3 -m unittest discover -s barleta/apps/analytics/uci-loader -v

build: prepare
	cd fenrir && for component in operator moonlight-proxy wolf-agent; do go build -o "$(TASK_TMP)/bin/fenrir-$$component" "./cmd/$$component" || exit; done
	cargo build --locked --manifest-path moonlight-mcp/Cargo.toml

status: prepare
	kubectl get applications.argoproj.io -n argocd
	kubectl get pods -A
	kubectl get pvc -A

fenrir-ip: prepare
	@kubectl get svc moonlight-proxy -n house -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'

argocd-sync: prepare
	kubectl patch application barleta-root -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"make"},"sync":{}}}'
