#!/usr/bin/env bash
# =============================================================================
# k8s_cluster_setup.sh — Entry point for the modular Kubernetes installer
#
# Structure:
#   k8s_cluster_setup.sh    This file — paths, config loading, sourcing,
#                           main(), CLI dispatch
#   lib/logging.sh          Colour constants + log/warn/error/info/section
#   lib/config.sh           All configuration variable defaults
#   lib/helpers.sh          SSH/SCP helpers, local-node detection
#   lib/checks.sh           check_root, check_lock, validate_config
#   lib/node_scripts.sh     Heredoc generators for remote scripts
#   steps/NN_*.sh           One file per install step (01–15)
#   steps/addon_*.sh        Optional add-on components
#   steps/ops_*.sh          Day-2 operational commands
#   steps/uninstall.sh      Interactive cluster teardown
# =============================================================================
set -euo pipefail
# IFS left at default — a non-default IFS breaks array parsing in sourced
# conf files and space-delimited for-loops in is_local_node.

trap 'echo "[FATAL] Script aborted at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
STEPS_DIR="${SCRIPT_DIR}/steps"
LOG_FILE="${SCRIPT_DIR}/k8s_install_$(date +%Y%m%d_%H%M%S).log"
LATEST_LOG="${SCRIPT_DIR}/k8s_install_latest.log"
LOCK_FILE="/tmp/k8s_install.lock"
CONFIG_FILE="${SCRIPT_DIR}/k8s_cluster.conf"

# ── Logging (must come before config loading so errors can be reported) ───────
# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"

# ── External config ───────────────────────────────────────────────────────────
# When sourced for testing, suppress config loading so test fixtures control all
# variable values without interference from a real k8s_cluster.conf file.
[[ "${K8S_SOURCE_ONLY:-}" == "true" ]] && CONFIG_FILE=/dev/null

if [[ -f "$CONFIG_FILE" ]]; then
  set +e
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  _src_rc=$?
  set -e
  if (( _src_rc != 0 )); then
    echo "[config] ERROR: Failed to source ${CONFIG_FILE} (exit ${_src_rc})." >&2
    echo "[config] Check for syntax errors: bash -n ${CONFIG_FILE}" >&2
    exit 1
  fi
  echo "[config] Loaded configuration from ${CONFIG_FILE}"
else
  echo "[config] No k8s_cluster.conf found — using built-in defaults."
  echo "[config] Run './k8s_configure.sh' to generate a config interactively."
fi

# ── Configuration defaults (applied after conf file so file values win) ───────
# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"

# ── Source all modules ────────────────────────────────────────────────────────
_source_modules() {
  local missing=0

  # lib — dependency order matters: helpers before checks (checks calls helpers)
  for f in \
    "${LIB_DIR}/helpers.sh" \
    "${LIB_DIR}/checks.sh" \
    "${LIB_DIR}/node_scripts.sh"
  do
    if [[ ! -f "$f" ]]; then
      echo "[FATAL] Required lib module missing: ${f}" >&2
      missing=$(( missing + 1 ))
    else
      # shellcheck source=/dev/null
      source "$f"
    fi
  done

  # steps — sourcing order does not affect execution order (main() controls that)
  for f in \
    "${STEPS_DIR}/01_ssh.sh" \
    "${STEPS_DIR}/02_prep.sh" \
    "${STEPS_DIR}/03_nvidia.sh" \
    "${STEPS_DIR}/04_k8s_bins.sh" \
    "${STEPS_DIR}/05_init.sh" \
    "${STEPS_DIR}/06_cni.sh" \
    "${STEPS_DIR}/07_workers.sh" \
    "${STEPS_DIR}/08_helm.sh" \
    "${STEPS_DIR}/09_nfs.sh" \
    "${STEPS_DIR}/10_monitoring.sh" \
    "${STEPS_DIR}/11_gpu_operator.sh" \
    "${STEPS_DIR}/12_gpu_timeslice.sh" \
    "${STEPS_DIR}/13_dashboard.sh" \
    "${STEPS_DIR}/14_vllm.sh" \
    "${STEPS_DIR}/15_verify.sh" \
    "${STEPS_DIR}/addon_ceph.sh" \
    "${STEPS_DIR}/addon_minio.sh" \
    "${STEPS_DIR}/addon_ingress.sh" \
    "${STEPS_DIR}/addon_metallb.sh" \
    "${STEPS_DIR}/addon_cert_manager.sh" \
    "${STEPS_DIR}/addon_harden.sh" \
    "${STEPS_DIR}/addon_registry.sh" \
    "${STEPS_DIR}/addon_argocd.sh" \
    "${STEPS_DIR}/addon_loki.sh" \
    "${STEPS_DIR}/ops_backup.sh" \
    "${STEPS_DIR}/ops_certs.sh" \
    "${STEPS_DIR}/ops_upgrade.sh" \
    "${STEPS_DIR}/ops_nodes.sh" \
    "${STEPS_DIR}/ops_vllm_swap.sh" \
    "${STEPS_DIR}/uninstall.sh"
  do
    if [[ ! -f "$f" ]]; then
      echo "[FATAL] Required step module missing: ${f}" >&2
      missing=$(( missing + 1 ))
    else
      # shellcheck source=/dev/null
      source "$f"
    fi
  done

  if (( missing > 0 )); then
    echo "[FATAL] ${missing} module file(s) missing. Run from the k8s-install directory." >&2
    exit 1
  fi
}

# Skip sourcing when running tests that only need config/logging
[[ "${K8S_SOURCE_ONLY:-}" != "true" ]] && _source_modules

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  section "Kubernetes Cluster Installer — Ubuntu 24.04"
  info "Log file: ${LOG_FILE}"
  ln -sf "$LOG_FILE" "${LATEST_LOG}" 2>/dev/null || true

  check_root
  check_lock
  validate_config

  _step=0
  _step_total=15
  _next_step() { _step=$(( _step + 1 )); info ""; info "════ Step ${_step}/${_step_total} ════"; }

  _next_step; setup_ssh_keys
  _next_step; prepare_all_nodes
  _next_step; install_nvidia_drivers
  _next_step; install_k8s_binaries
  _next_step; init_control_plane

  export KUBECONFIG="/root/.kube/config"

  if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
    info "Single-node cluster — removing control-plane NoSchedule taint..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- \
      2>/dev/null || true
    kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- \
      2>/dev/null || true
    log "Control-plane taint removed."
  fi

  _next_step; install_cni
  _next_step; join_workers
  _next_step; install_helm
  _next_step; install_nfs_provisioner
  _next_step; install_monitoring
  _next_step; install_gpu_operator
  _next_step; configure_gpu_timeslicing
  _next_step; install_dashboard
  _next_step; install_vllm

  # Optional add-ons — only run when their INSTALL_* flag is true
  install_ceph
  install_minio
  install_ingress
  install_metallb
  install_cert_manager
  install_registry
  install_argocd
  install_loki
  [[ "${INSTALL_HARDEN:-false}" == "true" ]] && harden_cluster

  _next_step; verify_cluster

  section "Installation Complete!"
  log "Cluster is up and running."
  info "KUBECONFIG: /root/.kube/config"
  info "Run: export KUBECONFIG=/root/.kube/config"
  info "Then: kubectl get nodes"
  echo ""
  info "Standalone steps: backup restore cert-renew upgrade add-node remove-node"
  info "                  ceph minio ingress metallb cert-manager harden registry"
  info "                  argocd loki vllm-swap"
}

# ── CLI dispatch ──────────────────────────────────────────────────────────────
# Skip entirely when sourced for testing (K8S_SOURCE_ONLY=true)
[[ "${K8S_SOURCE_ONLY:-}" == "true" ]] && return 0 2>/dev/null || true

if [[ "${1:-}" == "--backup" && -n "${2:-}" ]]; then
  export RESTORE_SNAPSHOT="$2"; shift 2
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  check_root; validate_config; uninstall_cluster
elif [[ "${1:-}" == "--step" && -n "${2:-}" ]]; then
  check_root; validate_config
  export KUBECONFIG="/root/.kube/config"
  case "$2" in
    ssh)                                          setup_ssh_keys ;;
    prep|node-prep|"Node Preparation")            prepare_all_nodes ;;
    nvidia|"nvidia drivers"|"NVIDIA")             install_nvidia_drivers ;;
    k8s-bins|"k8s bins"|"Kubernetes Binaries")    install_k8s_binaries ;;
    init|"control plane"|"Control Plane Init")    init_control_plane ;;
    cni|CNI|"CNI Plugin")                         install_cni ;;
    workers|"join workers"|"Join Workers")        join_workers ;;
    helm|Helm|"Install Helm")                     install_helm ;;
    nfs|NFS|"NFS Provisioner")                    install_nfs_provisioner ;;
    monitoring|prometheus|grafana)                install_monitoring ;;
    gpu-op|"gpu operator"|"GPU Operator")         install_gpu_operator ;;
    gpu-timeslice|timeslice|"time-slicing")       configure_gpu_timeslicing ;;
    dashboard|Dashboard|"Kubernetes Dashboard")   install_dashboard ;;
    vllm|vLLM|"vLLM Stack"|"vLLM Production Stack") install_vllm ;;
    vllm-swap|"vllm swap"|"swap model")           vllm_swap ;;
    backup)                                       backup_cluster ;;
    restore)                                      restore_cluster ;;
    cert-renew|"cert renew"|"renew certs")        renew_certs ;;
    upgrade|"k8s upgrade"|"cluster upgrade")      upgrade_cluster ;;
    add-node|"add node")                          add_node ;;
    remove-node|"remove node")                    remove_node ;;
    ceph|rook-ceph|"rook ceph")                   install_ceph ;;
    minio)                                        install_minio ;;
    ingress|ingress-nginx)                        install_ingress ;;
    metallb)                                      install_metallb ;;
    cert-manager|certmanager)                     install_cert_manager ;;
    harden|cis|hardening)                         harden_cluster ;;
    registry|docker-registry)                     install_registry ;;
    argocd|argo-cd|gitops)                        install_argocd ;;
    loki|logging|loki-promtail)                   install_loki ;;
    verify|Verify|verification)                   verify_cluster ;;
    uninstall|Uninstall)                          uninstall_cluster ;;
    *)
      error "Unknown step: $2"
      error "Core steps:     ssh prep nvidia k8s-bins init cni workers"
      error "                helm nfs monitoring gpu-op gpu-timeslice dashboard vllm verify"
      error "Standalone ops: backup restore cert-renew upgrade add-node remove-node vllm-swap"
      error "Add-ons:        ceph minio ingress metallb cert-manager harden registry argocd loki"
      exit 1 ;;
  esac
else
  main "$@"
fi
