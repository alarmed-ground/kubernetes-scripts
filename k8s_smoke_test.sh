#!/usr/bin/env bash
# =============================================================================
# k8s_smoke_test.sh — Post-install smoke tests
# Run this AFTER k8s_cluster_setup.sh completes
# =============================================================================
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

check() {
  local desc="$1"; shift
  if eval "$*" &>/dev/null; then pass "$desc"; else fail "$desc"; fi
}

echo "=================================================="
echo " Kubernetes Cluster Smoke Tests"
echo "=================================================="

# ── Connectivity ──────────────────────────────────────────────────────────────
echo -e "\n--- Cluster Connectivity ---"
check "kubectl can reach API server" "kubectl cluster-info"
check "All nodes are Ready" \
  "kubectl get nodes --no-headers | awk '{print \$2}' | grep -v Ready | wc -l | grep -q '^0$'"

# ── Core System Pods ──────────────────────────────────────────────────────────
echo -e "\n--- Core System Pods ---"
check "kube-system pods Running" \
  "kubectl get pods -n kube-system --no-headers | grep -v Running | grep -v Completed | wc -l | grep -q '^0$'"
check "CoreDNS is Running" \
  "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep Running"
check "CNI pods are Running" \
  "kubectl get pods -n kube-flannel,kube-system --no-headers 2>/dev/null | grep -iE 'flannel|calico' | grep Running"

# ── Monitoring ────────────────────────────────────────────────────────────────
echo -e "\n--- Monitoring Stack ---"
check "Prometheus pod Running" \
  "kubectl get pods -n monitoring --no-headers | grep prometheus-kube-prometheus-stack | grep Running"
check "Grafana pod Running" \
  "kubectl get pods -n monitoring --no-headers | grep grafana | grep Running"
check "Alertmanager pod Running" \
  "kubectl get pods -n monitoring --no-headers | grep alertmanager | grep Running"
check "Prometheus NodePort service exists" \
  "kubectl get svc -n monitoring | grep NodePort"

# ── GPU Operator ──────────────────────────────────────────────────────────────
echo -e "\n--- GPU Operator ---"
if kubectl get ns gpu-operator &>/dev/null; then
  check "GPU operator namespace exists" "kubectl get ns gpu-operator"
  check "GPU operator pods Running" \
    "kubectl get pods -n gpu-operator --no-headers | grep Running | wc -l | grep -v '^0$'"
  ALLOCATABLE=$(kubectl get nodes -o json | jq '[.items[].status.allocatable."nvidia.com/gpu" // "0" | tonumber] | add')
  if (( ALLOCATABLE > 0 )); then
    pass "GPU resources allocatable: ${ALLOCATABLE}"
  else
    warn "No GPU resources detected (nvidia.com/gpu = 0). Check node labels and GPU Operator logs."
  fi
else
  warn "GPU Operator namespace not found — was GPU Operator skipped?"
fi

# ── NFS Provisioner ───────────────────────────────────────────────────────────
echo -e "\n--- NFS Provisioner ---"
if kubectl get ns nfs-provisioner &>/dev/null; then
  check "NFS provisioner pod Running" \
    "kubectl get pods -n nfs-provisioner --no-headers | grep Running"
  check "nfs-client StorageClass exists" \
    "kubectl get storageclass nfs-client"

  # Test dynamic provisioning
  cat <<'PVTEST' | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-test-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-client
  resources:
    requests:
      storage: 100Mi
PVTEST
  sleep 10
  PVC_STATUS=$(kubectl get pvc smoke-test-pvc -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$PVC_STATUS" == "Bound" ]]; then
    pass "NFS PVC dynamically provisioned (Bound)"
  else
    fail "NFS PVC status: ${PVC_STATUS} (expected Bound)"
  fi
  kubectl delete pvc smoke-test-pvc -n default --ignore-not-found &>/dev/null
else
  warn "NFS provisioner namespace not found — was NFS skipped?"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo -e "  Tests passed: ${GREEN}${PASS}${NC}  |  Tests failed: ${RED}${FAIL}${NC}"
echo "=================================================="
(( FAIL == 0 )) && echo -e "${GREEN}All checks passed — cluster looks healthy!${NC}" \
                || echo -e "${RED}${FAIL} check(s) failed — review output above.${NC}"
exit $FAIL
