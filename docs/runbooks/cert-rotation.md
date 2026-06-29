# Runbook: Certificate Rotation

**Frequency:** Every 90 days | **RTO:** 30 min | **RPO:** N/A | **Downtime:** 0 min (zero-downtime)

---

## Automated Process (Preferred)

Radix HFT uses **cert-manager** to automate certificate renewal. Most renewals are automatic:

```bash
# Check cert-manager is running
kubectl get pods -n cert-manager

# Check certificate status
kubectl get certificate -A
# Look for READY: True, AGE within renewal window (30 days before expiry)
```

**If automatic renewal fails:**

```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager --tail=50

# Force renew (creates new cert, restarts pods)
kubectl delete certificate <cert-name> -n <namespace>
# cert-manager will recreate it immediately

# Monitor renewal
kubectl get certificate <cert-name> -n <namespace> -w
# Watch for READY: True
```

---

## Manual Certificate Rotation

### **Step 1: Generate New Certificate**

**Option A: Using cert-manager (Recommended)**
```bash
# Create Certificate resource
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-tls
  namespace: trading
spec:
  secretName: api-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - api.radix-hft.com
    - api.staging.radix-hft.com
    - "*.radix-hft.com"
  duration: 2160h  # 90 days
  renewBefore: 720h  # 30 days
EOF

# Wait for certificate to be ready
kubectl get certificate api-tls -n trading -w
# READY should become True
```

**Option B: Using OpenSSL (Manual)**
```bash
# Generate private key (if not exists)
openssl genrsa -out api.key 2048

# Create certificate request
openssl req -new \
  -key api.key \
  -out api.csr \
  -subj "/C=US/ST=CA/L=San Francisco/O=Radix/CN=api.radix-hft.com"

# Get certificate signed by CA (e.g., Let's Encrypt, AWS Certificate Manager)
# For AWS ACM:
aws acm request-certificate \
  --domain-name api.radix-hft.com \
  --subject-alternative-names "*.radix-hft.com" "api.staging.radix-hft.com" \
  --region us-east-1

# Validate domain ownership (DNS CNAME)
# AWS will email you the CNAME records to add
```

---

### **Step 2: Update Secret in Kubernetes**

```bash
# Option A: If using cert-manager (automatic)
# cert-manager updates the secret automatically
kubectl get secret api-tls-secret -n trading -o yaml | head -10

# Option B: If manual certificate
kubectl create secret tls api-tls-secret \
  --cert=api.crt \
  --key=api.key \
  --namespace trading \
  --dry-run=client -o yaml | kubectl apply -f -

# Verify secret is updated
kubectl get secret api-tls-secret -n trading -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
# Output: notBefore= ... notAfter= ...  (should show new expiry)
```

---

### **Step 3: Update Ingress Resource**

```bash
# Check current ingress
kubectl get ingress -n trading -o yaml | grep -A 5 "tls:"

# Update ingress (if secret reference changed)
kubectl patch ingress api-ingress -n trading \
  -p '{"spec":{"tls":[{"hosts":["api.radix-hft.com"],"secretName":"api-tls-secret"}]}}'

# Verify
kubectl get ingress api-ingress -n trading -o wide
```

---

### **Step 4: Rolling Restart (Zero-Downtime)**

```bash
# Restart API Gateway pods (ALB will maintain traffic)
kubectl rollout restart deployment/api-gateway -n trading

# Monitor pod replacement
kubectl rollout status deployment/api-gateway -n trading

# Verify pods restarted with new cert
kubectl get pods -n trading -l app=api-gateway
```

---

## Verification

### **Check Certificate Validity**

```bash
# From kubectl
kubectl get secret api-tls-secret -n trading -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -dates
# Output should show new notAfter date

# From curl
curl -I --cacert api.crt https://api.radix-hft.com/health
# Should return 200 OK (not certificate error)

# From browser
# Visit https://api.radix-hft.com/health
# Certificate should show new expiry date (90 days from today)
```

### **Check Certificate Chain**

```bash
# Verify cert is valid
openssl x509 -in api.crt -noout -text | grep -A 2 "Validity\|Subject:"

# Check for warnings
curl -I https://api.radix-hft.com/health 2>&1 | grep -i "certificate\|warning"
# Should be empty
```

### **Monitor Certificate Age**

```bash
# Prometheus query (if monitoring is configured)
# probe_ssl_earliest_cert_expiry - time() < 604800  (less than 7 days)

# Or manually check all certs
for cert in $(kubectl get secret -n trading -o jsonpath='{.items[?(@.type=="kubernetes.io/tls")].metadata.name}'); do
  echo "Cert: $cert"
  kubectl get secret $cert -n trading -o jsonpath='{.data.tls\.crt}' | base64 -d | \
    openssl x509 -noout -dates
  echo "---"
done
```

---

## Certificate Expiry Warning System

### **Automated Alerts**

```bash
# Deploy alert in Prometheus (prometheus/alerts.yaml)
- alert: CertificateExpiringSoon
  expr: probe_ssl_earliest_cert_expiry - time() < 14*24*60*60  # 14 days
  for: 1h
  annotations:
    summary: "TLS certificate expiring in {{ $value | humanizeDuration }}"
    runbook: "https://docs.radix-hft.com/runbooks/cert-rotation"
```

### **Manual Monitoring**

```bash
# Check certificate expiry every 30 days
# Add to cron (or monitoring dashboard):
0 9 1 * * /usr/local/bin/check-cert-expiry.sh

# Script content:
#!/bin/bash
for cert in $(kubectl get secret -n trading -o name | grep tls); do
  EXPIRY=$(kubectl get $cert -o jsonpath='{.data.tls\.crt}' | base64 -d | \
    openssl x509 -noout -enddate | cut -d= -f2)
  DAYS_LEFT=$(( ($(date -d "$EXPIRY" +%s) - $(date +%s)) / 86400 ))
  if [ $DAYS_LEFT -lt 30 ]; then
    echo "WARNING: $cert expires in $DAYS_LEFT days"
  fi
done
```

---

## Troubleshooting

### **Issue: cert-manager Stuck (Certificate not Ready)**

```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager -f | grep -i "error\|fail"

# Check ACME challenge status
kubectl get challenge -n trading

# If challenge failed:
# 1. Check DNS records
$ dig +short _acme-challenge.api.radix-hft.com TXT

# 2. Force renewal
kubectl delete secret api-tls-secret -n trading
# cert-manager will recreate it

# 3. Monitor status
kubectl get certificate api-tls -n trading -w
```

### **Issue: Certificate Applied But Still Showing Old Cert**

```bash
# Pod may have cached old cert
# Force restart
kubectl rollout restart deployment/api-gateway -n trading
kubectl rollout status deployment/api-gateway -n trading

# Check pod actually restarted
kubectl get pods -n trading -l app=api-gateway --sort-by=.metadata.creationTimestamp
```

### **Issue: ALB/Ingress Not Using New Certificate**

```bash
# Check ALB listener configuration
aws elbv2 describe-listeners \
  --load-balancer-arn <ALB_ARN> \
  --region us-east-1 | jq '.Listeners[] | select(.Protocol=="HTTPS")'

# Update ALB certificate (if manual)
aws elbv2 modify-listener \
  --listener-arn <LISTENER_ARN> \
  --certificates CertificateArn=<NEW_CERT_ARN> \
  --region us-east-1
```

---

## Pre-Rotation Checklist

- [ ] Cert-manager is running and healthy
- [ ] DNS records are correct (for ACME challenge)
- [ ] No pending certificate orders
- [ ] Backup of old certificate (already done by K8s secret versioning)
- [ ] Alert rules configured for expiry warning
- [ ] Post-rotation smoke tests planned

---

## Post-Rotation Checklist

- [ ] Certificate shows in kubectl
- [ ] All pods restarted successfully
- [ ] No 503/SSL errors in logs
- [ ] HTTPS endpoint works (curl -I https://api.radix-hft.com)
- [ ] Browser shows new expiry date
- [ ] Monitoring shows no certificate warnings
- [ ] Order flow smoke tests pass

---

## Scheduling Rotation

**Mark in Calendar:**
- Day 1: Certificate issued
- Day 60: Pre-expiry reminder
- Day 75: Alert threshold (14 days before expiry)
- Day 90: Scheduled rotation (or auto-renewed)

**With cert-manager:** No action needed (automatic renewal at 30 days before expiry)

**Without cert-manager:** Manual renewal every 90 days

---

## Related Commands

```bash
# List all secrets with TLS certs
kubectl get secret -A -o custom-columns=NAME:.metadata.name,TYPE:.type | grep tls

# Check single certificate
kubectl get secret api-tls-secret -n trading -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -subject -dates

# View certificate in detail
kubectl get secret api-tls-secret -n trading -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text

# Update secret from file
kubectl create secret tls api-tls-secret --cert=api.crt --key=api.key --dry-run=client -o yaml | \
  kubectl apply -f -

# Check ingress TLS config
kubectl describe ingress api-ingress -n trading | grep -A 10 "TLS:"

# Restart pods to pick up new cert
kubectl rollout restart deployment/api-gateway -n trading
```

---

**Last Updated:** 2026-06-19  
**Rotation Frequency:** Every 90 days (automatic with cert-manager)  
**Maintained By:** Infrastructure Team
