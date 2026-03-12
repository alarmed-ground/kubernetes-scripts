#!/usr/bin/env bash
# =============================================================================
# k8s_configure.sh — Interactive Configuration Wizard
# Collects all cluster parameters, validates them, writes k8s_cluster.conf,
# and optionally launches the installer.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/k8s_cluster.conf"
INSTALLER="${SCRIPT_DIR}/k8s_cluster_setup.sh"

# ──────────────────────────────────────────────────────────────────────────────
# COLORS & UI PRIMITIVES
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';      DIM='\033[2m';      NC='\033[0m'

# Symbols
SYM_OK="✔";  SYM_ERR="✖";  SYM_WARN="⚠";  SYM_ARROW="▶";  SYM_DOT="•"

print_header() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║       Kubernetes Cluster Installer — Configuration Wizard    ║"
  echo "  ║                      Ubuntu 24.04                           ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

section_header() {
  local title="$1"
  local step="${2:-}"
  echo ""
  echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────────────────────┐${NC}"
  if [[ -n "$step" ]]; then
    printf "${BOLD}${CYAN}  │  %-3s  %-52s│${NC}\n" "${step}" "${title}"
  else
    printf "${BOLD}${CYAN}  │  %-57s│${NC}\n" "${title}"
  fi
  echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────────────────────┘${NC}"
  echo ""
}

hint()    { echo -e "  ${DIM}${CYAN}${SYM_DOT} $*${NC}"; }
ok()      { echo -e "  ${GREEN}${SYM_OK}  $*${NC}"; }
err()     { echo -e "  ${RED}${SYM_ERR}  $*${NC}"; }
warn_msg(){ echo -e "  ${YELLOW}${SYM_WARN}  $*${NC}"; }
label()   { echo -e "  ${BOLD}${SYM_ARROW} $*${NC}"; }

# Progress bar across sections
TOTAL_SECTIONS=10
CURRENT_SECTION=0
show_progress() {
  CURRENT_SECTION=$((CURRENT_SECTION + 1))
  local filled=$((CURRENT_SECTION * 40 / TOTAL_SECTIONS))
  local empty=$((40 - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++));  do bar+="░"; done
  echo -e "\n  ${DIM}Progress: [${CYAN}${bar}${NC}${DIM}] ${CURRENT_SECTION}/${TOTAL_SECTIONS}${NC}\n"
}

# ──────────────────────────────────────────────────────────────────────────────
# INPUT HELPERS
# ──────────────────────────────────────────────────────────────────────────────

# prompt_input VAR_NAME "Question" "default" ["secret"]
prompt_input() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local secret="${4:-}"
  local input=""

  while true; do
    if [[ -n "$default" ]]; then
      echo -ne "  ${BOLD}${question}${NC} ${DIM}[${default}]${NC}: "
    else
      echo -ne "  ${BOLD}${question}${NC}: "
    fi

    if [[ "$secret" == "secret" ]]; then
      read -r -s input
      echo ""
    else
      read -r input
    fi

    input="${input:-$default}"

    if [[ -z "$input" ]]; then
      err "This field is required."
    else
      eval "${var_name}='${input}'"
      return 0
    fi
  done
}

# prompt_optional VAR_NAME "Question" "default"
prompt_optional() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local input=""

  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${question}${NC} ${DIM}[${default}]${NC} ${DIM}(optional, Enter to skip)${NC}: "
  else
    echo -ne "  ${BOLD}${question}${NC} ${DIM}(optional, Enter to skip)${NC}: "
  fi
  read -r input
  eval "${var_name}='${input:-$default}'"
}

# prompt_choice VAR_NAME "Question" option1 option2 ...
prompt_choice() {
  local var_name="$1"
  local question="$2"
  shift 2
  local options=("$@")
  local choice=""
  local valid=false

  echo -e "  ${BOLD}${question}${NC}"
  for i in "${!options[@]}"; do
    echo -e "    ${CYAN}$((i+1))${NC}) ${options[$i]}"
  done

  while ! $valid; do
    echo -ne "  ${BOLD}Enter choice [1-${#options[@]}]${NC}: "
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      eval "${var_name}='${options[$((choice-1))]}'"
      valid=true
    else
      err "Invalid choice. Enter a number between 1 and ${#options[@]}."
    fi
  done
}

# prompt_yes_no VAR_NAME "Question" "y|n"
prompt_yes_no() {
  local var_name="$1"
  local question="$2"
  local default="${3:-n}"
  local input=""
  local display="y/N"
  [[ "$default" == "y" ]] && display="Y/n"

  while true; do
    echo -ne "  ${BOLD}${question}${NC} ${DIM}[${display}]${NC}: "
    read -r input
    input="${input:-$default}"
    input="${input,,}"
    case "$input" in
      y|yes) eval "${var_name}=true";  return ;;
      n|no)  eval "${var_name}=false"; return ;;
      *)     err "Please enter y or n." ;;
    esac
  done
}

# prompt_ip VAR_NAME "Question" "default"
prompt_ip() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local input=""

  while true; do
    prompt_input "$var_name" "$question" "$default"
    eval "input=\${${var_name}}"
    if validate_ip "$input"; then
      return 0
    else
      err "'${input}' is not a valid IPv4 address."
    fi
  done
}

# prompt_ip_optional VAR_NAME "Question" "default"
prompt_ip_optional() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local input=""

  while true; do
    prompt_optional "$var_name" "$question" "$default"
    eval "input=\${${var_name}}"
    if [[ -z "$input" ]]; then
      return 0
    elif validate_ip "$input"; then
      return 0
    else
      err "'${input}' is not a valid IPv4 address."
    fi
  done
}

# Collect multiple IPs into an array variable name (as string)
prompt_ip_list() {
  local var_name="$1"   # will hold a bash-array-syntax string
  local question="$2"
  local ips=()
  local ip=""
  local more=true

  echo -e "  ${BOLD}${question}${NC}"
  hint "Enter one IP per line. Press Enter on a blank line when done."
  echo ""

  local index=1
  while $more; do
    while true; do
      echo -ne "  ${BOLD}Worker ${index} IP${NC} ${DIM}(blank to finish)${NC}: "
      read -r ip
      if [[ -z "$ip" ]]; then
        more=false; break
      elif validate_ip "$ip"; then
        ips+=("$ip")
        ok "Added worker: ${ip}"
        index=$((index + 1))
        break
      else
        err "'${ip}' is not a valid IPv4 address."
      fi
    done
  done

  # Build array string: ("ip1" "ip2" ...)
  local arr_str="("
  for i in "${ips[@]:-}"; do
    [[ -n "$i" ]] && arr_str+="\"$i\" "
  done
  arr_str="${arr_str% })"
  eval "${var_name}='${arr_str}'"
}

# ──────────────────────────────────────────────────────────────────────────────
# VALIDATORS
# ──────────────────────────────────────────────────────────────────────────────
validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( octet <= 255 )) || return 1
  done
  return 0
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  validate_ip "$ip" || return 1
  (( prefix <= 32 )) || return 1
  return 0
}

validate_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

validate_password_strength() {
  local pw="$1"
  [[ ${#pw} -ge 12 ]]           || { err "Password must be at least 12 characters.";         return 1; }
  [[ "$pw" =~ [A-Z] ]]          || { err "Password must contain at least one uppercase letter."; return 1; }
  [[ "$pw" =~ [a-z] ]]          || { err "Password must contain at least one lowercase letter."; return 1; }
  [[ "$pw" =~ [0-9] ]]          || { err "Password must contain at least one digit.";         return 1; }
  [[ "$pw" =~ [^a-zA-Z0-9] ]]  || { err "Password must contain at least one special character."; return 1; }
  return 0
}

validate_abs_path() {
  [[ "$1" == /* ]] || { err "Path must be absolute (start with /)."; return 1; }
  return 0
}

validate_k8s_version() {
  [[ "$1" =~ ^1\.[2-9][0-9]$ ]] || { err "K8s version must be in format 1.XX (e.g. 1.31)."; return 1; }
  return 0
}

validate_helm_version() {
  validate_semver "$1" || { err "Helm version must be in semver format (e.g. 3.16.2)."; return 1; }
  return 0
}

validate_namespace() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
    err "Namespace must be lowercase alphanumeric with hyphens, no leading/trailing hyphens."
    return 1
  }
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 1 — SSH & Node Access
# ──────────────────────────────────────────────────────────────────────────────
collect_ssh() {
  section_header "SSH & Node Access" "1/8"
  hint "These credentials are used to connect to all cluster nodes."
  echo ""

  prompt_input SSH_USER "Remote username" "ubuntu"
  ok "SSH user: ${SSH_USER}"

  prompt_input SSH_KEY_PATH "SSH private key path (will be generated if missing)" \
    "${HOME}/.ssh/k8s_cluster_rsa"
  ok "Key path: ${SSH_KEY_PATH}"

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Cluster Nodes
# ──────────────────────────────────────────────────────────────────────────────
collect_nodes() {
  section_header "Cluster Node IPs" "2/8"
  hint "Enter the IP addresses for your control plane and worker nodes."
  hint "All nodes must be running Ubuntu 24.04 and reachable via SSH."
  echo ""

  prompt_ip CONTROL_PLANE_IP "Control plane IP" ""
  ok "Control plane: ${CONTROL_PLANE_IP}"
  echo ""

  prompt_ip_list WORKER_IPS_STR "Worker node IPs"
  echo ""

  # Parse count for display
  local count=0
  if [[ "$WORKER_IPS_STR" != "()" ]]; then
    count=$(echo "$WORKER_IPS_STR" | grep -o '"' | wc -l)
    count=$((count / 2))
  fi
  if (( count == 0 )); then
    warn_msg "No workers added — single-node cluster (control plane will be un-tainted)."
  else
    ok "${count} worker node(s) registered."
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Kubernetes Settings
# ──────────────────────────────────────────────────────────────────────────────
collect_k8s() {
  section_header "Kubernetes Settings" "3/8"
  echo ""

  # K8s version
  while true; do
    prompt_input K8S_VERSION "Kubernetes version (minor)" "1.31"
    validate_k8s_version "$K8S_VERSION" && ok "K8s version: ${K8S_VERSION}" && break
  done
  echo ""

  # CNI
  prompt_choice CNI_PLUGIN "Container Network Interface (CNI) plugin" \
    "flannel" "calico"
  echo ""

  # Pod CIDR — auto-default by CNI
  local default_cidr="10.244.0.0/16"
  [[ "$CNI_PLUGIN" == "calico" ]] && default_cidr="192.168.0.0/16"

  while true; do
    prompt_input POD_CIDR "Pod network CIDR" "$default_cidr"
    validate_cidr "$POD_CIDR" && ok "Pod CIDR: ${POD_CIDR}" && break
    err "'${POD_CIDR}' is not a valid CIDR."
  done
  echo ""

  # Helm version
  while true; do
    prompt_input HELM_VERSION "Helm version" "3.16.2"
    validate_helm_version "$HELM_VERSION" && ok "Helm: ${HELM_VERSION}" && break
  done

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 4 — NVIDIA Drivers
# ──────────────────────────────────────────────────────────────────────────────
collect_nvidia() {
  section_header "NVIDIA Drivers" "4/8"
  hint "The installer auto-detects GPUs via lspci and skips non-GPU nodes."
  echo ""

  prompt_yes_no INSTALL_NVIDIA "Install NVIDIA drivers and GPU Operator?" "y"
  echo ""

  if [[ "$INSTALL_NVIDIA" == "true" ]]; then

    # ── Driver Branch ─────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Driver Branch Reference:${NC}"
    echo -e "  ${DIM}  590  │ LATEST   │ RTX 50xx, GB200/B200/B100 (Blackwell), H200${NC}"
    echo -e "  ${DIM}  580  │ Latest-1 │ RTX 50xx, Blackwell, H200 — previous latest${NC}"
    echo -e "  ${DIM}  570  │ Stable   │ RTX 50xx, Blackwell, H200 — stable${NC}"
    echo -e "  ${DIM}  565  │ Stable   │ RTX 40xx, A/H series — production stable${NC}"
    echo -e "  ${DIM}  560  │ Stable   │ RTX 40xx, A/H series — previous stable${NC}"
    echo -e "  ${DIM}  550  │ LTS      │ Ampere/Hopper/Lovelace — widely deployed${NC}"
    echo -e "  ${DIM}  535  │ LTS      │ Ampere DataCenter A100/A30/A10${NC}"
    echo -e "  ${DIM}  525  │ Legacy   │ Older Ampere platforms${NC}"
    echo ""

    prompt_choice NVIDIA_DRIVER_VERSION \
      "Select NVIDIA driver branch" \
      "590 (LATEST — Blackwell/RTX 50xx/GB200/H200)" \
      "580 (Previous latest — Blackwell/RTX 50xx/H200)" \
      "570 (Stable — Blackwell/RTX 50xx/H200)" \
      "565 (Stable — RTX 40xx / A-H series)" \
      "560 (Previous stable — RTX 40xx / A-H series)" \
      "550 (LTS — Ampere/Hopper/Lovelace — recommended for older HW)" \
      "535 (LTS — Ampere DataCenter A100/A30/A10)" \
      "525 (Legacy LTS — older Ampere)"

    # Strip the description, keep only the version number
    NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION%% *}"
    ok "NVIDIA driver branch: ${NVIDIA_DRIVER_VERSION}"
    echo ""

    # ── Open Kernel Modules ───────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Open Kernel Modules:${NC}"
    echo -e "  ${DIM}  Recommended for Turing (RTX 20xx) and newer GPUs.${NC}"
    echo -e "  ${DIM}  REQUIRED for Blackwell (B-series). Adds better driver stability${NC}"
    echo -e "  ${DIM}  and faster feature adoption. Installs nvidia-driver-*-open package.${NC}"
    echo ""

  # Auto-suggest open kernel for 590/570 (Blackwell requires it)
    local default_open="n"
    if [[ "$NVIDIA_DRIVER_VERSION" == "590" || "$NVIDIA_DRIVER_VERSION" == "580" || "$NVIDIA_DRIVER_VERSION" == "570" ]]; then
      default_open="y"
      hint "Branch ${NVIDIA_DRIVER_VERSION} targets Blackwell/RTX 50xx — open kernel modules are strongly recommended."
    fi

    prompt_yes_no NVIDIA_OPEN_KERNEL "Use open kernel modules (nvidia-driver-${NVIDIA_DRIVER_VERSION}-open)?" "$default_open"
    if [[ "$NVIDIA_OPEN_KERNEL" == "true" ]]; then
      ok "Open kernel modules: enabled (nvidia-driver-${NVIDIA_DRIVER_VERSION}-open)"
    else
      ok "Open kernel modules: disabled (nvidia-driver-${NVIDIA_DRIVER_VERSION} proprietary)"
    fi
    echo ""

    # ── Fabric Manager ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Fabric Manager:${NC}"
    echo -e "  ${DIM}  Required for NVLink / NVSwitch multi-GPU systems${NC}"
    echo -e "  ${DIM}  (A100 SXM4, H100 SXM5, H200 SXM, DGX, HGX platforms).${NC}"
    echo -e "  ${DIM}  Not needed for PCIe single-GPU nodes.${NC}"
    echo ""

    prompt_choice NVIDIA_FABRIC_MANAGER \
      "Fabric Manager installation" \
      "auto (detect NVSwitch/SXM at install time)" \
      "yes (always install)" \
      "no (never install)"

    case "$NVIDIA_FABRIC_MANAGER" in
      auto*) NVIDIA_FABRIC_MANAGER="auto" ;;
      yes*)  NVIDIA_FABRIC_MANAGER="true" ;;
      no*)   NVIDIA_FABRIC_MANAGER="false" ;;
    esac
    ok "Fabric Manager: ${NVIDIA_FABRIC_MANAGER}"
    echo ""

    # ── Reboot timeout ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Reboot Timeout:${NC}"
    echo -e "  ${DIM}  After the driver installs, each node reboots automatically.${NC}"
    echo -e "  ${DIM}  This is the maximum seconds to wait per node for SSH to return.${NC}"
    echo -e "  ${DIM}  Slow hardware or large initramfs may need 300-600s.${NC}"
    echo ""
    while true; do
      prompt_input NVIDIA_REBOOT_TIMEOUT "Seconds to wait per node after reboot" "300"
      [[ "$NVIDIA_REBOOT_TIMEOUT" =~ ^[0-9]+$ ]] && (( NVIDIA_REBOOT_TIMEOUT >= 60 )) \
        && ok "Reboot timeout: ${NVIDIA_REBOOT_TIMEOUT}s" && break
      err "Must be a number >= 60."
    done

  else
    NVIDIA_DRIVER_VERSION="590"
    NVIDIA_OPEN_KERNEL="false"
    NVIDIA_FABRIC_MANAGER="auto"
    NVIDIA_REBOOT_TIMEOUT="300"
    warn_msg "Skipping NVIDIA. GPU Operator will also be skipped."
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Monitoring (Prometheus + Grafana)
# ──────────────────────────────────────────────────────────────────────────────
collect_monitoring() {
  section_header "Monitoring Stack — Prometheus & Grafana" "5/8"
  hint "Deploys kube-prometheus-stack via Helm."
  echo ""

  prompt_yes_no INSTALL_MONITORING "Install Prometheus + Grafana?" "y"
  echo ""

  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    # Chart version
    prompt_input PROM_STACK_VERSION "kube-prometheus-stack chart version" "65.1.0"
    ok "Chart version: ${PROM_STACK_VERSION}"
    echo ""

    # Namespace
    while true; do
      prompt_input NS_MONITORING "Monitoring namespace" "monitoring"
      validate_namespace "$NS_MONITORING" && ok "Namespace: ${NS_MONITORING}" && break
    done
    echo ""

    # NodePort assignments
    hint "NodePort services will be exposed on the control plane IP."
    prompt_input GRAFANA_NODEPORT     "Grafana NodePort"      "32000"
    prompt_input PROMETHEUS_NODEPORT  "Prometheus NodePort"   "32001"
    prompt_input ALERTMANAGER_NODEPORT "Alertmanager NodePort" "32002"
    echo ""

    # Grafana admin password — with strength check & confirm
    local pw1="" pw2=""
    while true; do
      echo -ne "  ${BOLD}Grafana admin password${NC}: "
      read -r -s pw1; echo ""
      validate_password_strength "$pw1" || continue

      echo -ne "  ${BOLD}Confirm password${NC}: "
      read -r -s pw2; echo ""
      if [[ "$pw1" == "$pw2" ]]; then
        GRAFANA_ADMIN_PASSWORD="$pw1"
        ok "Grafana password set."
        break
      else
        err "Passwords do not match. Try again."
      fi
    done
    echo ""

    # Prometheus retention
    prompt_input PROM_RETENTION "Prometheus data retention" "30d"
    ok "Retention: ${PROM_RETENTION}"

    # Prometheus storage
    prompt_input PROM_STORAGE_SIZE "Prometheus PVC size" "20Gi"
    ok "Storage: ${PROM_STORAGE_SIZE}"

  else
    PROM_STACK_VERSION="65.1.0"
    NS_MONITORING="monitoring"
    GRAFANA_ADMIN_PASSWORD="ChangeMe123!"
    GRAFANA_NODEPORT="32000"
    PROMETHEUS_NODEPORT="32001"
    ALERTMANAGER_NODEPORT="32002"
    PROM_RETENTION="30d"
    PROM_STORAGE_SIZE="20Gi"
    warn_msg "Monitoring stack will be skipped."
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 6 — NFS External Provisioner
# ──────────────────────────────────────────────────────────────────────────────
collect_nfs() {
  section_header "NFS Storage Provisioner" "6/8"
  hint "Sets up dynamic PVC provisioning via an NFS server."
  echo ""

  prompt_yes_no INSTALL_NFS "Install NFS external provisioner?" "y"
  echo ""

  if [[ "$INSTALL_NFS" == "true" ]]; then
    prompt_ip_optional NFS_SERVER_IP "NFS server IP" "$CONTROL_PLANE_IP"
    ok "NFS server: ${NFS_SERVER_IP:-<none>}"
    echo ""

    while true; do
      prompt_input NFS_PATH "NFS export path on server" "/srv/nfs/k8s"
      validate_abs_path "$NFS_PATH" && ok "NFS path: ${NFS_PATH}" && break
    done
    echo ""

    # Namespace
    while true; do
      prompt_input NS_NFS "NFS provisioner namespace" "nfs-provisioner"
      validate_namespace "$NS_NFS" && ok "Namespace: ${NS_NFS}" && break
    done
    echo ""

    prompt_input NFS_STORAGE_CLASS "StorageClass name" "nfs-client"
    ok "StorageClass: ${NFS_STORAGE_CLASS}"

    prompt_yes_no NFS_DEFAULT_SC "Make this the default StorageClass?" "y"
    ok "Default SC: ${NFS_DEFAULT_SC}"

  else
    NFS_SERVER_IP=""
    NFS_PATH="/srv/nfs/k8s"
    NS_NFS="nfs-provisioner"
    NFS_STORAGE_CLASS="nfs-client"
    NFS_DEFAULT_SC="false"
    warn_msg "NFS provisioner will be skipped."
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 7 — Kubernetes Dashboard
# ──────────────────────────────────────────────────────────────────────────────
collect_dashboard() {
  section_header "Kubernetes Dashboard" "7/10"
  hint "Deploys the official Kubernetes Dashboard v2.7.0 with a NodePort service."
  hint "Access via https://<control-plane>:<nodeport> using a generated admin token."
  echo ""

  prompt_yes_no INSTALL_DASHBOARD "Install Kubernetes Dashboard?" "n"
  echo ""

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    DASHBOARD_VERSION="2.7.0"

    while true; do
      prompt_input DASHBOARD_NODEPORT "Dashboard NodePort (HTTPS)" "32443"
      [[ "$DASHBOARD_NODEPORT" =~ ^[0-9]+$ ]] \
        && (( DASHBOARD_NODEPORT >= 30000 && DASHBOARD_NODEPORT <= 32767 )) \
        && ok "Dashboard NodePort: ${DASHBOARD_NODEPORT}" && break
      err "NodePort must be between 30000 and 32767."
    done
    echo ""

    while true; do
      prompt_input NS_DASHBOARD "Dashboard namespace" "kubernetes-dashboard"
      validate_namespace "$NS_DASHBOARD" && ok "Namespace: ${NS_DASHBOARD}" && break
    done
  else
    DASHBOARD_VERSION="2.7.0"
    DASHBOARD_NODEPORT="32443"
    NS_DASHBOARD="kubernetes-dashboard"
    warn_msg "Dashboard will be skipped."
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 8 — vLLM Production Stack
# ──────────────────────────────────────────────────────────────────────────────
collect_vllm() {
  section_header "vLLM Production Stack" "8/10"
  hint "Deploys the vLLM production stack Helm chart for GPU-accelerated LLM inference."
  hint "Requires NVIDIA GPU Operator to be enabled."
  echo ""

  if [[ "$INSTALL_NVIDIA" != "true" ]]; then
    warn_msg "NVIDIA is disabled — vLLM requires GPU support and will be skipped."
    INSTALL_VLLM="false"
    VLLM_NAMESPACE="vllm"
    VLLM_NODEPORT="32080"
    VLLM_MODEL="meta-llama/Llama-3.2-1B-Instruct"
    VLLM_HF_TOKEN=""
    VLLM_DTYPE="auto"
    VLLM_MAX_MODEL_LEN="4096"
    VLLM_GPU_COUNT="1"
    VLLM_CPU_REQUEST="4"
    VLLM_CPU_LIMIT="8"
    VLLM_MEM_REQUEST="16Gi"
    VLLM_MEM_LIMIT="32Gi"
    VLLM_EXTRA_ARGS=""
    VLLM_STORAGE_SIZE="50Gi"
    VLLM_REUSE_PVC="false"
    VLLM_PVC_NAME="vllm-model-cache"
    show_progress
    return
  fi

  prompt_yes_no INSTALL_VLLM "Install vLLM production stack?" "n"
  echo ""

  if [[ "$INSTALL_VLLM" != "true" ]]; then
    VLLM_NAMESPACE="vllm"
    VLLM_NODEPORT="32080"
    VLLM_MODEL="meta-llama/Llama-3.2-1B-Instruct"
    VLLM_HF_TOKEN=""
    VLLM_DTYPE="auto"
    VLLM_MAX_MODEL_LEN="4096"
    VLLM_GPU_COUNT="1"
    VLLM_CPU_REQUEST="4"
    VLLM_CPU_LIMIT="8"
    VLLM_MEM_REQUEST="16Gi"
    VLLM_MEM_LIMIT="32Gi"
    VLLM_EXTRA_ARGS=""
    VLLM_STORAGE_SIZE="50Gi"
    VLLM_REUSE_PVC="false"
    VLLM_PVC_NAME="vllm-model-cache"
    warn_msg "vLLM stack will be skipped."
    show_progress
    return
  fi

  # ── Namespace & NodePort ───────────────────────────────────────────────────
  while true; do
    prompt_input VLLM_NAMESPACE "vLLM namespace" "vllm"
    validate_namespace "$VLLM_NAMESPACE" && ok "Namespace: ${VLLM_NAMESPACE}" && break
  done
  echo ""

  while true; do
    prompt_input VLLM_NODEPORT "vLLM router NodePort" "32080"
    [[ "$VLLM_NODEPORT" =~ ^[0-9]+$ ]] \
      && (( VLLM_NODEPORT >= 30000 && VLLM_NODEPORT <= 32767 )) \
      && ok "vLLM NodePort: ${VLLM_NODEPORT}" && break
    err "NodePort must be between 30000 and 32767."
  done
  echo ""

  # ── Model selection ────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Model${NC}"
  hint "Enter a HuggingFace model ID (e.g. meta-llama/Llama-3.2-1B-Instruct,"
  hint "  mistralai/Mistral-7B-Instruct-v0.3, Qwen/Qwen2.5-7B-Instruct)."
  hint "  The model will be downloaded on first pod startup."
  echo ""
  prompt_input VLLM_MODEL "HuggingFace model ID" "meta-llama/Llama-3.2-1B-Instruct"
  ok "Model: ${VLLM_MODEL}"
  echo ""

  # ── HuggingFace token ──────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  HuggingFace Token${NC}"
  hint "Required for gated models (Llama, Gemma, Mistral, etc.)."
  hint "Leave blank if the model is public."
  echo ""
  local hf_input=""
  echo -ne "  ${BOLD}HuggingFace token${NC} ${DIM}(Enter to skip)${NC}: "
  read -r -s hf_input
  echo ""
  VLLM_HF_TOKEN="${hf_input}"
  if [[ -n "$VLLM_HF_TOKEN" ]]; then
    ok "HuggingFace token: set (hidden)"
  else
    warn_msg "No HF token provided — will fail for gated models."
  fi
  echo ""

  # ── Engine parameters ──────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Engine Parameters${NC}"

  prompt_choice VLLM_DTYPE \
    "Tensor dtype" \
    "auto (recommended — picks optimal dtype per GPU)" \
    "float16 (FP16 — good for Ampere/Turing GPUs)" \
    "bfloat16 (BF16 — better for Hopper/Ada/Blackwell)" \
    "float32 (FP32 — high precision, slow)"
  case "$VLLM_DTYPE" in
    auto*)    VLLM_DTYPE="auto" ;;
    float16*) VLLM_DTYPE="float16" ;;
    bfloat16*)VLLM_DTYPE="bfloat16" ;;
    float32*) VLLM_DTYPE="float32" ;;
  esac
  ok "dtype: ${VLLM_DTYPE}"
  echo ""

  prompt_input VLLM_MAX_MODEL_LEN \
    "Max model context length (tokens)" "4096"
  ok "Max context length: ${VLLM_MAX_MODEL_LEN} tokens"
  echo ""

  while true; do
    prompt_input VLLM_GPU_COUNT "Number of GPUs per replica" "1"
    [[ "$VLLM_GPU_COUNT" =~ ^[1-9][0-9]*$ ]] \
      && ok "GPUs per replica: ${VLLM_GPU_COUNT}" && break
    err "Must be a positive integer."
  done
  echo ""

  # ── Resource limits ────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Resource Limits${NC}"
  hint "CPU and memory per vLLM replica pod."
  echo ""
  prompt_input VLLM_CPU_REQUEST  "CPU request (cores)"   "4"
  prompt_input VLLM_CPU_LIMIT    "CPU limit (cores)"     "8"
  prompt_input VLLM_MEM_REQUEST  "Memory request"        "16Gi"
  prompt_input VLLM_MEM_LIMIT    "Memory limit"          "32Gi"
  ok "Resources: CPU ${VLLM_CPU_REQUEST}-${VLLM_CPU_LIMIT} cores | Mem ${VLLM_MEM_REQUEST}-${VLLM_MEM_LIMIT}"
  echo ""

  # ── Extra vLLM args ────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Extra vLLM Arguments${NC}"
  hint "Additional vLLM engine flags passed verbatim (e.g. --enable-chunked-prefill"
  hint "  --max-num-seqs 256 --quantization awq). Leave blank for defaults."
  echo ""
  prompt_optional VLLM_EXTRA_ARGS "Extra vLLM args" ""
  if [[ -n "$VLLM_EXTRA_ARGS" ]]; then
    ok "Extra args: ${VLLM_EXTRA_ARGS}"
  else
    ok "No extra args."
  fi
  echo ""

  # ── Model cache storage ────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Model Cache Storage${NC}"
  hint "Models are cached on a PersistentVolume so they survive pod restarts."
  hint "The cluster's default StorageClass will be used (NFS if configured)."
  echo ""

  prompt_yes_no VLLM_REUSE_PVC "Reuse an existing PVC for model cache?" "n"
  echo ""

  if [[ "$VLLM_REUSE_PVC" == "true" ]]; then
    prompt_input VLLM_PVC_NAME "Existing PVC name" "vllm-model-cache"
    ok "Will reuse PVC: ${VLLM_PVC_NAME}"
    VLLM_STORAGE_SIZE=""   # size irrelevant when reusing
  else
    prompt_input VLLM_PVC_NAME "PVC name to create" "vllm-model-cache"
    prompt_input VLLM_STORAGE_SIZE "Storage size for model cache" "50Gi"
    ok "Will create PVC ${VLLM_PVC_NAME} (${VLLM_STORAGE_SIZE})"
  fi
  echo ""

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 9 — Kubernetes Namespaces
# ──────────────────────────────────────────────────────────────────────────────
collect_namespaces() {
  section_header "Kubernetes Namespaces" "9/10"
  hint "Customize namespace names, or press Enter to keep the defaults."
  echo ""

  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    while true; do
      prompt_input NS_GPU_OPERATOR "GPU Operator namespace" "gpu-operator"
      validate_namespace "$NS_GPU_OPERATOR" && ok "GPU Operator namespace: ${NS_GPU_OPERATOR}" && break
    done
  else
    NS_GPU_OPERATOR="gpu-operator"
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 8 — Feature Flags Summary & Confirm
# ──────────────────────────────────────────────────────────────────────────────
confirm_summary() {
  section_header "Configuration Summary — Review Before Continuing" "10/10"

  # Parse worker count
  local worker_count=0
  if [[ "$WORKER_IPS_STR" != "()" && -n "$WORKER_IPS_STR" ]]; then
    worker_count=$(echo "$WORKER_IPS_STR" | grep -o '"' | wc -l)
    worker_count=$((worker_count / 2))
  fi
  local worker_list=""
  if (( worker_count > 0 )); then
    worker_list=$(echo "$WORKER_IPS_STR" | tr -d '()"' | xargs)
  else
    worker_list="none (single-node)"
  fi

  # Feature on/off indicators
  nvidia_status="${RED}✖ Skip${NC}";  [[ "$INSTALL_NVIDIA" == "true" ]] && nvidia_status="${GREEN}✔ driver-${NVIDIA_DRIVER_VERSION}${NC}"
  local nvidia_detail=""
  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    [[ "$NVIDIA_OPEN_KERNEL" == "true" ]] && nvidia_detail=" open-kernel" || nvidia_detail=" proprietary"
    nvidia_detail+=" | fabric-mgr: ${NVIDIA_FABRIC_MANAGER} | reboot-timeout: ${NVIDIA_REBOOT_TIMEOUT}s"
  fi
  mon_status="${RED}✖ Skip${NC}";    [[ "$INSTALL_MONITORING" == "true" ]] && mon_status="${GREEN}✔ v${PROM_STACK_VERSION}${NC}"
  nfs_status="${RED}✖ Skip${NC}";    [[ "$INSTALL_NFS" == "true" ]] && nfs_status="${GREEN}✔ ${NFS_SERVER_IP}:${NFS_PATH}${NC}"
  dash_status="${RED}✖ Skip${NC}";   [[ "$INSTALL_DASHBOARD" == "true" ]] && dash_status="${GREEN}✔ v${DASHBOARD_VERSION}${NC}"
  vllm_status="${RED}✖ Skip${NC}";   [[ "$INSTALL_VLLM" == "true" ]] && vllm_status="${GREEN}✔ ${VLLM_NAMESPACE}${NC}"

  echo -e "  ${BOLD}${BLUE}── Nodes ─────────────────────────────────────────────────${NC}"
  echo -e "  Control plane  : ${CYAN}${CONTROL_PLANE_IP}${NC}"
  echo -e "  Workers        : ${CYAN}${worker_list}${NC}"
  echo -e "  SSH user       : ${CYAN}${SSH_USER}${NC}"
  echo -e "  SSH key        : ${CYAN}${SSH_KEY_PATH}${NC}"
  echo ""
  echo -e "  ${BOLD}${BLUE}── Kubernetes ────────────────────────────────────────────${NC}"
  echo -e "  Version        : ${CYAN}${K8S_VERSION}${NC}"
  echo -e "  CNI            : ${CYAN}${CNI_PLUGIN}${NC}"
  echo -e "  Pod CIDR       : ${CYAN}${POD_CIDR}${NC}"
  echo -e "  Helm           : ${CYAN}${HELM_VERSION}${NC}"
  echo ""
  echo -e "  ${BOLD}${BLUE}── Components ────────────────────────────────────────────${NC}"
  echo -e "  NVIDIA drivers : $(echo -e ${nvidia_status})${DIM}${nvidia_detail}${NC}"
  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    echo -e "  Monitoring     : $(echo -e ${mon_status})  (ns: ${NS_MONITORING})"
    echo -e "    Grafana      : ${CYAN}http://${CONTROL_PLANE_IP}:${GRAFANA_NODEPORT}${NC}"
    echo -e "    Prometheus   : ${CYAN}http://${CONTROL_PLANE_IP}:${PROMETHEUS_NODEPORT}${NC}"
    echo -e "    Alertmanager : ${CYAN}http://${CONTROL_PLANE_IP}:${ALERTMANAGER_NODEPORT}${NC}"
    echo -e "    Retention    : ${CYAN}${PROM_RETENTION}${NC}  |  Storage: ${CYAN}${PROM_STORAGE_SIZE}${NC}"
  else
    echo -e "  Monitoring     : $(echo -e ${mon_status})"
  fi
  if [[ "$INSTALL_NFS" == "true" ]]; then
    echo -e "  NFS            : $(echo -e ${nfs_status})"
    echo -e "    StorageClass : ${CYAN}${NFS_STORAGE_CLASS}${NC}  (default: ${NFS_DEFAULT_SC})"
  else
    echo -e "  NFS            : $(echo -e ${nfs_status})"
  fi
  [[ "$INSTALL_NVIDIA" == "true" ]] && \
    echo -e "  GPU Operator   : ${GREEN}✔${NC}  (ns: ${NS_GPU_OPERATOR})"
  echo -e "  Dashboard      : $(echo -e ${dash_status})"
  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    echo -e "    URL          : ${CYAN}https://${CONTROL_PLANE_IP}:${DASHBOARD_NODEPORT}${NC}"
  fi
  echo -e "  vLLM Stack     : $(echo -e ${vllm_status})"
  if [[ "$INSTALL_VLLM" == "true" ]]; then
    echo -e "    Router       : ${CYAN}http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1${NC}"
    echo -e "    Model        : ${CYAN}${VLLM_MODEL}${NC}"
    echo -e "    dtype        : ${CYAN}${VLLM_DTYPE}${NC}  |  ctx: ${CYAN}${VLLM_MAX_MODEL_LEN}${NC} tokens  |  GPUs: ${CYAN}${VLLM_GPU_COUNT}${NC}"
    if [[ -n "${VLLM_HF_TOKEN:-}" ]]; then
      echo -e "    HF Token     : ${GREEN}set (hidden)${NC}"
    else
      echo -e "    HF Token     : ${YELLOW}not set (public model only)${NC}"
    fi
    if [[ "${VLLM_REUSE_PVC:-false}" == "true" ]]; then
      echo -e "    Storage      : ${CYAN}reuse PVC ${VLLM_PVC_NAME}${NC}"
    else
      echo -e "    Storage      : ${CYAN}new PVC ${VLLM_PVC_NAME} (${VLLM_STORAGE_SIZE})${NC}"
    fi
    [[ -n "${VLLM_EXTRA_ARGS:-}" ]] && \
      echo -e "    Extra args   : ${DIM}${VLLM_EXTRA_ARGS}${NC}"
  fi

  echo ""
  echo -e "  ${DIM}Config will be saved to: ${CONFIG_FILE}${NC}"
  echo ""

  prompt_yes_no CONFIRMED "Proceed with this configuration?" "y"
  if [[ "$CONFIRMED" != "true" ]]; then
    echo ""
    warn_msg "Configuration cancelled. Run the wizard again to reconfigure."
    exit 0
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# WRITE CONFIG FILE
# ──────────────────────────────────────────────────────────────────────────────
write_config() {
  # Escape password for shell safety
  local safe_pw
  safe_pw=$(printf '%q' "$GRAFANA_ADMIN_PASSWORD")

  cat > "$CONFIG_FILE" <<CONFEOF
# =============================================================================
# k8s_cluster.conf — Generated by k8s_configure.sh on $(date)
# =============================================================================

# ── SSH ───────────────────────────────────────────────────────────────────────
SSH_USER="${SSH_USER}"
SSH_KEY_PATH="${SSH_KEY_PATH}"

# ── Nodes ─────────────────────────────────────────────────────────────────────
CONTROL_PLANE_IP="${CONTROL_PLANE_IP}"
WORKER_IPS=${WORKER_IPS_STR}

# ── Kubernetes ────────────────────────────────────────────────────────────────
K8S_VERSION="${K8S_VERSION}"
POD_CIDR="${POD_CIDR}"
CNI_PLUGIN="${CNI_PLUGIN}"
HELM_VERSION="${HELM_VERSION}"

# ── NVIDIA ────────────────────────────────────────────────────────────────────
INSTALL_NVIDIA="${INSTALL_NVIDIA}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION}"
NVIDIA_OPEN_KERNEL="${NVIDIA_OPEN_KERNEL}"
NVIDIA_FABRIC_MANAGER="${NVIDIA_FABRIC_MANAGER}"
NVIDIA_REBOOT_TIMEOUT="${NVIDIA_REBOOT_TIMEOUT}"

# ── Monitoring ────────────────────────────────────────────────────────────────
INSTALL_MONITORING="${INSTALL_MONITORING}"
PROM_STACK_VERSION="${PROM_STACK_VERSION}"
NS_MONITORING="${NS_MONITORING}"
GRAFANA_ADMIN_PASSWORD=${safe_pw}
GRAFANA_NODEPORT="${GRAFANA_NODEPORT}"
PROMETHEUS_NODEPORT="${PROMETHEUS_NODEPORT}"
ALERTMANAGER_NODEPORT="${ALERTMANAGER_NODEPORT}"
PROM_RETENTION="${PROM_RETENTION}"
PROM_STORAGE_SIZE="${PROM_STORAGE_SIZE}"

# ── NFS ───────────────────────────────────────────────────────────────────────
INSTALL_NFS="${INSTALL_NFS}"
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_PATH="${NFS_PATH}"
NS_NFS="${NS_NFS}"
NFS_STORAGE_CLASS="${NFS_STORAGE_CLASS}"
NFS_DEFAULT_SC="${NFS_DEFAULT_SC}"

# ── GPU Operator ──────────────────────────────────────────────────────────────
NS_GPU_OPERATOR="${NS_GPU_OPERATOR}"

# ── Kubernetes Dashboard ──────────────────────────────────────────────────────
INSTALL_DASHBOARD="${INSTALL_DASHBOARD}"
DASHBOARD_VERSION="${DASHBOARD_VERSION}"
DASHBOARD_NODEPORT="${DASHBOARD_NODEPORT}"
NS_DASHBOARD="${NS_DASHBOARD}"

# ── vLLM Production Stack ─────────────────────────────────────────────────────
INSTALL_VLLM="${INSTALL_VLLM}"
VLLM_NAMESPACE="${VLLM_NAMESPACE}"
VLLM_NODEPORT="${VLLM_NODEPORT}"
VLLM_MODEL="${VLLM_MODEL}"
VLLM_HF_TOKEN="$(printf '%s' "${VLLM_HF_TOKEN}" | sed "s/'/'\\\\''/g")"
VLLM_DTYPE="${VLLM_DTYPE}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN}"
VLLM_GPU_COUNT="${VLLM_GPU_COUNT}"
VLLM_CPU_REQUEST="${VLLM_CPU_REQUEST}"
VLLM_CPU_LIMIT="${VLLM_CPU_LIMIT}"
VLLM_MEM_REQUEST="${VLLM_MEM_REQUEST}"
VLLM_MEM_LIMIT="${VLLM_MEM_LIMIT}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS}"
VLLM_STORAGE_SIZE="${VLLM_STORAGE_SIZE}"
VLLM_REUSE_PVC="${VLLM_REUSE_PVC}"
VLLM_PVC_NAME="${VLLM_PVC_NAME}"
CONFEOF

  chmod 600 "$CONFIG_FILE"
  ok "Configuration saved to ${CONFIG_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# PATCH INSTALLER WITH CONFIG VALUES
# ──────────────────────────────────────────────────────────────────────────────
patch_installer() {
  if [[ ! -f "$INSTALLER" ]]; then
    warn_msg "Installer not found at ${INSTALLER} — config written but installer not patched."
    return
  fi

  # Read worker IPs for sed (strip parens/quotes, comma-join)
  local worker_arr_str="$WORKER_IPS_STR"

  # Use a temp file to patch the CONFIGURATION block
  local tmp
  tmp=$(mktemp)

  # Replace the static config block between the two marker comments
  awk -v cp="$CONTROL_PLANE_IP" \
      -v wu="$SSH_USER" \
      -v wk="$SSH_KEY_PATH" \
      -v kv="$K8S_VERSION" \
      -v pc="$POD_CIDR" \
      -v cni="$CNI_PLUGIN" \
      -v nfs_ip="$NFS_SERVER_IP" \
      -v nfs_path="$NFS_PATH" \
      -v nv="$NVIDIA_DRIVER_VERSION" \
      -v nv_open="$NVIDIA_OPEN_KERNEL" \
      -v nv_fm="$NVIDIA_FABRIC_MANAGER" \
      -v nv_rt="$NVIDIA_REBOOT_TIMEOUT" \
      -v hv="$HELM_VERSION" \
      -v ns_mon="$NS_MONITORING" \
      -v ns_gpu="$NS_GPU_OPERATOR" \
      -v ns_nfs="$NS_NFS" \
      -v prom_ver="$PROM_STACK_VERSION" \
      -v gpass="$GRAFANA_ADMIN_PASSWORD" \
      -v inst_dash="$INSTALL_DASHBOARD" \
      -v dash_ver="$DASHBOARD_VERSION" \
      -v dash_port="$DASHBOARD_NODEPORT" \
      -v ns_dash="$NS_DASHBOARD" \
      -v inst_vllm="$INSTALL_VLLM" \
      -v vllm_ns="$VLLM_NAMESPACE" \
      -v vllm_port="$VLLM_NODEPORT" \
      -v vllm_model="$VLLM_MODEL" \
      -v vllm_hft="$VLLM_HF_TOKEN" \
      -v vllm_dtype="$VLLM_DTYPE" \
      -v vllm_maxlen="$VLLM_MAX_MODEL_LEN" \
      -v vllm_gpus="$VLLM_GPU_COUNT" \
      -v vllm_cpureq="$VLLM_CPU_REQUEST" \
      -v vllm_cpulim="$VLLM_CPU_LIMIT" \
      -v vllm_memreq="$VLLM_MEM_REQUEST" \
      -v vllm_memlim="$VLLM_MEM_LIMIT" \
      -v vllm_extra="$VLLM_EXTRA_ARGS" \
      -v vllm_stosize="$VLLM_STORAGE_SIZE" \
      -v vllm_reuse="$VLLM_REUSE_PVC" \
      -v vllm_pvc="$VLLM_PVC_NAME" \
      -v workers="$worker_arr_str" \
  'BEGIN { in_conf=0 }
   /^# CONFIGURATION — Edit these values/ { in_conf=1 }
   in_conf && /^CONTROL_PLANE_IP=/  { print "CONTROL_PLANE_IP=\"" cp "\""; next }
   in_conf && /^WORKER_IPS=/        { print "WORKER_IPS=" workers;         next }
   in_conf && /^SSH_USER=/          { print "SSH_USER=\"" wu "\"";          next }
   in_conf && /^SSH_KEY_PATH=/      { print "SSH_KEY_PATH=\"" wk "\"";      next }
   in_conf && /^K8S_VERSION=/       { print "K8S_VERSION=\"" kv "\"";       next }
   in_conf && /^POD_CIDR=/          { print "POD_CIDR=\"" pc "\"";          next }
   in_conf && /^CNI_PLUGIN=/        { print "CNI_PLUGIN=\"" cni "\"";       next }
   in_conf && /^NFS_SERVER_IP=/     { print "NFS_SERVER_IP=\"" nfs_ip "\""; next }
   in_conf && /^NFS_PATH=/          { print "NFS_PATH=\"" nfs_path "\"";    next }
   in_conf && /^NVIDIA_DRIVER_VERSION=/ { print "NVIDIA_DRIVER_VERSION=\"" nv "\""; next }
   in_conf && /^NVIDIA_OPEN_KERNEL=/   { print "NVIDIA_OPEN_KERNEL=\"" nv_open "\""; next }
   in_conf && /^NVIDIA_FABRIC_MANAGER=/ { print "NVIDIA_FABRIC_MANAGER=\"" nv_fm "\""; next }
   in_conf && /^NVIDIA_REBOOT_TIMEOUT=/ { print "NVIDIA_REBOOT_TIMEOUT=\"" nv_rt "\""; next }
   in_conf && /^HELM_VERSION=/      { print "HELM_VERSION=\"" hv "\"";      next }
   in_conf && /^NS_MONITORING=/     { print "NS_MONITORING=\"" ns_mon "\""; next }
   in_conf && /^NS_GPU_OPERATOR=/   { print "NS_GPU_OPERATOR=\"" ns_gpu "\""; next }
   in_conf && /^NS_NFS=/            { print "NS_NFS=\"" ns_nfs "\"";        next }
   in_conf && /^PROM_STACK_VERSION=/ { print "PROM_STACK_VERSION=\"" prom_ver "\""; next }
   in_conf && /^GRAFANA_ADMIN_PASSWORD=/ { print "GRAFANA_ADMIN_PASSWORD=\"" gpass "\""; next }
   in_conf && /^INSTALL_DASHBOARD=/ { print "INSTALL_DASHBOARD=\"" inst_dash "\""; next }
   in_conf && /^DASHBOARD_VERSION=/ { print "DASHBOARD_VERSION=\"" dash_ver "\""; next }
   in_conf && /^DASHBOARD_NODEPORT=/ { print "DASHBOARD_NODEPORT=\"" dash_port "\""; next }
   in_conf && /^NS_DASHBOARD=/      { print "NS_DASHBOARD=\"" ns_dash "\""; next }
   in_conf && /^INSTALL_VLLM=/      { print "INSTALL_VLLM=\"" inst_vllm "\""; next }
   in_conf && /^VLLM_NAMESPACE=/    { print "VLLM_NAMESPACE=\"" vllm_ns "\""; next }
   in_conf && /^VLLM_NODEPORT=/     { print "VLLM_NODEPORT=\"" vllm_port "\""; next }
   in_conf && /^VLLM_MODEL=/        { print "VLLM_MODEL=\"" vllm_model "\""; next }
   in_conf && /^VLLM_HF_TOKEN=/     { print "VLLM_HF_TOKEN=\"" vllm_hft "\""; next }
   in_conf && /^VLLM_DTYPE=/        { print "VLLM_DTYPE=\"" vllm_dtype "\""; next }
   in_conf && /^VLLM_MAX_MODEL_LEN=/ { print "VLLM_MAX_MODEL_LEN=\"" vllm_maxlen "\""; next }
   in_conf && /^VLLM_GPU_COUNT=/    { print "VLLM_GPU_COUNT=\"" vllm_gpus "\""; next }
   in_conf && /^VLLM_CPU_REQUEST=/  { print "VLLM_CPU_REQUEST=\"" vllm_cpureq "\""; next }
   in_conf && /^VLLM_CPU_LIMIT=/    { print "VLLM_CPU_LIMIT=\"" vllm_cpulim "\""; next }
   in_conf && /^VLLM_MEM_REQUEST=/  { print "VLLM_MEM_REQUEST=\"" vllm_memreq "\""; next }
   in_conf && /^VLLM_MEM_LIMIT=/    { print "VLLM_MEM_LIMIT=\"" vllm_memlim "\""; next }
   in_conf && /^VLLM_EXTRA_ARGS=/   { print "VLLM_EXTRA_ARGS=\"" vllm_extra "\""; next }
   in_conf && /^VLLM_STORAGE_SIZE=/ { print "VLLM_STORAGE_SIZE=\"" vllm_stosize "\""; next }
   in_conf && /^VLLM_REUSE_PVC=/    { print "VLLM_REUSE_PVC=\"" vllm_reuse "\""; next }
   in_conf && /^VLLM_PVC_NAME=/     { print "VLLM_PVC_NAME=\"" vllm_pvc "\""; next }
   /^# ─.*SANITY CHECKS/ { in_conf=0 }
   { print }' "$INSTALLER" > "$tmp"

  chmod 700 "$tmp"
  mv "$tmp" "$INSTALLER"
  ok "Installer patched with your configuration."
}

# ──────────────────────────────────────────────────────────────────────────────
# OPTIONAL: LAUNCH INSTALLER
# ──────────────────────────────────────────────────────────────────────────────
offer_launch() {
  echo ""
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "  ${BOLD}  Configuration complete!${NC}"
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  To run the installer manually:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER}${NC}"
  echo ""
  echo -e "  Or run a single step:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER} --step <step-name>${NC}"
  echo ""

  if [[ ! -f "$INSTALLER" ]]; then
    warn_msg "Installer script not found — cannot launch automatically."
    return
  fi

  prompt_yes_no LAUNCH_NOW "Launch the installer now?" "n"
  if [[ "$LAUNCH_NOW" == "true" ]]; then
    if [[ $EUID -ne 0 ]]; then
      echo ""
      warn_msg "Re-launching with sudo..."
      exec sudo bash "$INSTALLER"
    else
      exec bash "$INSTALLER"
    fi
  else
    echo ""
    ok "Configuration saved. Run the installer when ready:"
    echo -e "    ${CYAN}sudo bash ${INSTALLER}${NC}"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# RECONFIGURE PROMPT (if config already exists)
# ──────────────────────────────────────────────────────────────────────────────
check_existing_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    print_header
    echo -e "  ${YELLOW}${SYM_WARN}  An existing configuration was found:${NC}"
    echo -e "  ${DIM}${CONFIG_FILE}${NC}"
    echo ""
    # Show key values from existing config
    source "$CONFIG_FILE" 2>/dev/null || true
    echo -e "  ${DIM}Control plane : ${CONTROL_PLANE_IP:-<not set>}${NC}"
    echo -e "  ${DIM}SSH user      : ${SSH_USER:-<not set>}${NC}"
    echo -e "  ${DIM}K8s version   : ${K8S_VERSION:-<not set>}${NC}"
    echo ""
    prompt_yes_no RECONFIGURE "Reconfigure (overwrite existing config)?" "y"
    if [[ "$RECONFIGURE" != "true" ]]; then
      echo ""
      ok "Keeping existing configuration at ${CONFIG_FILE}."
      offer_launch
      exit 0
    fi
    echo ""
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
  print_header
  check_existing_config

  print_header
  echo -e "  ${DIM}This wizard collects all parameters needed to install your"
  echo -e "  Kubernetes cluster and saves them to ${CONFIG_FILE}.${NC}"
  echo -e "  ${DIM}You can abort at any time with Ctrl+C.${NC}"
  echo ""

  collect_ssh
  collect_nodes
  collect_k8s
  collect_nvidia
  collect_monitoring
  collect_nfs
  collect_dashboard
  collect_vllm
  collect_namespaces
  confirm_summary

  write_config
  patch_installer
  offer_launch
}

# ──────────────────────────────────────────────────────────────────────────────
# CTRL+C handler
# ──────────────────────────────────────────────────────────────────────────────
trap 'echo -e "\n\n  ${YELLOW}${SYM_WARN}  Wizard interrupted — no changes saved.${NC}\n"; exit 130' INT

main "$@"
