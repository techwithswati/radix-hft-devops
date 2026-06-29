# Contributing to Radix HFT

Thank you for your interest in contributing to the Radix HFT DevOps platform!

---

## Getting Started

### 1. Fork & Clone
```bash
git clone https://github.com/YOUR_USERNAME/radix-hft-devops.git
cd radix-hft-devops
git remote add upstream https://github.com/radix-hft/radix-hft-devops.git
```

### 2. Create a Branch
```bash
git checkout -b feature/your-feature-name
# Branch naming: feature/, fix/, docs/, infra/, test/
```

### 3. Make Changes & Test
```bash
# Install pre-commit hooks
pre-commit install

# Run hooks before committing
pre-commit run --all-files

# Test locally
bash scripts/smoke-tests.sh
```

### 4. Commit (Conventional Commits)
```bash
git commit -m "type(scope): description"
# Examples: feat(order-service): add validation
#           fix(risk-engine): correct calculation
#           docs(runbooks): add troubleshooting
```

### 5. Create Pull Request
- Push to fork: `git push origin feature/your-feature-name`
- Open PR on GitHub with filled template
- Address review feedback
- Merge once approved (Squash and Merge)

---

## Testing

**Required before PR:**
```bash
yamllint kubernetes/**/*.yaml
terraform validate terraform/
shellcheck scripts/*.sh
helm lint helm/trading-platform/
bash scripts/smoke-tests.sh
```

---

## Code Style

- **YAML:** 2-space indentation
- **Bash:** Use shellcheck
- **Terraform:** Run `terraform fmt`
- **Docker:** Follow best practices
- **Helm:** Consistent templates

---

## Documentation

Update when:
- Adding features → Update README, docs/
- Changing deployment → Update Helm docs
- Operational changes → Add/update runbook

Changelog is auto-generated from commit messages.

---

## Pull Request Checklist

- [ ] Code follows style guidelines
- [ ] All tests pass
- [ ] Pre-commit hooks pass
- [ ] Documentation updated
- [ ] No breaking changes (or documented)
- [ ] Commit messages are conventional

---

## Code Review

**Authors:** Keep PRs focused, respond to feedback, be open to suggestions

**Reviewers:** Be constructive, explain reasoning, test locally if possible

---

## Questions?

- Check [docs/](./docs/)
- Ask in #radix-devops Slack
- Open an Issue

---

**Thank you for contributing! 🚀**
