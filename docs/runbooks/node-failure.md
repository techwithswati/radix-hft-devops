# Runbook: Node Failure Recovery

**Severity:** P1 | **Component:** EKS Infrastructure | **RTO:** 10 min | **RPO:** 0 min

---

## Symptoms

- Pod evicted: `Node.kubernetes.io/not-ready:NoExecute`
- Node shows `NotReady` status
- Pods pending with `0/N nodes available`
- CPU/Memory metrics stop for a node
- PagerDuty: `NodeMemoryPressure` or `NodeDiskPressure`

**Check Status:**
```bash
kubectl get nodes -o wide
# Look for STATUS: NotReady

kubectl get events --all-namespaces --sort-by='.lastTimestamp' | grep -i "node\|evict"

kubectl describe nodes <node-name> | grep -A 20 "Conditions:"
```

---

## Immediate Response (0-5 min)

### **1. Assess Impact**

```bash
# How many pods are affected?
kubectl get pods --all-namespaces -o wide | grep <node-name> | wc -l

# Which namespaces are affected?
kubectl get pods --all-namespaces -o wide | grep <node-name> | awk '{print $1}' | sort | uniq

# Critical services affected?
kubectl get pods --all-namespaces -o wide | grep <node-name> | grep -E "order-service|market-data|risk-engine"
```

### **2. Check Node Health**

```bash
# SSH into node (if accessible)
aws ssm start-session --target <instance-id> --region us-east-1

# Inside node:
$ systemctl status kubelet
$ dmesg | tail -50  # Check for hardware errors
$ df -h             # Check disk space
$ free -h           # Check memory
$ top               # Check processes

# Exit
$ exit
```

### **3. Check AWS Instance Status**

```bash
# Instance status check
aws ec2 describe-instance-status \
  --instance-ids <instance-id> \
  --region us-east-1 | jq '.InstanceStatuses[0].{InstanceStatus:.InstanceStatus,SystemStatus:.SystemStatus}'

# If StatusChecks show "failed", instance is unhealthy
```

---

## Root Cause Analysis

### **Is the Node Recoverable?**

**Step 1: Check kubelet status**
```bash
kubectl describe node <node-name> | grep -A 20 "Conditions:"
# NotReady = kubelet not responding
# MemoryPressure = Out of memory
# DiskPressure = Out of disk space
# PIDPressure = Too many processes
```

**Step 2: Check kubelet logs** (if accessible)
```bash
# SSH into node
aws ssm start-session --target <instance-id>

# View kubelet logs
$ sudo journalctl -u kubelet -n 100

# Common issues:
# - "OOMKilled" = Out of memory
# - "disk space" = Disk full
# - "connection refused" = API server unreachable
```

**Step 3: Check pod utilization**
```bash
# Before proceeding, check if workloads can reschedule
kubectl get nodes -o wide
# If HPA or DaemonSets expect this node, they may not respawn

# Check Karpenter (if using)
kubectl get nodes -L karpenter.sh/capacity-type
```

---

## Recovery Procedures

### **Recovery: Graceful Drain & Replace (Preferred)**

**Step 1: Drain the node** (moves pods to other nodes)
```bash
# Mark node as unschedulable
kubectl cordon <node-name>

# Drain pods (wait for graceful termination)
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --pod-selector='app!=prometheus' \
  --timeout=5m

# Monitor draining
kubectl get pods -n trading -o wide | grep <node-name>
# Should eventually show no pods on node
```

**Step 2: Terminate unhealthy node**
```bash
# Get the instance ID
INSTANCE_ID=$(kubectl describe node <node-name> | grep ProviderID | awk -F'/' '{print $NF}')

# Terminate (ASG will replace it automatically)
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region us-east-1

# Monitor replacement
kubectl get nodes -w
# Watch for new node appearing
```

**Step 3: Verify replacement node is healthy**
```bash
# Wait for new node to appear
kubectl get nodes -o wide

# Check new node is Ready
kubectl get nodes <new-node-name> -o wide
# STATUS should be: Ready

# Check capacity
kubectl describe node <new-node-name> | grep -A 5 "Allocatable"
```

**Step 4: Reschedule evicted pods**
```bash
# Pods should automatically respawn due to Deployments/StatefulSets
kubectl get pods -n trading -o wide | grep "Pending"
# Should gradually move to Running

# Verify trading services are back
kubectl get deployment -n trading
# READY column should show all replicas ready

# Run smoke tests
bash scripts/smoke-tests.sh
```

---

### **Recovery: Force Delete (Emergency Only)**

If drain hangs and node is truly dead:

```bash
# **WARNING:** Only use if node is completely unreachable

# Get node name
NODE_NAME=$(kubectl get nodes | grep NotReady | awk '{print $1}')

# Delete node from K8s (pods will respawn elsewhere)
kubectl delete node $NODE_NAME

# Terminate EC2 instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=$NODE_NAME" \
  --region us-east-1 | jq -r '.Reservations[0].Instances[0].InstanceId')

aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region us-east-1
```

---

### **Recovery: Reboot Node**

If node is responsive but just needs restart:

```bash
# SSH into node
aws ssm start-session --target <instance-id>

# Graceful reboot
$ sudo systemctl reboot

# Monitor from cluster
kubectl get nodes <node-name> -w
# Watch status: NotReady → Ready
```

---

## Verification

### **Immediate (T+5 min)**

```bash
# 1. Is new node Ready?
kubectl get nodes
# All should show STATUS: Ready

# 2. Are pods rescheduled?
kubectl get pods -n trading -o wide | grep -v Running
# Should be empty (or only Completed/Succeeded)

# 3. Are metrics coming in?
kubectl get nodes -o wide | head -3
# NAME, STATUS, ROLES, AGE columns should all show data
```

### **Validation (T+10 min)**

```bash
# 1. Run smoke tests
bash scripts/smoke-tests.sh

# 2. Check order service
kubectl logs -n trading -l app=order-service --tail=20 | grep -c "error"
# Should be very low (< 5 errors in 20 lines)

# 3. Verify no pod restarts
kubectl get pods -n trading -o wide | awk '{print $4}' | grep -v "RESTARTS" | grep -v "^0$"
# Should be empty (all 0 restarts)

# 4. Check PVC attachments
kubectl get pvc -n trading
# All should show STATUS: Bound
```

---

## Network Drain (If Node Unreachable)

If node is completely unreachable (network down):

```bash
# 1. Check security group
aws ec2 describe-security-groups \
  --group-ids <sg-id> \
  --region us-east-1 | jq '.SecurityGroups[0].IpPermissions'

# 2. Check network ACLs
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=<subnet-id>" \
  --region us-east-1

# 3. If misconfigured, fix and retry node drain
# Once network restored, proceed with graceful drain

# 4. If network dead, use force delete above
```

---

## Post-Recovery

### **Immediate**
- [ ] Alert team: "Node $NODE_NAME recovered"
- [ ] Monitor new node for stability (30 min)
- [ ] Verify no data loss

### **Within 24h**
- [ ] Review CloudWatch logs for failure cause
- [ ] Check AWS support for hardware issues
- [ ] Document in runbook if new issue discovered

### **Within 1 week**
- [ ] Add node failure test to disaster recovery drills
- [ ] Review node resource sizing (was node undersized?)
- [ ] Check autoscaling group configuration

---

## Preventing Node Failures

### **Proactive Measures**
- [ ] Monitor node CPU/memory/disk regularly
- [ ] Set PodDisruptionBudget for critical services
- [ ] Use Karpenter for automatic node replacement
- [ ] Consolidate workloads during predictable peaks
- [ ] Use spot instances only for non-critical workloads

### **Early Warning**
```bash
# Watch for nodes approaching limits
watch -n 5 'kubectl top nodes'

# Check for pods getting evicted
kubectl get events -n trading --sort-by='.lastTimestamp' | grep -i evict

# Monitor kubelet health
kubectl get nodes -o custom-columns=NAME:.metadata.name,MEMORY:.status.allocatable.memory,DISK:.status.allocatable.ephemeralStorage
```

---

## Quick Command Reference

```bash
# Get node status
kubectl get nodes -o wide

# Get detailed node info
kubectl describe node <node-name>

# Drain node (graceful)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --timeout=5m

# Mark unschedulable (without draining)
kubectl cordon <node-name>

# Allow scheduling again
kubectl uncordon <node-name>

# Get pods on specific node
kubectl get pods --all-namespaces -o wide | grep <node-name>

# Delete node (force)
kubectl delete node <node-name>

# Check kubelet logs (via SSH)
sudo journalctl -u kubelet -n 100 -f

# Check disk usage
df -h /

# Check memory
free -h

# Reboot
sudo systemctl reboot
```

---

## Escalation

| Time | Action | Owner |
|---|---|---|
| T+0 | Node failure detected | On-call |
| T+5m | No auto-recovery? | Escalate to K8s ops |
| T+15m | Pod losses accumulating? | Page VP Eng |
| T+30m | Multiple node failures? | Infrastructure incident |

---

**Last Updated:** 2026-06-19  
**Maintained By:** Infrastructure Team

**Related:**
- [Rollback](./rollback.md)
- [Order Service Degradation](./order-service-degradation.md)
