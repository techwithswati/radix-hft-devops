.PHONY: help build test lint deploy clean docker-build docker-push helm-lint terraform-validate all

help:
	@echo "Radix HFT DevOps — Available Commands"
	@echo ""
	@echo "Development:"
	@echo "  make lint                 - Run all linting checks"
	@echo "  make test                 - Run all tests"
	@echo "  make validate             - Validate all configurations"
	@echo ""
	@echo "Docker:"
	@echo "  make docker-build         - Build all Docker images"
	@echo "  make docker-push          - Push images to registry"
	@echo ""
	@echo "Kubernetes:"
	@echo "  make helm-lint            - Lint Helm chart"
	@echo "  make helm-template        - Template Helm chart"
	@echo "  make kubectl-apply-dry    - Dry-run kubectl apply"
	@echo ""
	@echo "Terraform:"
	@echo "  make terraform-validate   - Validate Terraform"
	@echo "  make terraform-plan       - Show Terraform plan"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy-staging       - Deploy to staging"
	@echo "  make deploy-prod          - Deploy to production (canary)"
	@echo "  make smoke-test           - Run smoke tests"
	@echo ""
	@echo "Utilities:"
	@echo "  make clean                - Clean build artifacts"
	@echo "  make all                  - Run all checks"

# ────────────────────────────────────────────────────
# Linting
# ────────────────────────────────────────────────────
lint: lint-yaml lint-terraform lint-docker lint-shell lint-helm
	@echo "✅ All linting passed"

lint-yaml:
	@echo "🔍 Linting YAML..."
	@yamllint kubernetes/ helm/ argocd/ .github/workflows/
	@echo "✓ YAML lint passed"

lint-terraform:
	@echo "🔍 Linting Terraform..."
	@terraform -chdir=terraform fmt -check -recursive
	@terraform -chdir=terraform validate
	@tflint --init --config=.tflint.hcl
	@tflint --config=.tflint.hcl terraform/
	@echo "✓ Terraform lint passed"

lint-docker:
	@echo "🔍 Linting Dockerfiles..."
	@hadolint docker/*/Dockerfile
	@echo "✓ Docker lint passed"

lint-shell:
	@echo "🔍 Linting shell scripts..."
	@shellcheck scripts/*.sh
	@echo "✓ Shell lint passed"

lint-helm:
	@echo "🔍 Linting Helm chart..."
	@helm lint helm/trading-platform/
	@echo "✓ Helm lint passed"

# ────────────────────────────────────────────────────
# Testing
# ────────────────────────────────────────────────────
test: smoke-test integration-test
	@echo "✅ All tests passed"

smoke-test:
	@echo "🧪 Running smoke tests..."
	@bash scripts/smoke-tests.sh

integration-test:
	@echo "🧪 Running integration tests..."
	@bash scripts/integration-tests.sh

load-test:
	@echo "🧪 Running load tests..."
	@k6 run k6-tests/trading-load-test.js

# ────────────────────────────────────────────────────
# Validation
# ────────────────────────────────────────────────────
validate: terraform-validate helm-lint
	@echo "✅ All configurations validated"

terraform-validate:
	@echo "📋 Validating Terraform..."
	@terraform -chdir=terraform validate
	@echo "✓ Terraform validated"

helm-template:
	@echo "📋 Templating Helm chart..."
	@helm template trading-platform helm/trading-platform/ | yamllint -
	@echo "✓ Helm chart valid"

# ────────────────────────────────────────────────────
# Docker
# ────────────────────────────────────────────────────
SERVICES := order-service market-data-service risk-engine api-gateway
REGISTRY := ghcr.io/radix-hft
TAG := $(shell git rev-parse --short HEAD)

docker-build:
	@echo "🐳 Building Docker images..."
	@for service in $(SERVICES); do \
		echo "Building $$service:$(TAG)..."; \
		docker build -t $(REGISTRY)/$$service:$(TAG) docker/$$service/; \
	done
	@echo "✓ Docker images built"

docker-push:
	@echo "📤 Pushing Docker images to registry..."
	@for service in $(SERVICES); do \
		echo "Pushing $$service:$(TAG)..."; \
		docker push $(REGISTRY)/$$service:$(TAG); \
	done
	@echo "✓ Docker images pushed"

docker-build-arm64:
	@echo "🐳 Building ARM64 Docker images..."
	@docker buildx build --platform linux/arm64 -t $(REGISTRY)/order-service:$(TAG) docker/order-service/

# ────────────────────────────────────────────────────
# Kubernetes
# ────────────────────────────────────────────────────
kubectl-apply-dry:
	@echo "🔍 Dry-run kubectl apply..."
	@kubectl apply -f kubernetes/ --dry-run=client
	@echo "✓ Dry-run successful"

kubectl-apply:
	@echo "📦 Applying Kubernetes manifests..."
	@kubectl apply -f kubernetes/
	@echo "✓ Applied"

# ────────────────────────────────────────────────────
# Helm
# ────────────────────────────────────────────────────
helm-upgrade-staging:
	@echo "📦 Deploying to staging with Helm..."
	@helm upgrade --install trading-platform helm/trading-platform/ \
		-f helm/trading-platform/values-staging.yaml \
		-n trading --create-namespace --wait

helm-upgrade-prod:
	@echo "⚠️  Deploying to PRODUCTION with Helm..."
	@echo "This will trigger canary rollout. Continue? [y/N]"
	@helm upgrade --install trading-platform helm/trading-platform/ \
		-f helm/trading-platform/values-prod.yaml \
		-n trading --wait

# ────────────────────────────────────────────────────
# Deployment
# ────────────────────────────────────────────────────
deploy-staging: lint test docker-build docker-push helm-upgrade-staging smoke-test
	@echo "✅ Staging deployment complete"

deploy-prod: lint test docker-build docker-push helm-upgrade-prod smoke-test
	@echo "✅ Production deployment complete"

# ────────────────────────────────────────────────────
# Utilities
# ────────────────────────────────────────────────────
clean:
	@echo "🧹 Cleaning up..."
	@find . -type d -name __pycache__ -exec rm -rf {} +
	@find . -type f -name "*.pyc" -delete
	@rm -rf .terraform/ terraform/.terraform/
	@rm -rf dist/ build/
	@echo "✓ Cleaned"

all: lint test validate
	@echo "✅ All checks passed"

# ────────────────────────────────────────────────────
# Pre-commit
# ────────────────────────────────────────────────────
pre-commit-install:
	@echo "🔗 Installing pre-commit hooks..."
	@pre-commit install
	@echo "✓ Hooks installed"

pre-commit-run:
	@echo "🔍 Running pre-commit..."
	@pre-commit run --all-files
	@echo "✓ Pre-commit passed"

# ────────────────────────────────────────────────────
# Local Development
# ────────────────────────────────────────────────────
dev-up:
	@echo "🚀 Starting local development environment..."
	@docker-compose up -d
	@echo "✓ Local environment running"

dev-down:
	@echo "🛑 Stopping local development environment..."
	@docker-compose down
	@echo "✓ Local environment stopped"

dev-logs:
	@docker-compose logs -f
