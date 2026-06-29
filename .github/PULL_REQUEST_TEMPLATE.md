## Description

Brief summary of changes. What problem does this solve?

**Related Issue:** Closes #[ISSUE_NUMBER]

---

## Type of Change

- [ ] 🐛 Bug fix
- [ ] ✨ New feature
- [ ] 🔧 Infrastructure/DevOps
- [ ] 📚 Documentation
- [ ] ♻️ Refactoring
- [ ] ⚡ Performance improvement
- [ ] 🔒 Security fix

---

## Changes Made

- [ ] Change 1
- [ ] Change 2
- [ ] Change 3

---

## Testing

### Manual Testing
- [ ] Tested on staging environment
- [ ] Verified locally with: `[command]`
- [ ] No regressions observed

### Automated Tests
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] All CI checks passing (linting, security, builds)

---

## Impact Assessment

### Services Affected
- [ ] Order Service
- [ ] Market Data Service
- [ ] Risk Engine
- [ ] API Gateway
- [ ] Database
- [ ] Kafka
- [ ] Other: [specify]

### Breaking Changes?
- [ ] No breaking changes
- [ ] Yes, breaking changes (explain below)

### Performance Impact
- [ ] No performance impact
- [ ] Performance improvement (explain below)
- [ ] Potential performance regression (explain & mitigate below)

---

## Deployment Notes

### Pre-deployment Checklist
- [ ] Database migrations run (if applicable)
- [ ] Secrets/credentials configured
- [ ] Feature flags set up (if needed)
- [ ] Canary deployment planned

### Deployment Strategy
- [ ] Rolling update (standard)
- [ ] Blue-green deployment
- [ ] Canary rollout (5% → 25% → 100%)

### Rollback Plan
If this deployment causes issues, rollback via:
```bash
helm rollback trading-platform [PREVIOUS_REVISION]
```

---

## Checklist

### Code Quality
- [ ] Code follows project style guidelines
- [ ] Comments added for complex logic
- [ ] No debug statements left in code
- [ ] Logging is appropriate

### Documentation
- [ ] README updated (if needed)
- [ ] Runbooks updated (if operational impact)
- [ ] Changelog entry added

### Security
- [ ] No hardcoded credentials
- [ ] No new security vulnerabilities
- [ ] Dependency versions are pinned

---

**Reviewers:** @order-service-team @devops-team
