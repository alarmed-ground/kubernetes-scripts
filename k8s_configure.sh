#!/usr/bin/env bash
# =============================================================================
# k8s_configure.sh — Interactive Configuration Wizard  v2
#
# Improvements over v1:
#   • --section <name>  re-run a single section without the full wizard
#   • --preflight       run pre-flight checks only (SSH, ping, disk, ports)
#   • --show            print the current config file and exit
#   • Config file versioning (CONF_VERSION=2) with forward-migration
#   • Pre-flight checks embedded before saving (ping nodes, test SSH port,
#     check disk space, verify NFS reachability, detect NodePort conflicts)
#   • Inline editing — after the summary you can jump back to any section
#     instead of being forced to restart the entire wizard
#   • NodePort conflict detection across all configured services
#   • SSH connectivity test with actionable error messages
#   • Disk space check on local machine before saving
#   • NFS export reachability test (showmount / nc fallback)
#   • GPU count auto-suggestion based on worker count
#   • Model size vs memory guard for vLLM
#   • Section names printed in the offer_launch reference table
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/k8s_cluster.conf"
INSTALLER="${SCRIPT_DIR}/k8s_cluster_setup.sh"
CONF_VERSION=2

# ──────────────────────────────────────────────────────────────────────────────
# COLORS & UI PRIMITIVES
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';      DIM='\033[2m';      NC='\033[0m'

SYM_OK="✔";  SYM_ERR="✖";  SYM_WARN="⚠";  SYM_ARROW="▶";  SYM_DOT="•"

print_header() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║       Kubernetes Cluster Installer — Configuration Wizard    ║"
  echo "  ║                      Ubuntu 24.04                            ║"
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
info_msg(){ echo -e "  ${BLUE}${SYM_DOT} $*${NC}"; }

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
prompt_input() {
  local var_name="$1" question="$2" default="${3:-}" secret="${4:-}" input=""
  while true; do
    if [[ -n "$default" ]]; then
      echo -ne "  ${BOLD}${question}${NC} ${DIM}[${default}]${NC}: "
    else
      echo -ne "  ${BOLD}${question}${NC}: "
    fi
    if [[ "$secret" == "secret" ]]; then read -r -s input; echo ""; else read -r input; fi
    input="${input:-$default}"
    if [[ -z "$input" ]]; then err "This field is required."; else eval "${var_name}='${input}'"; return 0; fi
  done
}

prompt_optional() {
  local var_name="$1" question="$2" default="${3:-}" input=""
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${question}${NC} ${DIM}[${default}]${NC} ${DIM}(optional, Enter to skip)${NC}: "
  else
    echo -ne "  ${BOLD}${question}${NC} ${DIM}(optional, Enter to skip)${NC}: "
  fi
  read -r input
  eval "${var_name}='${input:-$default}'"
}

prompt_choice() {
  local var_name="$1" question="$2"; shift 2
  local options=("$@") choice="" valid=false
  echo -e "  ${BOLD}${question}${NC}"
  for i in "${!options[@]}"; do echo -e "    ${CYAN}$((i+1))${NC}) ${options[$i]}"; done
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

prompt_yes_no() {
  local var_name="$1" question="$2" default="${3:-n}" input="" display="y/N"
  [[ "$default" == "y" ]] && display="Y/n"
  while true; do
    echo -ne "  ${BOLD}${question}${NC} ${DIM}[${display}]${NC}: "
    read -r input
    input="${input:-$default}"; input="${input,,}"
    case "$input" in
      y|yes) eval "${var_name}=true";  return ;;
      n|no)  eval "${var_name}=false"; return ;;
      *)     err "Please enter y or n." ;;
    esac
  done
}

prompt_ip() {
  local var_name="$1" question="$2" default="${3:-}" input=""
  while true; do
    prompt_input "$var_name" "$question" "$default"
    eval "input=\${${var_name}}"
    if validate_ip "$input"; then return 0; else err "'${input}' is not a valid IPv4 address."; fi
  done
}

prompt_ip_optional() {
  local var_name="$1" question="$2" default="${3:-}" input=""
  while true; do
    prompt_optional "$var_name" "$question" "$default"
    eval "input=\${${var_name}}"
    if [[ -z "$input" ]]; then return 0
    elif validate_ip "$input"; then return 0
    else err "'${input}' is not a valid IPv4 address."; fi
  done
}

prompt_ip_list() {
  local var_name="$1" question="$2"
  local ips=() ip="" more=true index=1
  echo -e "  ${BOLD}${question}${NC}"
  hint "Enter one IP per line. Press Enter on a blank line when done."
  echo ""
  while $more; do
    while true; do
      echo -ne "  ${BOLD}Worker ${index} IP${NC} ${DIM}(blank to finish)${NC}: "
      read -r ip
      if [[ -z "$ip" ]]; then more=false; break
      elif validate_ip "$ip"; then ips+=("$ip"); ok "Added worker: ${ip}"; index=$((index+1)); break
      else err "'${ip}' is not a valid IPv4 address."; fi
    done
  done
  local arr_str="("
  for i in "${ips[@]:-}"; do [[ -n "$i" ]] && arr_str+="\"$i\" "; done
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
  for octet in "${octets[@]}"; do (( octet <= 255 )) || return 1; done
  return 0
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  validate_ip "${cidr%/*}" || return 1
  (( ${cidr#*/} <= 32 )) || return 1
  return 0
}

validate_semver()   { [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; }
validate_abs_path() { [[ "$1" == /* ]] || { err "Path must be absolute (start with /)."; return 1; }; return 0; }
validate_k8s_version() { [[ "$1" =~ ^1\.[2-9][0-9]$ ]] || { err "K8s version must be in format 1.XX (e.g. 1.31)."; return 1; }; return 0; }
validate_helm_version() { validate_semver "$1" || { err "Helm version must be semver (e.g. 3.16.2)."; return 1; }; return 0; }
validate_namespace() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
    err "Namespace must be lowercase alphanumeric with hyphens, no leading/trailing hyphens."
    return 1
  }; return 0
}
validate_password_strength() {
  local pw="$1"
  [[ ${#pw} -ge 12 ]]          || { err "Password must be at least 12 characters.";             return 1; }
  [[ "$pw" =~ [A-Z] ]]         || { err "Password must contain at least one uppercase letter."; return 1; }
  [[ "$pw" =~ [a-z] ]]         || { err "Password must contain at least one lowercase letter."; return 1; }
  [[ "$pw" =~ [0-9] ]]         || { err "Password must contain at least one digit.";            return 1; }
  [[ "$pw" =~ [^a-zA-Z0-9] ]] || { err "Password must contain at least one special character."; return 1; }
  return 0
}

validate_nodeport() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 30000 && $1 <= 32767 )) || {
    err "NodePort must be between 30000 and 32767."
    return 1
  }; return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ──────────────────────────────────────────────────────────────────────────────
run_preflight() {
  local mode="${1:-full}"   # full | ssh-only | nfs-only | nodeport-only
  local all_pass=true

  section_header "Pre-flight Checks" "✈"

  # ── 1. Collect all nodes ───────────────────────────────────────────────────
  local all_nodes=("$CONTROL_PLANE_IP")
  if [[ "$WORKER_IPS_STR" != "()" && -n "${WORKER_IPS_STR:-}" ]]; then
    while IFS= read -r -d '"' part; do
      [[ "$part" =~ ^[0-9] ]] && all_nodes+=("$part")
    done <<< "$WORKER_IPS_STR"
  fi

  # ── 2. Ping reachability ──────────────────────────────────────────────────
  info_msg "Checking node reachability (ping)..."
  for node in "${all_nodes[@]}"; do
    if ping -c1 -W2 "$node" &>/dev/null 2>&1; then
      ok "  ${node} — reachable"
    else
      err "  ${node} — NOT reachable (ping failed)"
      warn_msg "  → Check that the node is powered on and the IP is correct."
      all_pass=false
    fi
  done
  echo ""

  # ── 3. SSH port open ─────────────────────────────────────────────────────
  info_msg "Checking SSH port 22..."
  for node in "${all_nodes[@]}"; do
    if command -v nc &>/dev/null; then
      if nc -z -w3 "$node" 22 &>/dev/null 2>&1; then
        ok "  ${node}:22 — open"
      else
        err "  ${node}:22 — port closed or filtered"
        warn_msg "  → Ensure sshd is running: sudo systemctl start ssh"
        all_pass=false
      fi
    else
      # fallback: bash /dev/tcp
      if (echo >/dev/tcp/"$node"/22) &>/dev/null 2>&1; then
        ok "  ${node}:22 — open"
      else
        warn_msg "  ${node}:22 — could not check (nc not available)"
      fi
    fi
  done
  echo ""

  # ── 4. SSH key authentication ─────────────────────────────────────────────
  if [[ -f "$SSH_KEY_PATH" ]]; then
    info_msg "Testing SSH key authentication..."
    for node in "${all_nodes[@]}"; do
      if ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o BatchMode=yes \
             -o ConnectTimeout=5 \
             "${SSH_USER}@${node}" "echo ok" &>/dev/null 2>&1; then
        ok "  ${SSH_USER}@${node} — SSH key auth works"
      else
        warn_msg "  ${SSH_USER}@${node} — SSH key auth not yet available"
        hint "    This is OK before first install — the wizard will copy the key."
      fi
    done
  else
    info_msg "SSH key ${SSH_KEY_PATH} not yet generated — will be created during install."
  fi
  echo ""

  # ── 5. Local disk space ──────────────────────────────────────────────────
  info_msg "Checking local disk space..."
  local free_mb
  free_mb=$(df -m "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -n "$free_mb" ]]; then
    if (( free_mb >= 500 )); then
      ok "  Local free space: ${free_mb} MB — sufficient"
    else
      warn_msg "  Local free space: ${free_mb} MB — low (recommend >= 500 MB)"
    fi
  fi
  echo ""

  # ── 6. NFS reachability ──────────────────────────────────────────────────
  if [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_SERVER_IP:-}" ]]; then
    info_msg "Checking NFS server reachability (${NFS_SERVER_IP})..."
    # Try showmount first, then nc fallback for port 2049
    if command -v showmount &>/dev/null; then
      local exports
      exports=$(showmount -e "$NFS_SERVER_IP" 2>&1)
      if echo "$exports" | grep -q "${NFS_PATH:-}"; then
        ok "  NFS export ${NFS_PATH} found on ${NFS_SERVER_IP}"
      elif echo "$exports" | grep -qE "Export list|/"; then
        warn_msg "  NFS server responds but ${NFS_PATH} not in export list"
        warn_msg "  → Exports found: $(echo "$exports" | grep '/' | head -3)"
      else
        err "  Cannot reach NFS server ${NFS_SERVER_IP} via showmount"
        warn_msg "  → Check that nfs-kernel-server is running and ports 2049/111 are open"
        all_pass=false
      fi
    elif command -v nc &>/dev/null; then
      if nc -z -w3 "$NFS_SERVER_IP" 2049 &>/dev/null 2>&1; then
        ok "  NFS port 2049 open on ${NFS_SERVER_IP}"
      else
        err "  NFS port 2049 closed on ${NFS_SERVER_IP}"
        all_pass=false
      fi
    else
      warn_msg "  Cannot check NFS (no showmount or nc available) — skipping"
    fi
    echo ""
  fi

  # ── 7. NodePort conflict detection ───────────────────────────────────────
  info_msg "Checking for NodePort conflicts..."
  declare -A port_map
  local conflicts=false
  _register_port() {
    local port="$1" name="$2"
    [[ -z "$port" ]] && return
    if [[ -n "${port_map[$port]:-}" ]]; then
      err "  NodePort ${port} is used by both '${port_map[$port]}' and '${name}'"
      conflicts=true; all_pass=false
    else
      port_map[$port]="$name"
      ok "  Port ${port} → ${name}"
    fi
  }
  [[ "${INSTALL_MONITORING:-false}" == "true" ]] && {
    _register_port "${GRAFANA_NODEPORT:-32000}"      "Grafana"
    _register_port "${PROMETHEUS_NODEPORT:-32001}"   "Prometheus"
    _register_port "${ALERTMANAGER_NODEPORT:-32002}"  "Alertmanager"
  }
  [[ "${INSTALL_DASHBOARD:-false}" == "true" ]] && \
    _register_port "${DASHBOARD_NODEPORT:-32443}"    "Dashboard"
  [[ "${INSTALL_VLLM:-false}" == "true" ]] && \
    _register_port "${VLLM_NODEPORT:-32080}"         "vLLM Router"
  $conflicts || ok "  No NodePort conflicts detected"
  echo ""

  # ── Result ────────────────────────────────────────────────────────────────
  if $all_pass; then
    ok "All pre-flight checks passed."
  else
    warn_msg "Some pre-flight checks failed — review the warnings above."
    if [[ "$mode" == "full" ]]; then
      echo ""
      prompt_yes_no _PF_CONTINUE "Continue anyway?" "y"
      [[ "${_PF_CONTINUE}" != "true" ]] && { echo ""; warn_msg "Aborted."; exit 1; }
    fi
  fi
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 1 — SSH & Node Access
# ──────────────────────────────────────────────────────────────────────────────
collect_ssh() {
  section_header "SSH & Node Access" "1/10"
  hint "These credentials are used to connect to all cluster nodes."
  echo ""

  prompt_input SSH_USER "Remote username" "ubuntu"
  ok "SSH user: ${SSH_USER}"

  prompt_input SSH_KEY_PATH \
    "SSH private key path (will be generated if missing)" \
    "${HOME}/.ssh/k8s_cluster_rsa"
  ok "Key path: ${SSH_KEY_PATH}"

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Cluster Nodes
# ──────────────────────────────────────────────────────────────────────────────
collect_nodes() {
  section_header "Cluster Node IPs" "2/10"
  hint "Enter IP addresses for your control plane and worker nodes."
  hint "All nodes must be running Ubuntu 24.04 and reachable via SSH."
  echo ""

  prompt_ip CONTROL_PLANE_IP "Control plane IP" ""
  ok "Control plane: ${CONTROL_PLANE_IP}"
  echo ""

  prompt_ip_list WORKER_IPS_STR "Worker node IPs"
  echo ""

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
  WORKER_COUNT=$count

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Kubernetes Settings
# ──────────────────────────────────────────────────────────────────────────────
collect_k8s() {
  section_header "Kubernetes Settings" "3/10"
  echo ""

  while true; do
    prompt_input K8S_VERSION "Kubernetes version (minor)" "1.31"
    validate_k8s_version "$K8S_VERSION" && ok "K8s version: ${K8S_VERSION}" && break
  done
  echo ""

  prompt_choice CNI_PLUGIN "Container Network Interface (CNI) plugin" \
    "flannel (recommended — VXLAN, works on VMs and bare metal)" \
    "calico (advanced — NetworkPolicy support, VXLAN mode)"
  CNI_PLUGIN="${CNI_PLUGIN%% *}"
  ok "CNI: ${CNI_PLUGIN}"
  echo ""

  local default_cidr="10.244.0.0/16"
  [[ "$CNI_PLUGIN" == "calico" ]] && default_cidr="192.168.0.0/16"
  hint "Default CIDR auto-selected for ${CNI_PLUGIN}: ${default_cidr}"

  while true; do
    prompt_input POD_CIDR "Pod network CIDR" "$default_cidr"
    validate_cidr "$POD_CIDR" && ok "Pod CIDR: ${POD_CIDR}" && break
    err "'${POD_CIDR}' is not a valid CIDR."
  done
  echo ""

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
  section_header "NVIDIA Drivers" "4/10"
  hint "The installer auto-detects GPUs via lspci and skips non-GPU nodes."
  echo ""

  prompt_yes_no INSTALL_NVIDIA "Install NVIDIA drivers and GPU Operator?" "y"
  echo ""

  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
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
    NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION%% *}"
    ok "NVIDIA driver branch: ${NVIDIA_DRIVER_VERSION}"
    echo ""

    echo -e "  ${BOLD}${BLUE}  Open Kernel Modules:${NC}"
    echo -e "  ${DIM}  Recommended for Turing (RTX 20xx) and newer GPUs.${NC}"
    echo -e "  ${DIM}  REQUIRED for Blackwell (B-series).${NC}"
    echo ""
    local default_open="n"
    if [[ "$NVIDIA_DRIVER_VERSION" =~ ^(590|580|570)$ ]]; then
      default_open="y"
      hint "Branch ${NVIDIA_DRIVER_VERSION} targets Blackwell/RTX 50xx — open kernel modules are strongly recommended."
    fi
    prompt_yes_no NVIDIA_OPEN_KERNEL \
      "Use open kernel modules (nvidia-driver-${NVIDIA_DRIVER_VERSION}-open)?" "$default_open"
    if [[ "$NVIDIA_OPEN_KERNEL" == "true" ]]; then
      ok "Open kernel modules: enabled"
    else
      ok "Open kernel modules: disabled (proprietary)"
    fi
    echo ""

    echo -e "  ${BOLD}${BLUE}  Fabric Manager:${NC}"
    echo -e "  ${DIM}  Required for NVLink/NVSwitch multi-GPU systems (A100 SXM4, H100 SXM5, DGX, HGX).${NC}"
    echo -e "  ${DIM}  Not needed for single PCIe GPU nodes.${NC}"
    echo ""
    prompt_choice NVIDIA_FABRIC_MANAGER \
      "Fabric Manager installation" \
      "auto (detect NVSwitch/SXM at install time — recommended)" \
      "yes (always install)" \
      "no (never install)"
    case "$NVIDIA_FABRIC_MANAGER" in
      auto*) NVIDIA_FABRIC_MANAGER="auto" ;;
      yes*)  NVIDIA_FABRIC_MANAGER="true" ;;
      no*)   NVIDIA_FABRIC_MANAGER="false" ;;
    esac
    ok "Fabric Manager: ${NVIDIA_FABRIC_MANAGER}"
    echo ""

    # ── GPU Time-Slicing ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  GPU Time-Slicing:${NC}"
    echo -e "  ${DIM}  Expose multiple virtual GPUs per physical GPU.${NC}"
    echo -e "  ${DIM}  Useful for sharing one GPU across multiple inference pods.${NC}"
    echo -e "  ${DIM}  No memory isolation — all slices share VRAM. Works on any GPU.${NC}"
    echo ""
    prompt_yes_no GPU_TIMESLICING_ENABLED "Enable GPU time-slicing?" "n"
    if [[ "$GPU_TIMESLICING_ENABLED" == "true" ]]; then
      while true; do
        prompt_input GPU_TIMESLICE_COUNT "Virtual GPUs per physical GPU" "4"
        [[ "$GPU_TIMESLICE_COUNT" =~ ^[2-9]$|^[1-9][0-9]+$ ]]           && ok "Time-slicing: ${GPU_TIMESLICE_COUNT}x virtual GPUs per physical GPU"           && break
        err "Must be an integer >= 2."
      done
    else
      GPU_TIMESLICE_COUNT="4"
      ok "GPU time-slicing: disabled"
    fi
    echo ""

    echo -e "  ${BOLD}${BLUE}  Reboot Timeout:${NC}"
    echo -e "  ${DIM}  After the driver installs, each node reboots. This is the max seconds${NC}"
    echo -e "  ${DIM}  to wait per node for SSH to return. Slow hardware may need 600s.${NC}"
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
    GPU_TIMESLICING_ENABLED="false"
    GPU_TIMESLICE_COUNT="4"
    warn_msg "Skipping NVIDIA. GPU Operator will also be skipped."
  fi

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Monitoring (Prometheus + Grafana)
# ──────────────────────────────────────────────────────────────────────────────
collect_monitoring() {
  section_header "Monitoring Stack — Prometheus & Grafana" "5/10"
  hint "Deploys kube-prometheus-stack via Helm."
  echo ""

  prompt_yes_no INSTALL_MONITORING "Install Prometheus + Grafana?" "y"
  echo ""

  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    prompt_input PROM_STACK_VERSION "kube-prometheus-stack chart version" "65.1.0"
    ok "Chart version: ${PROM_STACK_VERSION}"
    echo ""

    while true; do
      prompt_input NS_MONITORING "Monitoring namespace" "monitoring"
      validate_namespace "$NS_MONITORING" && ok "Namespace: ${NS_MONITORING}" && break
    done
    echo ""

    hint "NodePort services will be exposed on the control plane IP."
    hint "NodePorts must be in the range 30000–32767 and must be unique."
    echo ""
    while true; do
      prompt_input GRAFANA_NODEPORT "Grafana NodePort" "32000"
      validate_nodeport "$GRAFANA_NODEPORT" && ok "Grafana: :${GRAFANA_NODEPORT}" && break
    done
    while true; do
      prompt_input PROMETHEUS_NODEPORT "Prometheus NodePort" "32001"
      validate_nodeport "$PROMETHEUS_NODEPORT" && ok "Prometheus: :${PROMETHEUS_NODEPORT}" && break
    done
    while true; do
      prompt_input ALERTMANAGER_NODEPORT "Alertmanager NodePort" "32002"
      validate_nodeport "$ALERTMANAGER_NODEPORT" && ok "Alertmanager: :${ALERTMANAGER_NODEPORT}" && break
    done
    echo ""

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

    prompt_input PROM_RETENTION "Prometheus data retention" "30d"
    ok "Retention: ${PROM_RETENTION}"
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
  section_header "NFS Storage Provisioner" "6/10"
  hint "Sets up dynamic PVC provisioning via an NFS server."
  echo ""

  prompt_yes_no INSTALL_NFS "Install NFS external provisioner?" "y"
  echo ""

  if [[ "$INSTALL_NFS" == "true" ]]; then
    prompt_ip_optional NFS_SERVER_IP "NFS server IP" "${CONTROL_PLANE_IP:-}"
    ok "NFS server: ${NFS_SERVER_IP:-<none>}"
    echo ""

    while true; do
      prompt_input NFS_PATH "NFS export path on server" "/srv/nfs/k8s"
      validate_abs_path "$NFS_PATH" && ok "NFS path: ${NFS_PATH}" && break
    done
    echo ""

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
  hint "Deploys the official Kubernetes Dashboard with a NodePort HTTPS service."
  hint "Access via https://<control-plane>:<nodeport> using a generated admin token."
  echo ""

  prompt_yes_no INSTALL_DASHBOARD "Install Kubernetes Dashboard?" "n"
  echo ""

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    DASHBOARD_VERSION="2.7.0"
    while true; do
      prompt_input DASHBOARD_NODEPORT "Dashboard NodePort (HTTPS)" "32443"
      validate_nodeport "$DASHBOARD_NODEPORT" && ok "Dashboard NodePort: ${DASHBOARD_NODEPORT}" && break
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

  _vllm_defaults() {
    VLLM_NAMESPACE="vllm"; VLLM_NODEPORT="32080"
    VLLM_MODEL="meta-llama/Llama-3.2-1B-Instruct"; VLLM_HF_TOKEN=""
    VLLM_DTYPE="auto"; VLLM_MAX_MODEL_LEN="4096"; VLLM_GPU_COUNT="1"
    VLLM_CPU_REQUEST="4"; VLLM_CPU_LIMIT="8"
    VLLM_MEM_REQUEST="16Gi"; VLLM_MEM_LIMIT="32Gi"
    VLLM_EXTRA_ARGS=""; VLLM_STORAGE_SIZE="50Gi"
    VLLM_REUSE_PVC="false"; VLLM_PVC_NAME="vllm-model-cache"
  }

  if [[ "$INSTALL_NVIDIA" != "true" ]]; then
    warn_msg "NVIDIA is disabled — vLLM requires GPU support and will be skipped."
    INSTALL_VLLM="false"; _vllm_defaults; show_progress; return
  fi

  prompt_yes_no INSTALL_VLLM "Install vLLM production stack?" "n"
  echo ""

  if [[ "$INSTALL_VLLM" != "true" ]]; then
    _vllm_defaults; warn_msg "vLLM stack will be skipped."; show_progress; return
  fi

  # Namespace & NodePort
  while true; do
    prompt_input VLLM_NAMESPACE "vLLM namespace" "vllm"
    validate_namespace "$VLLM_NAMESPACE" && ok "Namespace: ${VLLM_NAMESPACE}" && break
  done
  echo ""

  while true; do
    prompt_input VLLM_NODEPORT "vLLM router NodePort" "32080"
    validate_nodeport "$VLLM_NODEPORT" && ok "vLLM NodePort: ${VLLM_NODEPORT}" && break
  done
  echo ""

  # Model selection with common suggestions
  echo -e "  ${BOLD}${BLUE}  Model Selection${NC}"
  echo -e "  ${DIM}  Common models (Enter to use, or type any HuggingFace model ID):${NC}"
  echo -e "  ${DIM}    1) meta-llama/Llama-3.2-1B-Instruct   (1B  — ~2 GB VRAM, fast)${NC}"
  echo -e "  ${DIM}    2) meta-llama/Llama-3.2-3B-Instruct   (3B  — ~6 GB VRAM)${NC}"
  echo -e "  ${DIM}    3) meta-llama/Llama-3.1-8B-Instruct   (8B  — ~16 GB VRAM)${NC}"
  echo -e "  ${DIM}    4) Qwen/Qwen2.5-7B-Instruct           (7B  — ~14 GB VRAM, public)${NC}"
  echo -e "  ${DIM}    5) mistralai/Mistral-7B-Instruct-v0.3 (7B  — ~14 GB VRAM)${NC}"
  echo -e "  ${DIM}    6) Custom model ID${NC}"
  echo ""
  local model_choice=""
  echo -ne "  ${BOLD}Model [1-6 or HF model ID]${NC} ${DIM}[1]${NC}: "
  read -r model_choice
  case "${model_choice:-1}" in
    1|"") VLLM_MODEL="meta-llama/Llama-3.2-1B-Instruct" ;;
    2)    VLLM_MODEL="meta-llama/Llama-3.2-3B-Instruct" ;;
    3)    VLLM_MODEL="meta-llama/Llama-3.1-8B-Instruct" ;;
    4)    VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct" ;;
    5)    VLLM_MODEL="mistralai/Mistral-7B-Instruct-v0.3" ;;
    6)    prompt_input VLLM_MODEL "HuggingFace model ID" "meta-llama/Llama-3.2-1B-Instruct" ;;
    *)    VLLM_MODEL="$model_choice" ;;  # user typed a model ID directly
  esac
  ok "Model: ${VLLM_MODEL}"
  echo ""

  # HuggingFace token
  echo -e "  ${BOLD}${BLUE}  HuggingFace Token${NC}"
  hint "Required for gated models (Llama, Gemma, Mistral, etc.). Leave blank for public models."
  # Detect if model is likely gated
  if echo "$VLLM_MODEL" | grep -qiE "llama|gemma|mistral|falcon"; then
    hint "⚠  '${VLLM_MODEL}' is typically a gated model — a HF token is likely required."
  fi
  echo ""
  echo -ne "  ${BOLD}HuggingFace token${NC} ${DIM}(Enter to skip)${NC}: "
  local hf_input=""; read -r -s hf_input; echo ""
  VLLM_HF_TOKEN="${hf_input}"
  if [[ -n "$VLLM_HF_TOKEN" ]]; then
    ok "HuggingFace token: set (hidden)"
  else
    warn_msg "No HF token — will fail for gated models."
  fi
  echo ""

  # Engine parameters
  echo -e "  ${BOLD}${BLUE}  Engine Parameters${NC}"
  prompt_choice VLLM_DTYPE \
    "Tensor dtype" \
    "auto (recommended — picks optimal dtype per GPU)" \
    "float16 (FP16 — Ampere/Turing)" \
    "bfloat16 (BF16 — Hopper/Ada/Blackwell)" \
    "float32 (FP32 — high precision, slow)"
  case "$VLLM_DTYPE" in
    auto*)    VLLM_DTYPE="auto" ;;
    float16*) VLLM_DTYPE="float16" ;;
    bfloat16*)VLLM_DTYPE="bfloat16" ;;
    float32*) VLLM_DTYPE="float32" ;;
  esac
  ok "dtype: ${VLLM_DTYPE}"
  echo ""

  prompt_input VLLM_MAX_MODEL_LEN "Max model context length (tokens)" "4096"
  ok "Max context length: ${VLLM_MAX_MODEL_LEN} tokens"
  echo ""

  # GPU count — auto-suggest based on worker count
  local suggested_gpus="1"
  if (( ${WORKER_COUNT:-0} >= 2 )); then suggested_gpus="${WORKER_COUNT}"; fi
  hint "Allocate multiple GPUs to enable tensor parallelism across GPUs."
  while true; do
    prompt_input VLLM_GPU_COUNT "Number of GPUs per replica" "$suggested_gpus"
    [[ "$VLLM_GPU_COUNT" =~ ^[1-9][0-9]*$ ]] && ok "GPUs per replica: ${VLLM_GPU_COUNT}" && break
    err "Must be a positive integer."
  done
  echo ""

  # Resource limits — auto-scale suggestion based on GPU count
  local suggested_mem_req="16Gi" suggested_mem_lim="32Gi"
  local suggested_cpu_req="4" suggested_cpu_lim="8"
  if (( VLLM_GPU_COUNT >= 4 )); then
    suggested_mem_req="64Gi"; suggested_mem_lim="128Gi"
    suggested_cpu_req="16"; suggested_cpu_lim="32"
    hint "Scaling resource suggestions for ${VLLM_GPU_COUNT} GPUs."
  elif (( VLLM_GPU_COUNT >= 2 )); then
    suggested_mem_req="32Gi"; suggested_mem_lim="64Gi"
    suggested_cpu_req="8"; suggested_cpu_lim="16"
    hint "Scaling resource suggestions for ${VLLM_GPU_COUNT} GPUs."
  fi

  echo -e "  ${BOLD}${BLUE}  Resource Limits${NC}"
  hint "CPU and memory per vLLM replica pod."
  echo ""
  prompt_input VLLM_CPU_REQUEST "CPU request (cores)" "$suggested_cpu_req"
  prompt_input VLLM_CPU_LIMIT   "CPU limit (cores)"   "$suggested_cpu_lim"
  prompt_input VLLM_MEM_REQUEST "Memory request"      "$suggested_mem_req"
  prompt_input VLLM_MEM_LIMIT   "Memory limit"        "$suggested_mem_lim"
  ok "Resources: CPU ${VLLM_CPU_REQUEST}–${VLLM_CPU_LIMIT} | Mem ${VLLM_MEM_REQUEST}–${VLLM_MEM_LIMIT}"

  # Memory adequacy warning
  local mem_req_gi
  mem_req_gi=$(echo "$VLLM_MEM_REQUEST" | grep -oE '[0-9]+')
  if echo "$VLLM_MODEL" | grep -qiE "70b|65b|34b" && (( ${mem_req_gi:-0} < 80 )); then
    warn_msg "Large model detected (likely 34–70B params). Memory request of ${VLLM_MEM_REQUEST} may be insufficient."
    hint "Recommend >= 80Gi for 34B, >= 140Gi for 70B models."
  elif echo "$VLLM_MODEL" | grep -qiE "13b|14b" && (( ${mem_req_gi:-0} < 28 )); then
    warn_msg "13–14B model detected. Memory request of ${VLLM_MEM_REQUEST} may be insufficient."
    hint "Recommend >= 28Gi for 13–14B models."
  fi
  echo ""

  # Extra vLLM args
  echo -e "  ${BOLD}${BLUE}  Extra vLLM Arguments${NC}"
  hint "Additional engine flags (e.g. --enable-chunked-prefill --quantization awq)."
  hint "Leave blank for defaults."
  echo ""
  prompt_optional VLLM_EXTRA_ARGS "Extra vLLM args" ""
  if [[ -n "$VLLM_EXTRA_ARGS" ]]; then ok "Extra args: ${VLLM_EXTRA_ARGS}"
  else ok "No extra args."; fi
  echo ""

  # Model cache storage
  echo -e "  ${BOLD}${BLUE}  Model Cache Storage${NC}"
  hint "Models are cached on a PVC so they survive pod restarts without re-downloading."
  echo ""
  prompt_yes_no VLLM_REUSE_PVC "Reuse an existing PVC for model cache?" "n"
  echo ""
  if [[ "$VLLM_REUSE_PVC" == "true" ]]; then
    prompt_input VLLM_PVC_NAME "Existing PVC name" "vllm-model-cache"
    ok "Will reuse PVC: ${VLLM_PVC_NAME}"
    VLLM_STORAGE_SIZE=""
  else
    prompt_input VLLM_PVC_NAME "PVC name to create" "vllm-model-cache"
    prompt_input VLLM_STORAGE_SIZE "Storage size for model cache" "50Gi"
    ok "Will create PVC ${VLLM_PVC_NAME} (${VLLM_STORAGE_SIZE})"
  fi
  echo ""

  show_progress
}

# ──────────────────────────────────────────────────────────────────────────────
# SECTION 9 — Namespaces
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
# SECTION 10 — Summary & Inline Edit
# ──────────────────────────────────────────────────────────────────────────────
print_summary() {
  local worker_count=0
  if [[ "$WORKER_IPS_STR" != "()" && -n "${WORKER_IPS_STR:-}" ]]; then
    worker_count=$(echo "$WORKER_IPS_STR" | grep -o '"' | wc -l)
    worker_count=$((worker_count / 2))
  fi
  local worker_list="none (single-node)"
  (( worker_count > 0 )) && worker_list=$(echo "$WORKER_IPS_STR" | tr -d '()"' | xargs)

  local nvidia_status="${RED}✖ Skip${NC}"; [[ "$INSTALL_NVIDIA" == "true" ]] && nvidia_status="${GREEN}✔ driver-${NVIDIA_DRIVER_VERSION}${NC}"
  local mon_status="${RED}✖ Skip${NC}";    [[ "$INSTALL_MONITORING" == "true" ]] && mon_status="${GREEN}✔ v${PROM_STACK_VERSION}${NC}"
  local nfs_status="${RED}✖ Skip${NC}";    [[ "$INSTALL_NFS" == "true" ]] && nfs_status="${GREEN}✔ ${NFS_SERVER_IP}:${NFS_PATH}${NC}"
  local dash_status="${RED}✖ Skip${NC}";   [[ "$INSTALL_DASHBOARD" == "true" ]] && dash_status="${GREEN}✔ v${DASHBOARD_VERSION}${NC}"
  local vllm_status="${RED}✖ Skip${NC}";   [[ "$INSTALL_VLLM" == "true" ]] && vllm_status="${GREEN}✔ ${VLLM_NAMESPACE}${NC}"

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
  echo -e "  NVIDIA drivers : $(echo -e "${nvidia_status}")"
  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    echo -e "    kernel       : ${DIM}$([[ "$NVIDIA_OPEN_KERNEL" == "true" ]] && echo open || echo proprietary) | FM: ${NVIDIA_FABRIC_MANAGER} | reboot: ${NVIDIA_REBOOT_TIMEOUT}s${NC}"
  fi
  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    echo -e "  Monitoring     : $(echo -e "${mon_status}")  (ns: ${NS_MONITORING})"
    echo -e "    Grafana      : ${CYAN}http://${CONTROL_PLANE_IP}:${GRAFANA_NODEPORT}${NC}"
    echo -e "    Prometheus   : ${CYAN}http://${CONTROL_PLANE_IP}:${PROMETHEUS_NODEPORT}${NC}"
    echo -e "    Alertmanager : ${CYAN}http://${CONTROL_PLANE_IP}:${ALERTMANAGER_NODEPORT}${NC}"
    echo -e "    Retention    : ${CYAN}${PROM_RETENTION}${NC}  |  Storage: ${CYAN}${PROM_STORAGE_SIZE}${NC}"
  else
    echo -e "  Monitoring     : $(echo -e "${mon_status}")"
  fi
  if [[ "$INSTALL_NFS" == "true" ]]; then
    echo -e "  NFS            : $(echo -e "${nfs_status}")"
    echo -e "    StorageClass : ${CYAN}${NFS_STORAGE_CLASS}${NC}  (default: ${NFS_DEFAULT_SC})"
  else
    echo -e "  NFS            : $(echo -e "${nfs_status}")"
  fi
  [[ "$INSTALL_NVIDIA" == "true" ]] &&     echo -e "  GPU Operator   : ${GREEN}✔${NC}  (ns: ${NS_GPU_OPERATOR})"
  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    if [[ "${GPU_TIMESLICING_ENABLED:-false}" == "true" ]]; then
      echo -e "  GPU Timeslicing: ${GREEN}✔ ${GPU_TIMESLICE_COUNT}x virtual GPUs per physical GPU${NC}"
    else
      echo -e "  GPU Timeslicing: ${DIM}disabled${NC}"
    fi
  fi
  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    echo -e "  Dashboard      : $(echo -e "${dash_status}")"
    echo -e "    URL          : ${CYAN}https://${CONTROL_PLANE_IP}:${DASHBOARD_NODEPORT}${NC}"
  else
    echo -e "  Dashboard      : $(echo -e "${dash_status}")"
  fi
  if [[ "$INSTALL_VLLM" == "true" ]]; then
    echo -e "  vLLM Stack     : $(echo -e "${vllm_status}")"
    echo -e "    Router       : ${CYAN}http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1${NC}"
    echo -e "    Model        : ${CYAN}${VLLM_MODEL}${NC}"
    echo -e "    dtype        : ${CYAN}${VLLM_DTYPE}${NC}  |  ctx: ${CYAN}${VLLM_MAX_MODEL_LEN}${NC} tokens  |  GPUs: ${CYAN}${VLLM_GPU_COUNT}${NC}"
    [[ -n "${VLLM_HF_TOKEN:-}" ]] && echo -e "    HF Token     : ${GREEN}set (hidden)${NC}" || echo -e "    HF Token     : ${YELLOW}not set${NC}"
    if [[ "${VLLM_REUSE_PVC:-false}" == "true" ]]; then
      echo -e "    Storage      : ${CYAN}reuse PVC ${VLLM_PVC_NAME}${NC}"
    else
      echo -e "    Storage      : ${CYAN}new PVC ${VLLM_PVC_NAME} (${VLLM_STORAGE_SIZE})${NC}"
    fi
    [[ -n "${VLLM_EXTRA_ARGS:-}" ]] && echo -e "    Extra args   : ${DIM}${VLLM_EXTRA_ARGS}${NC}"
  else
    echo -e "  vLLM Stack     : $(echo -e "${vllm_status}")"
  fi
  echo ""
  echo -e "  ${DIM}Config will be saved to: ${CONFIG_FILE}${NC}"
  echo ""
}

confirm_summary() {
  section_header "Configuration Summary — Review Before Continuing" "10/10"

  while true; do
    print_summary

    echo -e "  ${BOLD}What would you like to do?${NC}"
    echo -e "    ${CYAN}y${NC}) Save and continue"
    echo -e "    ${CYAN}n${NC}) Abort"
    echo -e "    ${CYAN}1${NC}) Edit SSH & Access"
    echo -e "    ${CYAN}2${NC}) Edit Cluster Nodes"
    echo -e "    ${CYAN}3${NC}) Edit Kubernetes Settings"
    echo -e "    ${CYAN}4${NC}) Edit NVIDIA Drivers"
    echo -e "    ${CYAN}5${NC}) Edit Monitoring"
    echo -e "    ${CYAN}6${NC}) Edit NFS Provisioner"
    echo -e "    ${CYAN}7${NC}) Edit Kubernetes Dashboard"
    echo -e "    ${CYAN}8${NC}) Edit vLLM Stack"
    echo -e "    ${CYAN}9${NC}) Edit Namespaces"
    echo -e "    ${CYAN}p${NC}) Run pre-flight checks"
    echo ""
    echo -ne "  ${BOLD}Choice${NC} ${DIM}[y/n/1-9/p]${NC}: "
    local choice; read -r choice
    case "${choice,,}" in
      y|yes|"") show_progress; return ;;
      n|no)     echo ""; warn_msg "Configuration cancelled."; exit 0 ;;
      1) CURRENT_SECTION=0; collect_ssh ;;
      2) CURRENT_SECTION=1; collect_nodes ;;
      3) CURRENT_SECTION=2; collect_k8s ;;
      4) CURRENT_SECTION=3; collect_nvidia ;;
      5) CURRENT_SECTION=4; collect_monitoring ;;
      6) CURRENT_SECTION=5; collect_nfs ;;
      7) CURRENT_SECTION=6; collect_dashboard ;;
      8) CURRENT_SECTION=7; collect_vllm ;;
      9) CURRENT_SECTION=8; collect_namespaces ;;
      p) run_preflight full ;;
      *) err "Invalid choice." ;;
    esac
    section_header "Configuration Summary — Review Before Continuing" "10/10"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# WRITE CONFIG FILE
# ──────────────────────────────────────────────────────────────────────────────
write_config() {
  local safe_pw
  safe_pw=$(printf '%q' "$GRAFANA_ADMIN_PASSWORD")

  cat > "$CONFIG_FILE" <<CONFEOF
# =============================================================================
# k8s_cluster.conf — Generated by k8s_configure.sh on $(date)
# CONF_VERSION=${CONF_VERSION}
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
GPU_TIMESLICING_ENABLED="${GPU_TIMESLICING_ENABLED}"
GPU_TIMESLICE_COUNT="${GPU_TIMESLICE_COUNT}"

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
# PATCH INSTALLER
# ──────────────────────────────────────────────────────────────────────────────
patch_installer() {
  if [[ ! -f "$INSTALLER" ]]; then
    warn_msg "Installer not found at ${INSTALLER} — config written but installer not patched."
    return
  fi
  local worker_arr_str="$WORKER_IPS_STR"
  local tmp; tmp=$(mktemp)

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
      -v gts_en="$GPU_TIMESLICING_ENABLED" \
      -v gts_cnt="$GPU_TIMESLICE_COUNT" \
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
   in_conf && /^NVIDIA_OPEN_KERNEL=/    { print "NVIDIA_OPEN_KERNEL=\"" nv_open "\""; next }
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
   in_conf && /^GPU_TIMESLICING_ENABLED=/ { print "GPU_TIMESLICING_ENABLED=\"" gts_en "\""; next }
   in_conf && /^GPU_TIMESLICE_COUNT=/     { print "GPU_TIMESLICE_COUNT=\"" gts_cnt "\""; next }
   /^# ─.*SANITY CHECKS/ { in_conf=0 }
   { print }' "$INSTALLER" > "$tmp"

  chmod 700 "$tmp"
  mv "$tmp" "$INSTALLER"
  ok "Installer patched with your configuration."
}

# ──────────────────────────────────────────────────────────────────────────────
# OFFER LAUNCH
# ──────────────────────────────────────────────────────────────────────────────
offer_launch() {
  echo ""
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "  ${BOLD}  Configuration complete!${NC}"
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  To run the ${BOLD}full installer${NC}:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER}${NC}"
  echo ""
  echo -e "  To run a ${BOLD}single step${NC}:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER} --step <step-name>${NC}"
  echo ""
  printf "  ${BOLD}%-14s %-18s %s${NC}\n" "Step name" "Aliases" "Phase"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "ssh"        ""                    "SSH key setup"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "prep"       "node-prep"            "Node preparation"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "nvidia"     ""                     "NVIDIA drivers"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "k8s-bins"   "k8s bins"             "Kubernetes binaries"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "init"       "control plane"        "Control plane init"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "cni"        "CNI"                  "CNI plugin"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "workers"    "join workers"         "Join worker nodes"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "helm"       "Helm"                 "Install Helm"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "nfs"        "NFS"                  "NFS provisioner"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "monitoring" "prometheus grafana"   "Monitoring stack"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "gpu-op"     "gpu operator"         "GPU Operator"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "dashboard"  "Dashboard"            "Kubernetes Dashboard"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "vllm"       "vLLM vLLM Stack"      "vLLM production stack"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "verify"     "verification"         "Post-install check"
  echo ""
  echo -e "  To ${BOLD}re-run the wizard for a single section${NC}:"
  echo -e "    ${CYAN}bash ${BASH_SOURCE[0]} --section <name>${NC}"
  echo -e "    ${DIM}Sections: ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces${NC}"
  echo ""
  echo -e "  To run ${BOLD}pre-flight checks${NC} only:"
  echo -e "    ${CYAN}bash ${BASH_SOURCE[0]} --preflight${NC}"
  echo ""
  echo -e "  To ${BOLD}uninstall${NC} the cluster:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER} --uninstall${NC}"
  echo ""

  if [[ ! -f "$INSTALLER" ]]; then
    warn_msg "Installer script not found — cannot launch automatically."
    return
  fi

  prompt_yes_no LAUNCH_NOW "Launch the full installer now?" "n"
  if [[ "$LAUNCH_NOW" == "true" ]]; then
    echo ""
    if [[ $EUID -ne 0 ]]; then
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
# CHECK EXISTING CONFIG / MIGRATION
# ──────────────────────────────────────────────────────────────────────────────
check_existing_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    print_header
    echo -e "  ${YELLOW}${SYM_WARN}  An existing configuration was found:${NC}"
    echo -e "  ${DIM}${CONFIG_FILE}${NC}"
    echo ""
    source "$CONFIG_FILE" 2>/dev/null || true

    # Version migration
    local file_ver="${CONF_VERSION_FILE:-1}"
    if grep -q "CONF_VERSION=" "$CONFIG_FILE" 2>/dev/null; then
      file_ver=$(grep "CONF_VERSION=" "$CONFIG_FILE" | head -1 | cut -d= -f2)
    fi
    if (( file_ver < CONF_VERSION )); then
      warn_msg "Config file is version ${file_ver} — current wizard is version ${CONF_VERSION}."
      hint "New fields will be added with defaults when you reconfigure."
    fi

    echo -e "  ${DIM}Control plane : ${CONTROL_PLANE_IP:-<not set>}${NC}"
    echo -e "  ${DIM}Workers       : $(echo "${WORKER_IPS[@]:-}" | tr ' ' ',' | sed 's/,$//') ${NC}"
    echo -e "  ${DIM}SSH user      : ${SSH_USER:-<not set>}${NC}"
    echo -e "  ${DIM}K8s version   : ${K8S_VERSION:-<not set>}${NC}"
    echo -e "  ${DIM}CNI           : ${CNI_PLUGIN:-<not set>}${NC}"
    echo ""

    echo -e "  ${BOLD}Options:${NC}"
    echo -e "    ${CYAN}r${NC}) Reconfigure (full wizard)"
    echo -e "    ${CYAN}e${NC}) Edit a single section"
    echo -e "    ${CYAN}p${NC}) Run pre-flight checks against current config"
    echo -e "    ${CYAN}s${NC}) Show config and launch installer"
    echo -e "    ${CYAN}q${NC}) Quit"
    echo ""
    echo -ne "  ${BOLD}Choice [r/e/p/s/q]${NC}: "
    local choice; read -r choice
    case "${choice,,}" in
      r) echo ""; return ;;   # fall through to full wizard
      e) run_section_menu ;;
      p)
        WORKER_IPS_STR="($(echo "${WORKER_IPS[@]:-}" | tr ' ' '\n' | grep '\.' | sed 's/^/"/' | sed 's/$/" /' | tr -d '\n'))"
        run_preflight preflight-only
        offer_launch; exit 0 ;;
      s)
        print_header
        section_header "Current Configuration"
        WORKER_IPS_STR="($(echo "${WORKER_IPS[@]:-}" | tr ' ' '\n' | grep '\.' | sed 's/^/"/' | sed 's/$/" /' | tr -d '\n'))"
        print_summary
        offer_launch; exit 0 ;;
      q|"") echo ""; ok "Keeping existing configuration."; offer_launch; exit 0 ;;
      *)    echo ""; return ;;
    esac
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SINGLE-SECTION EDIT MENU
# ──────────────────────────────────────────────────────────────────────────────
run_section_menu() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE" 2>/dev/null || true
    # Rebuild WORKER_IPS_STR from the sourced array
    local arr_str="("
    for ip in "${WORKER_IPS[@]:-}"; do [[ -n "$ip" ]] && arr_str+="\"$ip\" "; done
    arr_str="${arr_str% })"; WORKER_IPS_STR="$arr_str"
    WORKER_COUNT=$(echo "${WORKER_IPS[@]:-}" | wc -w)
  fi

  echo ""
  echo -e "  ${BOLD}Which section do you want to edit?${NC}"
  echo -e "    ${CYAN}1${NC}) SSH & Access"
  echo -e "    ${CYAN}2${NC}) Cluster Nodes"
  echo -e "    ${CYAN}3${NC}) Kubernetes Settings"
  echo -e "    ${CYAN}4${NC}) NVIDIA Drivers"
  echo -e "    ${CYAN}5${NC}) Monitoring"
  echo -e "    ${CYAN}6${NC}) NFS Provisioner"
  echo -e "    ${CYAN}7${NC}) Kubernetes Dashboard"
  echo -e "    ${CYAN}8${NC}) vLLM Stack"
  echo -e "    ${CYAN}9${NC}) Namespaces"
  echo -ne "  ${BOLD}Choice [1-9]${NC}: "
  local choice; read -r choice
  CURRENT_SECTION=0
  case "$choice" in
    1) collect_ssh ;;
    2) collect_nodes ;;
    3) collect_k8s ;;
    4) collect_nvidia ;;
    5) collect_monitoring ;;
    6) collect_nfs ;;
    7) collect_dashboard ;;
    8) collect_vllm ;;
    9) collect_namespaces ;;
    *) err "Invalid choice."; run_section_menu; return ;;
  esac
  write_config
  patch_installer
  offer_launch
  exit 0
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI ARGUMENT HANDLING
# ──────────────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --section)
        shift
        if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE" 2>/dev/null || true; fi
        local arr_str="("
        for ip in "${WORKER_IPS[@]:-}"; do [[ -n "$ip" ]] && arr_str+="\"$ip\" "; done
        arr_str="${arr_str% })"; WORKER_IPS_STR="${arr_str:-()}"
        WORKER_COUNT=$(echo "${WORKER_IPS[@]:-}" | wc -w)
        CURRENT_SECTION=0
        case "${1:-}" in
          ssh)        collect_ssh ;;
          nodes)      collect_nodes ;;
          k8s)        collect_k8s ;;
          nvidia)     collect_nvidia ;;
          monitoring) collect_monitoring ;;
          nfs)        collect_nfs ;;
          dashboard)  collect_dashboard ;;
          vllm)       collect_vllm ;;
          namespaces) collect_namespaces ;;
          *)
            err "Unknown section: ${1:-}"
            echo "  Valid sections: ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces"
            exit 1 ;;
        esac
        write_config; patch_installer; offer_launch; exit 0 ;;

      --preflight)
        if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE" 2>/dev/null || true; fi
        local arr_str="("
        for ip in "${WORKER_IPS[@]:-}"; do [[ -n "$ip" ]] && arr_str+="\"$ip\" "; done
        arr_str="${arr_str% })"; WORKER_IPS_STR="${arr_str:-()}"
        print_header
        run_preflight preflight-only
        exit 0 ;;

      --show)
        if [[ -f "$CONFIG_FILE" ]]; then
          echo ""
          echo -e "${BOLD}${CYAN}Current configuration (${CONFIG_FILE}):${NC}"
          echo ""
          cat "$CONFIG_FILE"
        else
          err "No config file found at ${CONFIG_FILE}"
          exit 1
        fi
        exit 0 ;;

      --help|-h)
        echo ""
        echo -e "${BOLD}Usage:${NC}"
        echo -e "  ${CYAN}bash k8s_configure.sh${NC}                    Full interactive wizard"
        echo -e "  ${CYAN}bash k8s_configure.sh --section <name>${NC}   Re-run a single section"
        echo -e "  ${CYAN}bash k8s_configure.sh --preflight${NC}        Pre-flight checks only"
        echo -e "  ${CYAN}bash k8s_configure.sh --show${NC}             Print current config"
        echo ""
        echo -e "${BOLD}Section names:${NC} ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces"
        echo ""
        exit 0 ;;

      *) err "Unknown argument: $1"; exit 1 ;;
    esac
    shift
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
trap 'echo -e "\n\n  ${YELLOW}${SYM_WARN}  Wizard interrupted — no changes saved.${NC}\n"; exit 130' INT

# Handle CLI flags before the interactive flow
parse_args "$@"

print_header
check_existing_config
print_header
echo -e "  ${DIM}This wizard collects all parameters needed to install your"
echo -e "  Kubernetes cluster and saves them to ${CONFIG_FILE}.${NC}"
echo -e "  ${DIM}You can abort at any time with Ctrl+C.${NC}"
echo ""

# Initialise WORKER_COUNT so vLLM GPU suggestion works even if collect_nodes
# is the first section called
WORKER_COUNT=0

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
run_preflight full
offer_launch
