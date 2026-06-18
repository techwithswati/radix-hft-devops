# Contributing to Radix HFT DevOps Platform

## Branch Strategy (Trunk-Based Development)

```
main (protected)
 └── feature/TICKET-description   (short-lived, < 2 days)
 └── fix/TICKET-description
 └── release/v1.2.0               (release branches only)
```

**Rules:**
- All changes via PR - no direct pushes to `main`.
- PRs require 1 approval + passing CI.
- Squash merge only.
- Delete branches after merge.

## Commit Convention (Conventional Commits)

```
<type>(<scope>): <subject>

[optional body]

[optional footer: TICKET-123]
```

**Types:** `feat` `fix` `docs` `style` `refactor` `perf` `test` `chore` `ci` `infra`

**Example:**
```
feat(order-service): add TWAP execution algorithm.
fix(terraform/eks): increase node group max to 16 for prod.
ci(github-actions): add cosign image signing to build stage.
infra(terraform): upgrade Aurora to PostgreSQL 16.2.
perf(risk-engine): reduce VaR calculation from 8ms to 3ms.
```

## Local Development

```bash
brew install terraform kubectl helm argocd k6 hadolint yamllint
brew install --cask docker
pip install pre-commit
pre-commit install
```

### Running tests locally

```bash
# Terraform validation
cd terraform/modules/eks && terraform init -backend=false && terraform validate

# Helm lint
helm lint ./helm/trading-platform --strict

# OPA policies
./opa eval --data policies/ --input kubernetes/ "data.radix.deny"

# k6 load test (smoke)
k6 run --vus 10 --duration 30s k6-tests/trading-load-test.js
```

## Pull Request Checklist

- [ ] Conventional commit message.
- [ ] Tests pass locally.
- [ ] `terraform fmt` applied.
- [ ] Helm chart updated if K8s manifests changed.
- [ ] `CHANGELOG.md` updated for user-facing changes.
- [ ] Runbook updated if operational behavior changed.
- [ ] Security impact assessed.
