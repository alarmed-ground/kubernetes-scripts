#!/usr/bin/env bash
# =============================================================================
# Kubernetes Cluster Installer for Ubuntu 24.04
# Installs: passwordless SSH, NVIDIA drivers, Kubernetes, Prometheus, Grafana,
#           GPU Operator, NFS External Provisioner
# =============================================================================
set -euo pipefail
# NOTE: IFS is intentionally left at default (space/tab/newline).
# A non-default IFS breaks array parsing in sourced conf files and
# space-delimited for-loops (e.g. is_local_node's IP list iteration).

# ERR trap — fires on any command that exits non-zero under set -e.
# Prints the exact line number and command so silent exits are diagnosed.
trap 'echo "[FATAL] Script aborted at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ──────────────────────────────────────────────────────────────────────────────
# SCRIPT METADATA
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/k8s_install_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/tmp/k8s_install.lock"
CONFIG_FILE="${SCRIPT_DIR}/k8s_cluster.conf"

# ──────────────────────────────────────────────────────────────────────────────
# SOURCE EXTERNAL CONFIG (overrides the static defaults below)
# ──────────────────────────────────────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  # Temporarily disable exit-on-error around source so a bad conf line
  # produces a clear message rather than a silent drop to terminal.
  set +e
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  _src_rc=$?
  set -e
  if (( _src_rc != 0 )); then
    echo "[config] ERROR: Failed to source ${CONFIG_FILE} (exit ${_src_rc})." >&2
    echo "[config] Check the file for syntax errors: bash -n ${CONFIG_FILE}" >&2
    exit 1
  fi
  echo "[config] Loaded configuration from ${CONFIG_FILE}"
else
  echo "[config] No k8s_cluster.conf found — using built-in defaults."
  echo "[config] Run './k8s_configure.sh' to generate a config interactively."
fi

# ──────────────────────────────────────────────────────────────────────────────
# COLOR OUTPUT
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔  $*${NC}" | tee -a "$LOG_FILE" || true; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠  $*${NC}" | tee -a "$LOG_FILE" || true; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✖  $*${NC}" | tee -a "$LOG_FILE" >&2 || true; }
info()    { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ  $*${NC}" | tee -a "$LOG_FILE" || true; }
section() {
  {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${NC}\n"
  } | tee -a "$LOG_FILE" || true
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Built-in defaults (overridden by k8s_cluster.conf if present)
# ──────────────────────────────────────────────────────────────────────────────
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"          # e.g. 192.168.1.10
# WORKER_IPS: use existing array if set, otherwise initialise to empty array.
# "${WORKER_IPS[@]:-}" fails under set -u when the array has never been declared.
if ! declare -p WORKER_IPS &>/dev/null 2>&1; then
  WORKER_IPS=()
fi
SSH_USER="${SSH_USER:-ubuntu}"                    # Remote user with sudo privileges
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/k8s_cluster_rsa}"
K8S_VERSION="${K8S_VERSION:-1.31}"               # Kubernetes minor version
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"           # Flannel default; change for Calico: 192.168.0.0/16
CNI_PLUGIN="${CNI_PLUGIN:-flannel}"              # flannel | calico
NFS_SERVER_IP="${NFS_SERVER_IP:-}"               # IP of your NFS server
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"            # Exported NFS path on server
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-590}"  # 525|535|550|560|565|570|580|590 or *-open variants
NVIDIA_OPEN_KERNEL="${NVIDIA_OPEN_KERNEL:-false}"      # true = install nvidia-driver-*-open (Turing+ recommended)
NVIDIA_FABRIC_MANAGER="${NVIDIA_FABRIC_MANAGER:-auto}" # auto|true|false — NVLink/NVSwitch multi-GPU systems
NVIDIA_REBOOT_TIMEOUT="${NVIDIA_REBOOT_TIMEOUT:-300}"  # seconds to wait for node to come back after reboot
HELM_VERSION="${HELM_VERSION:-3.16.2}"

# Namespace names
NS_MONITORING="${NS_MONITORING:-monitoring}"
NS_GPU_OPERATOR="${NS_GPU_OPERATOR:-gpu-operator}"
NS_NFS="${NS_NFS:-nfs-provisioner}"

# Prometheus / Grafana chart versions (kube-prometheus-stack)
PROM_STACK_VERSION="${PROM_STACK_VERSION:-65.1.0}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ChangeMe123!}"   # ← Change before production use

# NodePort assignments (wizard-configurable)
GRAFANA_NODEPORT="${GRAFANA_NODEPORT:-32000}"
PROMETHEUS_NODEPORT="${PROMETHEUS_NODEPORT:-32001}"
ALERTMANAGER_NODEPORT="${ALERTMANAGER_NODEPORT:-32002}"

# Prometheus storage (wizard-configurable)
PROM_RETENTION="${PROM_RETENTION:-30d}"
PROM_STORAGE_SIZE="${PROM_STORAGE_SIZE:-20Gi}"

# NFS StorageClass settings (wizard-configurable)
NFS_STORAGE_CLASS="${NFS_STORAGE_CLASS:-nfs-client}"
NFS_DEFAULT_SC="${NFS_DEFAULT_SC:-true}"

# Feature flags (set by wizard; default to true for backward compat)
INSTALL_NVIDIA="${INSTALL_NVIDIA:-true}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"
INSTALL_NFS="${INSTALL_NFS:-true}"
INSTALL_DASHBOARD="${INSTALL_DASHBOARD:-false}"
INSTALL_VLLM="${INSTALL_VLLM:-false}"

# Kubernetes Dashboard
DASHBOARD_VERSION="${DASHBOARD_VERSION:-2.7.0}"
DASHBOARD_NODEPORT="${DASHBOARD_NODEPORT:-32443}"
NS_DASHBOARD="${NS_DASHBOARD:-kubernetes-dashboard}"

# vLLM Production Stack
VLLM_NAMESPACE="${VLLM_NAMESPACE:-vllm}"
VLLM_NODEPORT="${VLLM_NODEPORT:-32080}"
VLLM_MODEL="${VLLM_MODEL:-meta-llama/Llama-3.2-1B-Instruct}"
VLLM_HF_TOKEN="${VLLM_HF_TOKEN:-}"
VLLM_DTYPE="${VLLM_DTYPE:-auto}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-4096}"
VLLM_GPU_COUNT="${VLLM_GPU_COUNT:-1}"
VLLM_CPU_REQUEST="${VLLM_CPU_REQUEST:-4}"
VLLM_CPU_LIMIT="${VLLM_CPU_LIMIT:-8}"
VLLM_MEM_REQUEST="${VLLM_MEM_REQUEST:-16Gi}"
VLLM_MEM_LIMIT="${VLLM_MEM_LIMIT:-32Gi}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
VLLM_STORAGE_SIZE="${VLLM_STORAGE_SIZE:-50Gi}"
VLLM_REUSE_PVC="${VLLM_REUSE_PVC:-false}"
VLLM_PVC_NAME="${VLLM_PVC_NAME:-vllm-model-cache}"

# ──────────────────────────────────────────────────────────────────────────────
# SANITY CHECKS
# ──────────────────────────────────────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
  fi
}

check_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    error "Another instance is running (lock: $LOCK_FILE). If stale, remove it and retry."
    exit 1
  fi
  touch "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

validate_config() {
  section "Validating Configuration"
  local errors=0

  [[ -z "$CONTROL_PLANE_IP" ]]   && { error "CONTROL_PLANE_IP is not set."; ((errors++)); }
  [[ ${#WORKER_IPS[@]} -eq 0 ]]  && warn "No WORKER_IPS defined — single-node cluster."
  [[ -z "$NFS_SERVER_IP" ]]      && warn "NFS_SERVER_IP not set — NFS provisioner will be skipped."

  if (( errors > 0 )); then
    error "$errors configuration error(s). Edit the CONFIGURATION section and retry."
    exit 1
  fi
  log "Configuration validated."

  # Report which nodes will run locally vs. via SSH — helps catch misdetection
  _build_local_ip_cache
  info "Local IPs detected on this machine: ${_LOCAL_IPS}"
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    if is_local_node "$node"; then
      info "  Node ${node} → LOCAL  (commands run directly, no SSH)"
    else
      info "  Node ${node} → REMOTE (commands run via SSH)"
    fi
  done

  # Probe nodes for sudo access and cache password once if needed.
  # This prevents "terminal required" errors during later remote steps.
  ensure_sudo_pass
}

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS: SSH / SCP with full permission and sudo handling
#
# sudo strategy — tried in order until one succeeds:
#
#   1. NOPASSWD  — sudo -n (non-interactive, no password needed at all)
#   2. SUDO_PASS — echo "$SUDO_PASS" | sudo -S  (pipe password via stdin)
#   3. Prompt    — sudo -S with password read interactively from the local tty
#
# The error "a terminal is required / sudo -S option" happens when:
#   • sudo needs a password  AND
#   • no stdin password is supplied  AND
#   • SSH was opened with BatchMode=yes (which disables the remote tty)
#
# Fix: always use "echo | sudo -S" when a password is involved so sudo reads
# from stdin rather than trying to open /dev/tty, which is unavailable in a
# non-interactive SSH session.
# ──────────────────────────────────────────────────────────────────────────────

# Collect the sudo password once and cache it in SUDO_PASS for the session.
# Call this before any remote sudo operation when NOPASSWD is not configured.
ensure_sudo_pass() {
  # Already have it — nothing to do
  [[ -n "${SUDO_PASS:-}" ]] && return 0

  # Check if ALL nodes already accept passwordless sudo
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  local needs_pass=false
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    # Local node — we already have root via sudo; no SSH probe needed
    if is_local_node "$node"; then continue; fi
    if ! ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o ConnectTimeout=10 \
             -o BatchMode=yes \
             "${SSH_USER}@${node}" \
             "sudo -n true" 2>/dev/null; then
      needs_pass=true
      break
    fi
  done

  if $needs_pass; then
    info "One or more nodes require a sudo password for user '${SSH_USER}'."
    info "Enter it once — it will be reused for all nodes this session."
    # Read from the local terminal (/dev/tty) even when stdin is redirected
    local pw=""
    if [[ -t 0 ]]; then
      read -r -s -p "  [sudo] Password for ${SSH_USER}: " pw; echo ""
    else
      read -r -s pw < /dev/tty; echo ""
    fi
    export SUDO_PASS="$pw"
    info "sudo password cached for this session."
  else
    info "All nodes accept passwordless sudo — no password needed."
    export SUDO_PASS=""
  fi
}

# Base SSH executor (BatchMode=yes — never opens a remote tty)
ssh_exec() {
  local host="$1"; shift
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o BatchMode=yes \
      "${SSH_USER}@${host}" "$@"
}

# _sudo_prefix — returns the correct inline sudo invocation for a remote shell.
# Always uses "sudo -S" so the password is read from stdin (pipe), never from
# a terminal — this is the only approach that works over a BatchMode SSH session.
#
#   No password needed : "sudo -n"
#   Password cached    : "echo '<pw>' | sudo -S"
#   Interactive prompt : reads from /dev/tty on the remote (last resort)
_sudo_prefix() {
  if [[ -z "${SUDO_PASS:-}" ]]; then
    # Try non-interactive first; caller wraps the command with this prefix
    echo "sudo -n"
  else
    # Pipe password via stdin; -S reads one line from stdin as the password.
    # printf is used instead of echo to avoid a trailing newline issue on some shells.
    printf "printf '%%s\\n' %q | sudo -S" "$SUDO_PASS"
  fi
}

# ssh_sudo HOST CMD… — run a shell command as root on a remote node.
# Automatically selects the correct sudo invocation (NOPASSWD / -S / interactive).
ssh_sudo() {
  local host="$1"; shift
  local cmd="$*"

  # ── Try 1: NOPASSWD sudo ──────────────────────────────────────────────────
  if ssh_exec "$host" "sudo -n bash -c $(printf '%q' "$cmd")" 2>/dev/null; then
    return 0
  fi

  # ── Try 2: password via stdin (-S) ────────────────────────────────────────
  if [[ -n "${SUDO_PASS:-}" ]]; then
    # printf writes "<password>\n" to sudo's stdin; -S reads exactly one line
    if ssh_exec "$host" \
         "printf '%s\n' $(printf '%q' "$SUDO_PASS") | sudo -S bash -c $(printf '%q' "$cmd")" \
         2>&1 | grep -v "^\[sudo\]"; then
      return 0
    fi
  fi

  # ── Try 3: prompt interactively (only works if local tty is a terminal) ───
  warn "[${host}] Falling back to interactive sudo — you may be prompted."
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -t \
      "${SSH_USER}@${host}" "sudo bash -c $(printf '%q' "$cmd")"
}

# ──────────────────────────────────────────────────────────────────────────────
# scp_and_run — copy a local script to a remote node and execute it as root
#
# WHY the wrapper-script pattern:
#   Passing multi-line strings as SSH arguments is the root cause of
#   "Permission denied" — the remote shell receives the heredoc as a single
#   quoted argument, which many SSH daemons truncate or reject entirely.
#   Writing the logic to a local wrapper file and SCP-ing it means SSH only
#   ever runs ONE short command: "bash /tmp/wrapper.sh"
#
# File flow on remote (both deleted on exit):
#   /tmp/k8s_payload_<id>.sh  — the caller's script         (mode 600, SSH_USER)
#   /tmp/k8s_wrapper_<id>.sh  — chmod + sudo orchestrator   (mode 700, SSH_USER)
#
# sudo strategy inside the wrapper:
#   NOPASSWD  →  sudo -n bash payload.sh
#   Password  →  printf '%s\n' <pw> | sudo -S bash payload.sh  (never opens tty)
#   PIPESTATUS[1] captures sudo's exit code from the printf|sudo pipeline
# ──────────────────────────────────────────────────────────────────────────────
scp_and_run() {
  local host="$1"
  local local_script="$2"

  # Unique IDs — PID + epoch avoids collisions on concurrent runs
  local uid="$$_$(date +%s)"
  local remote_payload="/tmp/k8s_payload_${uid}.sh"
  local remote_wrapper="/tmp/k8s_wrapper_${uid}.sh"
  local local_wrapper="/tmp/k8s_wrapper_local_${uid}.sh"

  # ── 1. Ensure payload is mode 600 before upload ───────────────────────────
  # root can always read 600 files via sudo; SSH_USER owns the file after SCP.
  chmod 600 "$local_script"

  info "[${host}] Uploading $(basename "$local_script")..."
  if ! scp -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            "$local_script" \
            "${SSH_USER}@${host}:${remote_payload}" 2>&1 | tee -a "$LOG_FILE"; then
    error "[${host}] SCP upload failed for $(basename "$local_script")"
    return 1
  fi

  # ── 2. Write wrapper script locally ───────────────────────────────────────
  if [[ -z "${SUDO_PASS:-}" ]]; then
    cat > "$local_wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
chmod 600 ${remote_payload}
sudo -n bash ${remote_payload}
_RC=\$?
rm -f ${remote_payload} ${remote_wrapper}
exit \$_RC
WRAPPER
  else
    local escaped_pw
    escaped_pw=$(printf '%q' "$SUDO_PASS")
    cat > "$local_wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
chmod 600 ${remote_payload}
printf '%s\n' ${escaped_pw} | sudo -S bash ${remote_payload} 2>/dev/null
_RC=\${PIPESTATUS[1]}
rm -f ${remote_payload} ${remote_wrapper}
exit \$_RC
WRAPPER
  fi
  # Mode 700: SSH_USER can execute the wrapper without sudo
  chmod 700 "$local_wrapper"

  # ── 3. Upload wrapper ──────────────────────────────────────────────────────
  if ! scp -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            "$local_wrapper" \
            "${SSH_USER}@${host}:${remote_wrapper}" 2>&1 | tee -a "$LOG_FILE"; then
    error "[${host}] SCP upload failed for wrapper"
    ssh_exec "$host" "rm -f ${remote_payload}" 2>/dev/null || true
    rm -f "$local_wrapper"
    return 1
  fi
  rm -f "$local_wrapper"

  # ── 4. Execute — single clean one-liner, zero quoting issues ──────────────
  info "[${host}] Executing $(basename "$local_script") as root..."
  if ! ssh_exec "$host" "bash ${remote_wrapper}" 2>&1 | tee -a "$LOG_FILE"; then
    error "[${host}] Remote execution failed: $(basename "$local_script")"
    ssh_exec "$host" "rm -f ${remote_payload} ${remote_wrapper}" 2>/dev/null || true
    return 1
  fi

  log "[${host}] $(basename "$local_script") completed successfully."
}

# ──────────────────────────────────────────────────────────────────────────────
# LOCAL-OR-REMOTE DISPATCH
#
# When the installer runs ON the control plane itself (common for bare-metal
# or single-machine setups), SSH-ing into localhost is wasteful and can fail
# if SSH isn't listening or the key isn't in authorized_keys yet.
#
# is_local_node HOST  — returns 0 if HOST resolves to a local interface IP
# run_on HOST CMD…    — runs CMD directly (bash -c) if local, else via ssh_exec
# run_script_on HOST SCRIPT — runs a local script file directly if local, else
#                             via scp_and_run (upload wrapper + execute as root)
# fetch_file_from HOST REMOTE_PATH LOCAL_PATH
#                     — copies a file from HOST:REMOTE to LOCAL_PATH;
#                       uses cp if local, scp if remote
# ──────────────────────────────────────────────────────────────────────────────

# Cache of local IPs — populated once at script start, never in a subshell
_LOCAL_IPS=""

_build_local_ip_cache() {
  [[ -n "$_LOCAL_IPS" ]] && return 0   # already built
  _LOCAL_IPS="127.0.0.1 localhost"
  # ip addr — primary source
  while IFS= read -r addr; do
    if [[ -n "$addr" ]]; then
      _LOCAL_IPS="$_LOCAL_IPS $addr"
    fi
  done < <(ip -4 addr show 2>/dev/null \
    | awk '/inet / {split($2,a,"/"); print a[1]}')
  # hostname -I — fallback / additional addresses
  while IFS= read -r addr; do
    if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      _LOCAL_IPS="$_LOCAL_IPS $addr"
    fi
  done < <(hostname -I 2>/dev/null | tr ' ' '\n')
  return 0  # always succeed — never let set -e kill the script here
}

# Populate the cache immediately at script load time (not inside a subshell).
# The || true ensures set -e cannot kill the script if something unexpected happens.
_build_local_ip_cache || true

is_local_node() {
  local host="${1// /}"   # strip any accidental whitespace from the argument

  # Resolve hostname → IP if not already a dotted-quad
  local resolved="$host"
  if ! [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' || echo "$host")
  fi

  # Walk every local IP token — word-split is intentional here
  local lip
  for lip in $_LOCAL_IPS; do
    if [[ "$resolved" == "$lip" || "$host" == "$lip" ]]; then
      return 0   # this host is the local machine
    fi
  done
  return 1
}

# run_on HOST CMD — execute a shell command on HOST as root.
# Local: sudo bash -c CMD  (respects SUDO_PASS the same way)
# Remote: ssh_exec + inline sudo (existing behaviour)
run_on() {
  local host="$1"; shift
  local cmd="$*"

  if is_local_node "$host"; then
    # ── Local: elevate with sudo ─────────────────────────────────────────────
    if [[ -z "${SUDO_PASS:-}" ]]; then
      sudo -n bash -c "$cmd"
    else
      printf '%s\n' "$SUDO_PASS" | sudo -S bash -c "$cmd" 2>/dev/null
    fi
  else
    # ── Remote: run as root via sudo over SSH — never opens a tty ────────────
    # kubeadm join, hostname changes, and similar commands all require root.
    # Use the same NOPASSWD / printf|sudo -S pattern as scp_and_run's wrapper.
    if [[ -z "${SUDO_PASS:-}" ]]; then
      ssh_exec "$host" "sudo -n bash -c $(printf '%q' "$cmd")"
    else
      local escaped_pw
      escaped_pw=$(printf '%q' "$SUDO_PASS")
      ssh_exec "$host" \
        "printf '%s\n' ${escaped_pw} | sudo -S bash -c $(printf '%q' "$cmd") 2>/dev/null"
    fi
  fi
}

# run_script_on HOST LOCAL_SCRIPT — run a local script file on HOST as root.
# Local: executes the script directly with sudo bash, tee output to log
# Remote: delegates to scp_and_run (upload wrapper + sudo execution)
run_script_on() {
  local host="$1"
  local script="$2"

  if is_local_node "$host"; then
    info "[${host}] Running $(basename "$script") locally as root..."
    chmod 600 "$script"
    local rc=0
    if [[ -z "${SUDO_PASS:-}" ]]; then
      # NOPASSWD path — full output to terminal and log file
      sudo -n bash "$script" 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
    else
      # Password path — feed password to sudo via stdin, let script output flow
      # grep -v filters only sudo's own "[sudo] password" prompt from stderr;
      # all actual script stdout/stderr is preserved and logged.
      printf '%s\n' "$SUDO_PASS" \
        | sudo -S bash "$script" 2>&1 \
        | grep -v '^\[sudo\]' \
        | tee -a "$LOG_FILE"
      rc=${PIPESTATUS[1]}   # exit code of sudo, not grep or tee
    fi
    if (( rc != 0 )); then
      error "[${host}] Local script $(basename "$script") failed (exit ${rc}). See ${LOG_FILE} for details."
      return $rc
    fi
    log "[${host}] $(basename "$script") completed successfully (local)."
  else
    scp_and_run "$host" "$script"
  fi
}

# fetch_file_from HOST REMOTE_PATH LOCAL_PATH — copy a file from HOST to local.
# Local: plain cp
# Remote: scp
fetch_file_from() {
  local host="$1"
  local remote_path="$2"
  local local_path="$3"

  if is_local_node "$host"; then
    cp -f "$remote_path" "$local_path"
  else
    scp -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${host}:${remote_path}" \
        "$local_path"
  fi
}
# ──────────────────────────────────────────────────────────────────────────────
setup_ssh_keys() {
  section "Step 1 — Passwordless SSH"

  if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    info "Generating SSH key pair at ${SSH_KEY_PATH}"
    ssh-keygen -t rsa -b 4096 -N "" -C "k8s-cluster-installer" -f "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"
  else
    info "SSH key already exists at ${SSH_KEY_PATH}"
  fi

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    if is_local_node "$node"; then
      info "Skipping SSH key copy for local node ${node}."
      continue
    fi
    info "Copying public key to ${node}..."
    ssh-copy-id -i "${SSH_KEY_PATH}.pub" \
      -o StrictHostKeyChecking=no \
      "${SSH_USER}@${node}" 2>&1 | tee -a "$LOG_FILE" || {
        error "Failed to copy SSH key to ${node}. Ensure the node is reachable and password auth is enabled."
        exit 1
      }
    ssh_exec "$node" "echo 'SSH OK from $(hostname)'" && log "Passwordless SSH verified for ${node}"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 2 — Common node preparation (runs on every node)
# ──────────────────────────────────────────────────────────────────────────────
generate_node_prep_script() {
  # Note: single-quoted heredoc (<<'NODEPREP') — no local variable expansion.
  # $(dpkg --print-architecture) and $(lsb_release -cs) expand on the REMOTE node.
  cat <<'NODEPREP'
#!/usr/bin/env bash
# =============================================================================
# node_prep.sh — Kubernetes node preparation for Ubuntu 24.04
# Runs as root on each cluster node via scp_and_run
# =============================================================================
set -euo pipefail

# ── Error trap: print the failing line number before exiting ─────────────────
trap 'echo "[node-prep] ERROR on line ${LINENO} — exit code ${?}" >&2' ERR

# ── Fully non-interactive apt — prevents ALL interactive prompts ──────────────
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
APT_OPTS=(
  -y -qq
  -o Dpkg::Options::="--force-confdef"
  -o Dpkg::Options::="--force-confold"
  -o APT::Get::Assume-Yes=true
  -o APT::Get::Show-Upgraded=false
)

step() { echo ""; echo "[node-prep] ── ${*} ──────────────────────────────"; }

# ── Robust apt-get update with clock-skew and transient failure handling ──────
# "Release file is not valid yet" = system clock is behind the mirror.
# We fix the clock with chrony/ntp, then retry with Acquire::Check-Valid-Until=false
# as a fallback so a minor skew never blocks the install.
apt_update_safe() {
  local attempts=3
  local delay=15

  # Sync clock first — eliminates the "not valid yet" error in most cases
  if command -v chronyc &>/dev/null; then
    chronyc makestep 2>/dev/null || true
  elif command -v ntpdate &>/dev/null; then
    ntpdate -u pool.ntp.org 2>/dev/null || true
  else
    # Install and run chrony if nothing is available
    apt-get install -y -qq chrony 2>/dev/null || true
    chronyc makestep 2>/dev/null || true
  fi

  local i=1
  while (( i <= attempts )); do
    echo "[node-prep] apt-get update (attempt ${i}/${attempts})..."
    # Acquire::Check-Valid-Until=false tolerates mirrors whose Release file
    # timestamp is ahead of our system clock by a small amount
    if apt-get update -qq \
        -o Acquire::Check-Valid-Until=false \
        -o Acquire::Retries=3 \
        2>&1 | grep -v "^$"; then
      echo "[node-prep] apt cache updated successfully."
      return 0
    fi
    warn_apt=$?
    echo "[node-prep] apt-get update attempt ${i} failed (exit ${warn_apt}), retrying in ${delay}s..."
    sleep $delay
    delay=$(( delay * 2 ))   # exponential back-off: 15s, 30s, 60s
    i=$(( i + 1 ))
  done

  echo "[node-prep] WARNING: apt-get update failed after ${attempts} attempts — continuing anyway." >&2
  return 0   # never block the install over an apt cache issue
}

# ── 1. Package updates ────────────────────────────────────────────────────────
step "Updating apt cache"
apt_update_safe

step "Upgrading installed packages"
apt-get upgrade "${APT_OPTS[@]}" \
  -o Acquire::Check-Valid-Until=false || true

step "Installing prerequisites"
apt-get install "${APT_OPTS[@]}" \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  nfs-common \
  open-iscsi \
  jq \
  htop \
  vim \
  net-tools \
  unzip \
  socat \
  conntrack \
  ipvsadm \
  ipset

# ── 2. Disable swap ───────────────────────────────────────────────────────────
step "Disabling swap"
swapoff -a
# Remove any swap entries from /etc/fstab (idempotent)
sed -i.bak '/[[:space:]]swap[[:space:]]/d' /etc/fstab
echo "[node-prep] Swap disabled."

# ── 3. Kernel modules ─────────────────────────────────────────────────────────
step "Loading required kernel modules"
modprobe overlay
modprobe br_netfilter

# Persist across reboots
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
echo "[node-prep] Kernel modules loaded and persisted."

# ── 4. Sysctl — networking parameters for Kubernetes ─────────────────────────
step "Applying sysctl settings"
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
# Required for iptables-based k8s networking
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Increase inotify limits for kubelet file watchers
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
# Required for Elasticsearch / OpenSearch workloads
vm.max_map_count                    = 262144
# Connection tracking table size
net.netfilter.nf_conntrack_max      = 1048576
EOF
sysctl --system -q
echo "[node-prep] Sysctl applied."

# ── 5. containerd ─────────────────────────────────────────────────────────────
step "Installing containerd"

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker apt repository
# Note: uses $(...) which expands correctly on the remote at runtime
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install "${APT_OPTS[@]}" containerd.io

# ── 5a. Configure containerd ──────────────────────────────────────────────────
step "Configuring containerd"

# Generate default config (overwrites any existing one)
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup — required when kubelet uses systemd cgroup driver
if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  echo "[node-prep] containerd: SystemdCgroup set to true."
else
  echo "[node-prep] containerd: SystemdCgroup already true or not found — skipping."
fi

# Ensure sandbox image is set (prevents pull errors on air-gapped setups)
# Uses the default pause image — override if using a private registry
if ! grep -q 'sandbox_image' /etc/containerd/config.toml; then
  sed -i '/\[plugins."io.containerd.grpc.v1.cri"\]/a\  sandbox_image = "registry.k8s.io/pause:3.9"' \
    /etc/containerd/config.toml
fi

systemctl restart containerd
systemctl enable containerd

# Verify containerd is running before proceeding
sleep 2
if ! systemctl is-active --quiet containerd; then
  echo "[node-prep] ERROR: containerd failed to start." >&2
  journalctl -u containerd --no-pager -n 30 >&2
  exit 1
fi
echo "[node-prep] containerd is running."

# ── 6. Verify critical tools are available ────────────────────────────────────
step "Verifying installation"
for cmd in curl gpg modprobe sysctl containerd; do
  if command -v "$cmd" &>/dev/null; then
    echo "[node-prep]   ✔  ${cmd}"
  else
    echo "[node-prep]   ✖  ${cmd} NOT FOUND" >&2
    exit 1
  fi
done

echo ""
echo "[node-prep] ══════════════════════════════════════════════"
echo "[node-prep]   Node preparation complete on $(hostname)"
echo "[node-prep] ══════════════════════════════════════════════"
NODEPREP
}

prepare_all_nodes() {
  section "Step 2 — Common Node Preparation"
  local prep_script="/tmp/node_prep_$$.sh"

  generate_node_prep_script > "$prep_script"
  # 600: owner read/write only — scp_and_run no longer overrides this.
  # sudo bash on the remote only needs read access (root always has it).
  chmod 600 "$prep_script"

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    info "Preparing node ${node}..."
    run_script_on "$node" "$prep_script" || {
      error "Node preparation failed on ${node}. Check ${LOG_FILE} for details."
      rm -f "$prep_script"
      exit 1
    }
    log "Node ${node} prepared successfully."
  done
  rm -f "$prep_script"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — NVIDIA Driver Installation
#
# Reboot sequence:
#   Phase 1 (pre-reboot)  — blacklist nouveau, install driver package + Fabric
#                           Manager, write a sentinel file, then reboot
#   reboot_and_wait       — issues reboot, waits for SSH to go down then come
#                           back up, then waits for the OS to be fully ready
#   Phase 2 (post-reboot) — verify nvidia-smi, install container toolkit,
#                           configure containerd/docker runtimes, enable
#                           persistence daemon, report MIG availability
#
# Supported driver branches (as of March 2026):
#
#  Branch   │ Type        │ Target hardware
#  ─────────┼─────────────┼────────────────────────────────────────────────────
#   590      │ Proprietary │ LATEST — RTX 50xx, GB200/B200/B100 (Blackwell), H200
#   580      │ Proprietary │ RTX 50xx, Blackwell, H200 — previous latest
#   570      │ Proprietary │ RTX 50xx, Blackwell, H200 — stable
#   565      │ Proprietary │ RTX 40xx, A/H series — stable
#   560      │ Proprietary │ RTX 40xx, A/H series — previous stable
#   550      │ Proprietary │ LTS — Ampere/Hopper/Lovelace, widely deployed
#   535      │ Proprietary │ LTS — Ampere DataCenter (A100/A30/A10)
#   525      │ Proprietary │ Legacy LTS — older Ampere
#   590-open │ Open kernel │ Blackwell, RTX 50xx, Hopper — REQUIRED for GB200
#   580-open │ Open kernel │ Blackwell, RTX 50xx, Hopper
#   570-open │ Open kernel │ RTX 40xx+, Hopper+, Blackwell
#   565-open │ Open kernel │ RTX 40xx, Hopper
#   550-open │ Open kernel │ Ampere+, Hopper — LTS open branch
#
# NOTE: Open kernel modules (nvidia-driver-*-open) are recommended by NVIDIA
# for Turing (RTX 20xx) and later. They are REQUIRED for GB200/Blackwell NVL.
# ──────────────────────────────────────────────────────────────────────────────

# ── NVIDIA Phase 1: Install driver packages then signal for reboot ────────────
generate_nvidia_install_script() {
  local driver_ver="$1"
  local open_kernel="${2:-false}"
  local install_fabric_mgr="${3:-auto}"
  local pkg_suffix=""
  [[ "$open_kernel" == "true" ]] && pkg_suffix="-open"

  cat <<NVIDIAINSTALL
#!/usr/bin/env bash
# NVIDIA Phase 1 — driver install (pre-reboot)
# Branch: ${driver_ver}${pkg_suffix:+ (open kernel)}
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── 1. GPU presence re-check (defensive — caller already verified) ────────────
echo "[nvidia-install] Verifying NVIDIA GPU presence..."
if ! command -v lspci &>/dev/null; then
  apt-get install -y -qq pciutils
fi
if ! lspci | grep -qi nvidia; then
  echo "[nvidia-install] WARNING: No NVIDIA GPU found — nothing to install."
  exit 0
fi
GPU_NAME=\$(lspci | grep -i nvidia | head -1)
echo "[nvidia-install] Confirmed: \${GPU_NAME}"

# ── 2. Blacklist nouveau ───────────────────────────────────────────────────────
echo "[nvidia-install] Blacklisting nouveau driver..."
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BEOF'
blacklist nouveau
options nouveau modeset=0
BEOF
update-initramfs -u -k all 2>/dev/null || true

# ── 3. Add graphics-drivers PPA ───────────────────────────────────────────────
echo "[nvidia-install] Adding graphics-drivers PPA..."
apt-get install -y -qq software-properties-common
add-apt-repository -y ppa:graphics-drivers/ppa
apt-get update -qq

# ── 4. Install driver package ─────────────────────────────────────────────────
DRIVER_PKG="nvidia-driver-${driver_ver}${pkg_suffix}"
UTILS_PKG="nvidia-utils-${driver_ver}"
echo "[nvidia-install] Installing \${DRIVER_PKG} and \${UTILS_PKG}..."
apt-get install -y -qq "\${DRIVER_PKG}" "\${UTILS_PKG}"

# ── 5. Fabric Manager (NVLink / NVSwitch systems) ─────────────────────────────
INSTALL_FM="${install_fabric_mgr}"
if [[ "\${INSTALL_FM}" == "auto" ]]; then
  if lspci | grep -qiE 'NVSwitch|NVLink|SXM'; then
    INSTALL_FM="true"
    echo "[nvidia-install] NVSwitch/SXM detected — will install Fabric Manager."
  else
    INSTALL_FM="false"
  fi
fi

if [[ "\${INSTALL_FM}" == "true" ]]; then
  echo "[nvidia-install] Installing nvidia-fabricmanager-${driver_ver}..."
  apt-get install -y -qq nvidia-fabricmanager-${driver_ver}
  # Enable but do NOT start yet — GPU module not loaded until after reboot
  systemctl enable nvidia-fabricmanager
  echo "[nvidia-install] Fabric Manager enabled (will start after reboot)."
fi

echo "[nvidia-install] Driver packages installed. Node will now be rebooted by the installer."
NVIDIAINSTALL
}

# ── NVIDIA Phase 2: Post-reboot verification + container toolkit ──────────────
generate_nvidia_postboot_script() {
  local driver_ver="$1"

  cat <<'NVIDIAPOST'
#!/usr/bin/env bash
# NVIDIA Phase 2 — post-reboot verification and container toolkit setup
# Phase 2 only runs on nodes where GPU was detected and Phase 1 succeeded.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── 1. Wait for dkms to finish building the kernel module ─────────────────────
# Ubuntu 24.04 installs drivers via dkms. After reboot, dkms may still be
# compiling the .ko — nvidia-smi will fail with "No devices found" until done.
echo "[nvidia-post] Checking dkms build status..."
DKMS_WAITED=0
DKMS_MAX=300
while (( DKMS_WAITED < DKMS_MAX )); do
  if pgrep -x dkms &>/dev/null; then
    echo "[nvidia-post] dkms still building (${DKMS_WAITED}s elapsed)..."
    sleep 10; DKMS_WAITED=$(( DKMS_WAITED + 10 ))
  else
    break
  fi
done
echo "[nvidia-post] dkms status:"
dkms status 2>/dev/null || true

# ── 2. Load the nvidia kernel module ─────────────────────────────────────────
# The module may not auto-load on first boot after install; force it here.
echo "[nvidia-post] Loading nvidia kernel modules..."
modprobe nvidia       || true
modprobe nvidia_uvm   || true
modprobe nvidia_drm   || true
modprobe nvidia_modeset || true
echo "[nvidia-post] Loaded modules: $(lsmod | grep -o '^nvidia[^ ]*' | tr '\n' ' ' || echo none)"

# ── 3. Verify nvidia-smi (up to 3 min) ───────────────────────────────────────
echo "[nvidia-post] Verifying nvidia-smi..."
SMI_OK=false
for i in $(seq 1 12); do
  if /usr/bin/nvidia-smi &>/dev/null; then
    SMI_OK=true
    echo "[nvidia-post] nvidia-smi succeeded on attempt ${i}."
    /usr/bin/nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    break
  fi
  echo "[nvidia-post] nvidia-smi not ready (attempt ${i}/12) — retrying in 15s..."
  sleep 15
  modprobe nvidia 2>/dev/null || true
done

if [[ "$SMI_OK" != "true" ]]; then
  echo "[nvidia-post] ─────────────── DIAGNOSTICS ───────────────" >&2
  echo "--- lsmod | nvidia ---" >&2
  lsmod | grep -i nvidia >&2 || echo "(no nvidia modules loaded)" >&2
  echo "--- dkms status ---" >&2
  dkms status 2>/dev/null >&2 || true
  echo "--- dmesg (nvidia/nvrm) ---" >&2
  dmesg | grep -iE "nvrm|nvidia|modprobe" | tail -40 >&2
  echo "--- /proc/driver/nvidia/version ---" >&2
  cat /proc/driver/nvidia/version 2>/dev/null || echo "(not present)" >&2
  echo "[nvidia-post] ────────────────────────────────────────────" >&2
  echo "[nvidia-post] ERROR: nvidia-smi failed after 3 min. See diagnostics above." >&2
  exit 1
fi

# ── 4. Start Fabric Manager if installed ──────────────────────────────────────
if systemctl list-unit-files | grep -q nvidia-fabricmanager; then
  echo "[nvidia-post] Starting Fabric Manager..."
  systemctl enable --now nvidia-fabricmanager
  if systemctl is-active --quiet nvidia-fabricmanager; then
    echo "[nvidia-post] Fabric Manager is running."
  else
    echo "[nvidia-post] WARNING: Fabric Manager failed to start." >&2
    journalctl -u nvidia-fabricmanager --no-pager -n 20 >&2
  fi
fi

# ── 5. Install NVIDIA Container Toolkit ───────────────────────────────────────
echo "[nvidia-post] Installing NVIDIA Container Toolkit..."
install -m 0755 -d /etc/apt/keyrings
# --batch --yes makes this idempotent if the keyring file already exists
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --batch --yes --dearmor \
      -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
chmod 644 /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit

# ── 6. Configure container runtimes ───────────────────────────────────────────
echo "[nvidia-post] Configuring containerd for NVIDIA runtime..."
nvidia-ctk runtime configure --runtime=containerd
systemctl restart containerd
sleep 3
if ! systemctl is-active --quiet containerd; then
  echo "[nvidia-post] ERROR: containerd failed to restart." >&2
  journalctl -u containerd --no-pager -n 20 >&2
  exit 1
fi

if command -v docker &>/dev/null; then
  echo "[nvidia-post] Configuring Docker for NVIDIA runtime..."
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker 2>/dev/null || true
fi

# ── 7. Enable persistence daemon ──────────────────────────────────────────────
if systemctl list-unit-files | grep -q nvidia-persistenced; then
  systemctl enable --now nvidia-persistenced 2>/dev/null || true
  echo "[nvidia-post] Persistence daemon enabled."
fi

# ── 8. MIG informational report ───────────────────────────────────────────────
if /usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null \
    | grep -q "Enabled\|Disabled"; then
  MIG_STATE=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader | head -1)
  echo "[nvidia-post] MIG-capable GPU detected. Current MIG mode: ${MIG_STATE}"
  echo "[nvidia-post] To enable MIG: nvidia-smi -mig 1  (requires another reboot)"
fi

echo ""
echo "[nvidia-post] ╔══════════════════════════════════════════════════╗"
echo "[nvidia-post] ║  NVIDIA driver fully activated.                  ║"
echo "[nvidia-post] ║  Container toolkit configured.                   ║"
echo "[nvidia-post] ║  Verify with: nvidia-smi                         ║"
echo "[nvidia-post] ╚══════════════════════════════════════════════════╝"
NVIDIAPOST
}

# ── reboot_and_wait: reboot a node and block until SSH and OS are ready ───────
reboot_and_wait() {
  local host="$1"
  local timeout="${2:-300}"   # seconds to wait for node to come back (default 5 min)
  local poll_interval=10

  info "[${host}] Issuing reboot..."

  # Issue reboot via sudo; use '|| true' because the SSH connection will be
  # forcibly closed by the OS as it shuts down — that's expected, not an error.
  if [[ -z "${SUDO_PASS:-}" ]]; then
    ssh_exec "$host" "sudo -n shutdown -r now" 2>/dev/null || true
  else
    local escaped_pw
    escaped_pw=$(printf '%q' "$SUDO_PASS")
    ssh_exec "$host" \
      "printf '%s\n' ${escaped_pw} | sudo -S shutdown -r now 2>/dev/null" \
      2>/dev/null || true
  fi

  # ── Phase A: wait for SSH to go DOWN (node is rebooting) ─────────────────
  info "[${host}] Waiting for node to go offline..."
  local elapsed=0
  local went_down=false
  while (( elapsed < 60 )); do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    # If SSH connection is refused or times out, the node is rebooting
    if ! ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o ConnectTimeout=5 \
             -o BatchMode=yes \
             "${SSH_USER}@${host}" "true" &>/dev/null; then
      went_down=true
      info "[${host}] Node is down (offline after ${elapsed}s). Waiting for it to come back..."
      break
    fi
  done

  if ! $went_down; then
    warn "[${host}] Node did not go offline within 60s — it may have rebooted too quickly. Continuing..."
  fi

  # ── Phase B: wait for SSH to come back UP ────────────────────────────────
  info "[${host}] Polling for SSH availability (timeout: ${timeout}s)..."
  elapsed=0
  while (( elapsed < timeout )); do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    if ssh -i "$SSH_KEY_PATH" \
           -o StrictHostKeyChecking=no \
           -o ConnectTimeout=8 \
           -o BatchMode=yes \
           "${SSH_USER}@${host}" "true" &>/dev/null; then
      info "[${host}] SSH is back (${elapsed}s after reboot command)."
      break
    fi
    info "[${host}] Still waiting... (${elapsed}s / ${timeout}s)"
    if (( elapsed >= timeout )); then
      error "[${host}] Timed out waiting for node to come back after ${timeout}s."
      return 1
    fi
  done

  # ── Phase C: wait for systemd to reach multi-user target ─────────────────
  info "[${host}] Waiting for OS to reach multi-user.target..."
  elapsed=0
  while (( elapsed < 120 )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    local state
    state=$(ssh -i "$SSH_KEY_PATH" \
                -o StrictHostKeyChecking=no \
                -o ConnectTimeout=8 \
                -o BatchMode=yes \
                "${SSH_USER}@${host}" \
                "systemctl is-system-running 2>/dev/null || echo starting" 2>/dev/null || echo "unavailable")
    case "$state" in
      running|degraded)
        log "[${host}] OS is ready (systemd state: ${state})."
        return 0
        ;;
      starting|initializing|unavailable)
        info "[${host}] OS still starting (${elapsed}s)..."
        ;;
      *)
        info "[${host}] systemd state: ${state} (${elapsed}s)..."
        ;;
    esac
  done

  warn "[${host}] systemd did not reach running state within 120s — proceeding anyway."
  return 0
}

# ── Main NVIDIA orchestration ─────────────────────────────────────────────────
install_nvidia_drivers() {
  section "Step 3 — NVIDIA Driver Installation"
  if [[ "${INSTALL_NVIDIA}" != "true" ]]; then
    warn "INSTALL_NVIDIA=false — skipping NVIDIA drivers."
    return
  fi

  local open_kernel="${NVIDIA_OPEN_KERNEL:-false}"
  local fabric_mgr="${NVIDIA_FABRIC_MANAGER:-auto}"
  local reboot_timeout="${NVIDIA_REBOOT_TIMEOUT:-300}"  # configurable via conf

  info "Driver branch  : ${NVIDIA_DRIVER_VERSION}"
  info "Open kernel    : ${open_kernel}"
  info "Fabric Manager : ${fabric_mgr}"
  info "Reboot timeout : ${reboot_timeout}s per node"

  # Generate both phase scripts once
  local phase1_script="/tmp/nvidia_phase1_$$.sh"
  local phase2_script="/tmp/nvidia_phase2_$$.sh"

  generate_nvidia_install_script \
    "$NVIDIA_DRIVER_VERSION" "$open_kernel" "$fabric_mgr" > "$phase1_script"
  generate_nvidia_postboot_script \
    "$NVIDIA_DRIVER_VERSION" > "$phase2_script"

  chmod 600 "$phase1_script" "$phase2_script"

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]}"; do
    [[ -z "$node" ]] && continue

    section "  NVIDIA Install — Node ${node}"

    # ── GPU detection — done HERE, before uploading anything ─────────────────
    # Run lspci as SSH_USER (no sudo needed — lspci is world-readable).
    # If lspci is missing, install pciutils first via a quick sudo one-liner,
    # then re-check. We do NOT rely on a sentinel file; the decision is made
    # locally based on the SSH output before any reboot logic is reached.
    info "[${node}] Probing for NVIDIA GPU..."

    # Ensure lspci is available (may not be on minimal Ubuntu cloud images)
    if ! run_on "$node" "command -v lspci" &>/dev/null; then
      info "[${node}] pciutils not found — installing..."
      run_on "$node" "apt-get install -y -qq pciutils" 2>/dev/null || true
    fi

    # lspci output is checked with grep -qi; exit code 1 = no match = no GPU
    if ! run_on "$node" "lspci 2>/dev/null | grep -qi nvidia"; then
      warn "[${node}] No NVIDIA GPU detected — skipping driver install and reboot."
      continue   # <── straight to next node, no Phase 1, no reboot, no Phase 2
    fi

    local gpu_name
    gpu_name=$(run_on "$node" "lspci 2>/dev/null | grep -i nvidia | head -1" 2>/dev/null || echo "unknown")
    log "[${node}] GPU detected: ${gpu_name}"

    # ── Phase 1: install driver packages ─────────────────────────────────────
    info "[${node}] Phase 1 — Installing driver packages..."
    run_script_on "$node" "$phase1_script" || {
      error "NVIDIA Phase 1 failed on ${node}."
      rm -f "$phase1_script" "$phase2_script"
      exit 1
    }
    log "[${node}] Phase 1 complete."

    # ── Reboot — only runs because we confirmed a GPU exists above ────────────
    info "[${node}] Rebooting to load NVIDIA kernel module..."
    reboot_and_wait "$node" "$reboot_timeout" || {
      error "Node ${node} did not come back after reboot. Installation cannot continue."
      rm -f "$phase1_script" "$phase2_script"
      exit 1
    }
    log "[${node}] Node is back online."

    # ── Phase 2: verify nvidia-smi + container toolkit ────────────────────────
    info "[${node}] Phase 2 — Post-reboot verification and container toolkit..."
    run_script_on "$node" "$phase2_script" || {
      error "NVIDIA Phase 2 failed on ${node}. Check nvidia-smi and dmesg on the node."
      rm -f "$phase1_script" "$phase2_script"
      exit 1
    }
    log "[${node}] NVIDIA fully activated and container toolkit configured."
  done

  rm -f "$phase1_script" "$phase2_script"
  section "Step 3 — NVIDIA Installation Complete (all nodes)"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — Install kubeadm / kubelet / kubectl
# ──────────────────────────────────────────────────────────────────────────────
generate_k8s_binaries_script() {
  local k8s_ver="$1"
  cat <<K8SBINEOF
#!/usr/bin/env bash
set -euo pipefail
echo "[k8s-bin] Adding Kubernetes apt repository (v${k8s_ver})..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${k8s_ver}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${k8s_ver}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet
echo "[k8s-bin] Kubernetes binaries installed and held."
K8SBINEOF
}

install_k8s_binaries() {
  section "Step 4 — Kubernetes Binaries (kubeadm / kubelet / kubectl)"
  local bin_script="/tmp/k8s_binaries_$$.sh"
  generate_k8s_binaries_script "$K8S_VERSION" > "$bin_script"
  chmod 700 "$bin_script"   # owner execute; SCP sends readable file to remote

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    info "Installing k8s binaries on ${node}..."
    run_script_on "$node" "$bin_script" || {
      error "k8s binary installation failed on ${node}."
      rm -f "$bin_script"
      exit 1
    }
    log "k8s binaries installed on ${node}."
  done
  rm -f "$bin_script"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — Initialize Control Plane
# ──────────────────────────────────────────────────────────────────────────────
init_control_plane() {
  section "Step 5 — Initializing Control Plane on ${CONTROL_PLANE_IP}"

  # Write the init script to a temp file directly (avoid heredoc-in-$() which
  # strips trailing newlines and can misfire under set -e).
  local init_file="/tmp/cp_init_$$.sh"

  cat > "$init_file" <<INITEOF
#!/usr/bin/env bash
set -euo pipefail

echo "[control-plane] Running kubeadm init..."
kubeadm init \\
  --apiserver-advertise-address=${CONTROL_PLANE_IP} \\
  --pod-network-cidr=${POD_CIDR} \\
  --upload-certs 2>&1

# ── kubectl for root ──────────────────────────────────────────────────────────
echo "[control-plane] Configuring kubectl for root..."
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

# ── kubectl for SSH_USER (if different from root) ─────────────────────────────
SSH_USER_HOME=\$(getent passwd "${SSH_USER}" | cut -d: -f6 2>/dev/null || echo "/home/${SSH_USER}")
if [[ -d "\${SSH_USER_HOME}" && "\${SSH_USER_HOME}" != "/root" ]]; then
  echo "[control-plane] Configuring kubectl for ${SSH_USER} in \${SSH_USER_HOME}..."
  mkdir -p "\${SSH_USER_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "\${SSH_USER_HOME}/.kube/config"
  chown ${SSH_USER}:${SSH_USER} "\${SSH_USER_HOME}/.kube/config"
  chmod 600 "\${SSH_USER_HOME}/.kube/config"
fi

# ── Join command for workers ───────────────────────────────────────────────────
echo "[control-plane] Generating join command..."
kubeadm token create --print-join-command > /tmp/k8s_join_command.txt
chmod 644 /tmp/k8s_join_command.txt
echo "[control-plane] Init complete."
INITEOF

  chmod 600 "$init_file"
  run_script_on "$CONTROL_PLANE_IP" "$init_file" || {
    error "kubeadm init failed on ${CONTROL_PLANE_IP}. Check the log above for details."
    rm -f "$init_file"
    exit 1
  }
  rm -f "$init_file"

  # ── Fetch kubeconfig to wherever kubectl runs on this installer machine ───────
  # Script always runs as root, so kubeconfig lives at /root/.kube/config.
  local local_kube_dir="/root/.kube"
  mkdir -p "$local_kube_dir"

  if is_local_node "$CONTROL_PLANE_IP"; then
    # kubeconfig is already at /root/.kube/config (written by init script as root)
    if [[ "${local_kube_dir}/config" != "/root/.kube/config" ]]; then
      cp -f /root/.kube/config "${local_kube_dir}/config"
      chmod 600 "${local_kube_dir}/config"
    fi
    log "kubeconfig ready at ${local_kube_dir}/config"
  else
    fetch_file_from "$CONTROL_PLANE_IP" \
      "/root/.kube/config" \
      "${local_kube_dir}/config"
    chmod 600 "${local_kube_dir}/config"
    log "kubeconfig fetched to ${local_kube_dir}/config"
  fi

  export KUBECONFIG="${local_kube_dir}/config"

  # ── Fetch join command ────────────────────────────────────────────────────────
  # For a local control plane the file is already on this machine — only copy
  # if source and destination differ (cp refuses to copy a file onto itself).
  local join_src="/tmp/k8s_join_command.txt"
  local join_dst="/tmp/k8s_join_command.txt"
  if is_local_node "$CONTROL_PLANE_IP"; then
    log "Join command already at ${join_dst} (local control plane)."
  else
    fetch_file_from "$CONTROL_PLANE_IP" "$join_src" "$join_dst"
    log "Join command fetched to ${join_dst}"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 6 — Install CNI Plugin
# ──────────────────────────────────────────────────────────────────────────────
install_cni() {
  section "Step 6 — Installing CNI Plugin (${CNI_PLUGIN})"
  export KUBECONFIG="/root/.kube/config"

  if [[ "$CNI_PLUGIN" == "flannel" ]]; then
    kubectl apply -f \
      https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  elif [[ "$CNI_PLUGIN" == "calico" ]]; then
    kubectl apply -f \
      https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
  else
    error "Unknown CNI plugin: ${CNI_PLUGIN}. Choose flannel or calico."
    exit 1
  fi
  log "CNI plugin ${CNI_PLUGIN} applied."
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 7 — Join Worker Nodes
# ──────────────────────────────────────────────────────────────────────────────
join_workers() {
  section "Step 7 — Joining Worker Nodes"
  if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
    warn "No worker nodes defined — skipping join step."
    return
  fi

  local join_cmd
  join_cmd=$(cat /tmp/k8s_join_command.txt)

  for worker in "${WORKER_IPS[@]}"; do
    info "Joining worker ${worker}..."
    run_on "$worker" "${join_cmd}"
    log "Worker ${worker} joined the cluster."
  done

  # ── Wait for all nodes (control-plane + workers) to reach Ready ──────────────
  # Expected total = 1 control plane + number of workers
  local expected_nodes=$(( 1 + ${#WORKER_IPS[@]} ))
  local wait_timeout=300   # 5 min — allows time for CNI pod scheduling
  info "Waiting for all ${expected_nodes} nodes to be Ready (timeout: ${wait_timeout}s)..."

  # kubectl wait is the correct tool — it watches the API directly.
  # --for=condition=Ready covers both control-plane and worker nodes.
  if kubectl wait node \
       --all \
       --for=condition=Ready \
       --timeout="${wait_timeout}s" \
       2>/dev/null; then
    log "All nodes are Ready."
  else
    # kubectl wait timed out or failed — fall back to a manual poll that
    # correctly distinguishes Ready from NotReady using exact field matching.
    warn "kubectl wait timed out — checking node status manually..."
    local elapsed=0
    local poll=10
    local all_ready=false
    while (( elapsed < wait_timeout )); do
      # Count nodes whose STATUS column is exactly "Ready" (not "NotReady")
      # awk field $2 is the STATUS column in 'kubectl get nodes --no-headers'
      local ready_count not_ready_count
      ready_count=$(kubectl get nodes --no-headers 2>/dev/null \
        | awk '$2 == "Ready" {count++} END {print count+0}')
      not_ready_count=$(kubectl get nodes --no-headers 2>/dev/null \
        | awk '$2 != "Ready" {count++} END {print count+0}')

      info "Nodes ready: ${ready_count}/${expected_nodes} | Not ready: ${not_ready_count}"

      if (( ready_count >= expected_nodes && not_ready_count == 0 )); then
        all_ready=true
        break
      fi
      sleep $poll
      elapsed=$(( elapsed + poll ))
    done

    if $all_ready; then
      log "All ${expected_nodes} nodes are Ready."
    else
      warn "Timed out after ${wait_timeout}s — ${ready_count}/${expected_nodes} nodes Ready. Proceeding anyway."
      warn "Run 'kubectl get nodes' to check cluster state."
    fi
  fi

  kubectl get nodes
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 8 — Install Helm
# ──────────────────────────────────────────────────────────────────────────────
install_helm() {
  section "Step 8 — Installing Helm ${HELM_VERSION}"

  if command -v helm &>/dev/null; then
    warn "Helm already installed: $(helm version --short)"
    return
  fi

  local helm_tar="/tmp/helm-v${HELM_VERSION}.tar.gz"
  local arch
  arch=$(dpkg --print-architecture)
  curl -fsSL \
    "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" \
    -o "$helm_tar"
  tar -zxf "$helm_tar" -C /tmp
  install -o root -g root -m 0755 "/tmp/linux-${arch}/helm" /usr/local/bin/helm
  rm -rf "$helm_tar" "/tmp/linux-${arch}"
  log "Helm $(helm version --short) installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 9 — Prometheus + Grafana (kube-prometheus-stack)
#
# Storage class resolution order:
#   1. NFS StorageClass (NFS_STORAGE_CLASS) — if NFS was installed
#   2. Cluster default StorageClass        — if one exists
#   3. Empty string                        — rely on cluster default annotation
#      (Helm will still create PVCs; they may pend if no default SC exists)
#
# The Prometheus PVC is pre-created before Helm runs so the provisioner has
# time to bind it — avoids the pod staying in Pending indefinitely.
# ──────────────────────────────────────────────────────────────────────────────
install_monitoring() {
  section "Step 10 — Prometheus & Grafana (kube-prometheus-stack)"
  export KUBECONFIG="/root/.kube/config"

  if [[ "${INSTALL_MONITORING}" != "true" ]]; then
    warn "INSTALL_MONITORING=false — skipping monitoring stack."
    return
  fi

  # ── Resolve which StorageClass to use ─────────────────────────────────────
  local storage_class=""

  if [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_STORAGE_CLASS:-}" ]]; then
    # Verify the NFS StorageClass actually exists before using it
    if kubectl get storageclass "${NFS_STORAGE_CLASS}" &>/dev/null; then
      storage_class="$NFS_STORAGE_CLASS"
      info "Using NFS StorageClass '${storage_class}' for monitoring PVCs."
    else
      warn "NFS StorageClass '${NFS_STORAGE_CLASS}' not found — falling back to cluster default."
    fi
  fi

  if [[ -z "$storage_class" ]]; then
    # Find the cluster's default StorageClass (annotated with is-default-class=true)
    storage_class=$(kubectl get storageclass \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
      2>/dev/null | awk '$2 == "true" {print $1; exit}')
    if [[ -n "$storage_class" ]]; then
      info "Using cluster default StorageClass '${storage_class}' for monitoring PVCs."
    else
      warn "No default StorageClass found. Monitoring PVCs will pend until one is available."
      warn "Install NFS provisioner or another storage provider, then re-run: --step monitoring"
    fi
  fi

  # ── Pre-create the Prometheus PVC so the provisioner binds it before Helm ──
  # kube-prometheus-stack creates this PVC itself but only after the pod starts,
  # which causes the pod to stay Pending while waiting for the PVC to bind.
  # Creating it here first gives the provisioner a head start.
  kubectl create namespace "$NS_MONITORING" --dry-run=client -o yaml | kubectl apply -f -

  if [[ -n "$storage_class" && -n "${PROM_STORAGE_SIZE:-}" ]]; then
    info "Pre-creating Prometheus PVC (${PROM_STORAGE_SIZE}, StorageClass: ${storage_class})..."
    kubectl apply -f - <<PROMPVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
  namespace: ${NS_MONITORING}
  labels:
    app: kube-prometheus-stack-prometheus
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: ${PROM_STORAGE_SIZE}
PROMPVC

    # Wait up to 60s for the PVC to bind before proceeding
    info "Waiting for Prometheus PVC to bind..."
    if ! kubectl wait pvc \
        --namespace "$NS_MONITORING" \
        --selector='app=kube-prometheus-stack-prometheus' \
        --for=jsonpath='{.status.phase}'=Bound \
        --timeout=60s 2>/dev/null; then
      warn "Prometheus PVC did not bind within 60s — Helm will proceed anyway."
      kubectl get pvc -n "$NS_MONITORING"
    fi
  fi

  # ── Deploy kube-prometheus-stack ───────────────────────────────────────────
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  local sc_flags=()
  if [[ -n "$storage_class" ]]; then
    sc_flags+=(
      --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=${storage_class}"
      --set "grafana.persistence.storageClassName=${storage_class}"
    )
  fi

  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace "$NS_MONITORING" \
    --version "$PROM_STACK_VERSION" \
    --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort="${GRAFANA_NODEPORT}" \
    --set prometheus.service.type=NodePort \
    --set prometheus.service.nodePort="${PROMETHEUS_NODEPORT}" \
    --set alertmanager.service.type=NodePort \
    --set alertmanager.service.nodePort="${ALERTMANAGER_NODEPORT}" \
    --set prometheus.prometheusSpec.retention="${PROM_RETENTION}" \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="${PROM_STORAGE_SIZE}" \
    --set grafana.persistence.enabled=true \
    --set grafana.persistence.size=5Gi \
    "${sc_flags[@]}" \
    --wait --timeout=10m

  log "kube-prometheus-stack deployed in namespace ${NS_MONITORING}."
  info "Grafana:      http://${CONTROL_PLANE_IP}:${GRAFANA_NODEPORT}  (admin / ${GRAFANA_ADMIN_PASSWORD})"
  info "Prometheus:   http://${CONTROL_PLANE_IP}:${PROMETHEUS_NODEPORT}"
  info "Alertmanager: http://${CONTROL_PLANE_IP}:${ALERTMANAGER_NODEPORT}"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 10 — NVIDIA GPU Operator
# ──────────────────────────────────────────────────────────────────────────────
install_gpu_operator() {
  section "Step 11 — NVIDIA GPU Operator"
  export KUBECONFIG="/root/.kube/config"

  if [[ "${INSTALL_NVIDIA}" != "true" ]]; then
    warn "INSTALL_NVIDIA=false — skipping GPU Operator."
    return
  fi
  local has_gpu=false
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    if run_on "$node" "lspci 2>/dev/null | grep -qi nvidia" 2>/dev/null; then
      has_gpu=true; break
    fi
  done

  if [[ "$has_gpu" == "false" ]]; then
    warn "No NVIDIA GPU detected on any node — skipping GPU Operator."
    return
  fi

  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
  helm repo update

  kubectl create namespace "$NS_GPU_OPERATOR" --dry-run=client -o yaml | kubectl apply -f -

  # ── Label GPU nodes ───────────────────────────────────────────────────────────
  # Do NOT use 'hostname -s' — Kubernetes registers nodes under whatever name
  # kubelet reports, which may differ from the shell hostname (FQDN vs short,
  # or a custom --node-name passed to kubeadm).  The only reliable source of
  # truth is kubectl itself: match the node's InternalIP to the IP we know.
  for node in "${WORKER_IPS[@]:-}"; do
    [[ -z "$node" ]] && continue
    if run_on "$node" "lspci 2>/dev/null | grep -qi nvidia" 2>/dev/null; then
      # Ask Kubernetes for the node name whose InternalIP matches this worker IP
      local node_name
      node_name=$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}{end}' \
        2>/dev/null \
        | awk -v ip="$node" '$2=="InternalIP" && $3==ip {print $1; exit}')

      if [[ -z "$node_name" ]]; then
        warn "Could not find Kubernetes node name for IP ${node} — skipping GPU label."
        warn "Run: kubectl get nodes -o wide   to verify the node registered correctly."
        continue
      fi

      kubectl label node "$node_name" nvidia.com/gpu.present=true --overwrite
      info "Labeled GPU node: ${node_name} (${node})"
    fi
  done

  helm upgrade --install gpu-operator \
    nvidia/gpu-operator \
    --namespace "$NS_GPU_OPERATOR" \
    --set driver.enabled=false \
    --set toolkit.enabled=true \
    --set devicePlugin.enabled=true \
    --set dcgmExporter.enabled=true \
    --set dcgmExporter.serviceMonitor.enabled=true \
    --set dcgmExporter.serviceMonitor.additionalLabels.release=kube-prometheus-stack \
    --wait --timeout=15m

  log "NVIDIA GPU Operator deployed in namespace ${NS_GPU_OPERATOR}."
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 9 — NFS External Provisioner
# ──────────────────────────────────────────────────────────────────────────────
install_nfs_provisioner() {
  section "Step 9 — NFS External Provisioner"
  export KUBECONFIG="/root/.kube/config"

  if [[ "${INSTALL_NFS}" != "true" ]]; then
    warn "INSTALL_NFS=false — skipping NFS provisioner."
    return
  fi

  if [[ -z "${NFS_SERVER_IP:-}" ]]; then
    warn "NFS_SERVER_IP not configured — skipping NFS provisioner."
    return
  fi

  # ── Step A: Install nfs-common on every cluster node ─────────────────────────
  # The provisioner pod mounts NFS volumes on whichever node it's scheduled on.
  # Without nfs-common the mount syscall fails and the pod hangs → deadline exceeded.
  info "Installing nfs-common on all cluster nodes..."
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    info "  Installing nfs-common on ${node}..."
    run_on "$node" \
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common 2>&1" || {
        warn "nfs-common install may have failed on ${node} — continuing."
      }
  done

  # ── Step B: Configure NFS server export (if server is a managed node) ────────
  if [[ "$NFS_SERVER_IP" == "$CONTROL_PLANE_IP" ]] || \
     printf '%s\n' "${WORKER_IPS[@]:-}" | grep -q "^${NFS_SERVER_IP}$"; then
    info "Configuring NFS export on ${NFS_SERVER_IP}..."

    local nfs_setup_script="/tmp/nfs_server_setup_$$.sh"
    cat > "$nfs_setup_script" <<NFSSCRIPT
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq nfs-kernel-server

# Create and permission the export directory
mkdir -p "${NFS_PATH}"
chown nobody:nogroup "${NFS_PATH}"
chmod 755 "${NFS_PATH}"

# Add export entry if not already present
if ! grep -qF "${NFS_PATH}" /etc/exports; then
  echo "${NFS_PATH} *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
fi

exportfs -ra
systemctl enable --now nfs-kernel-server

# Verify the export is live before returning
sleep 2
if showmount -e localhost 2>/dev/null | grep -q "${NFS_PATH}"; then
  echo "[nfs-server] Export verified: ${NFS_PATH}"
else
  echo "[nfs-server] WARNING: export not showing in showmount — check /etc/exports" >&2
fi
NFSSCRIPT
    chmod 600 "$nfs_setup_script"
    run_script_on "$NFS_SERVER_IP" "$nfs_setup_script" || {
      error "NFS server setup failed on ${NFS_SERVER_IP}."
      rm -f "$nfs_setup_script"
      exit 1
    }
    rm -f "$nfs_setup_script"
    log "NFS export configured on ${NFS_SERVER_IP}."
  else
    info "NFS server ${NFS_SERVER_IP} is external — ensure ${NFS_PATH} is already exported."
  fi

  # ── Step C: Verify NFS server is reachable from the installer machine ─────────
  info "Verifying NFS server ${NFS_SERVER_IP} is reachable..."
  if command -v showmount &>/dev/null; then
    if showmount -e "$NFS_SERVER_IP" 2>/dev/null | grep -q "${NFS_PATH}"; then
      log "NFS export ${NFS_PATH} confirmed reachable on ${NFS_SERVER_IP}."
    else
      warn "Cannot verify NFS export via showmount — check firewall rules on ${NFS_SERVER_IP}."
      warn "Required ports: 2049/tcp (NFS), 111/tcp+udp (portmapper)."
      warn "Continuing — provisioner pod may fail to start if NFS is unreachable."
    fi
  fi

  # ── Step D: Deploy Helm chart ─────────────────────────────────────────────────
  helm repo add nfs-subdir-external-provisioner \
    https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_NFS" --dry-run=client -o yaml | kubectl apply -f -

  # Deploy without --wait first so we can inspect pod state on failure
  helm upgrade --install nfs-subdir-external-provisioner \
    nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace "$NS_NFS" \
    --set nfs.server="${NFS_SERVER_IP}" \
    --set nfs.path="${NFS_PATH}" \
    --set storageClass.name="${NFS_STORAGE_CLASS}" \
    --set storageClass.defaultClass="${NFS_DEFAULT_SC}" \
    --set storageClass.reclaimPolicy=Retain \
    --set storageClass.archiveOnDelete=false

  # ── Step E: Wait for provisioner pod to be Running ───────────────────────────
  info "Waiting for NFS provisioner pod to become Ready (up to 5m)..."
  local elapsed=0 pod_ready=false
  while (( elapsed < 300 )); do
    local pod_status
    pod_status=$(kubectl get pods -n "$NS_NFS" \
      -l "app=nfs-subdir-external-provisioner" \
      --no-headers 2>/dev/null | awk '{print $3}' | head -1)

    if [[ "$pod_status" == "Running" ]]; then
      pod_ready=true
      break
    fi

    if [[ "$pod_status" == "CrashLoopBackOff" || "$pod_status" == "Error" ]]; then
      warn "NFS provisioner pod is in ${pod_status} state — printing logs..."
      kubectl logs -n "$NS_NFS" \
        -l "app=nfs-subdir-external-provisioner" --tail=40 2>/dev/null || true
      break
    fi

    info "  Pod status: ${pod_status:-Pending} (${elapsed}s elapsed) — waiting..."
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done

  if $pod_ready; then
    log "NFS provisioner deployed. StorageClass: ${NFS_STORAGE_CLASS} (default: ${NFS_DEFAULT_SC})."
  else
    # Show diagnostics but do NOT exit — monitoring can still deploy
    warn "NFS provisioner pod did not reach Running state after 5m."
    warn "Run these to diagnose:"
    warn "  kubectl get pods -n ${NS_NFS} -o wide"
    warn "  kubectl describe pod -n ${NS_NFS} -l app=nfs-subdir-external-provisioner"
    warn "  kubectl logs -n ${NS_NFS} -l app=nfs-subdir-external-provisioner"
    warn "Common causes: nfs-common missing on nodes, NFS port 2049 blocked, wrong NFS path."
    kubectl get pods -n "$NS_NFS" -o wide 2>/dev/null || true
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 12 — Kubernetes Dashboard v2.7.0
# ──────────────────────────────────────────────────────────────────────────────
install_dashboard() {
  section "Step 12 — Kubernetes Dashboard v${DASHBOARD_VERSION}"
  export KUBECONFIG="/root/.kube/config"

  if [[ "${INSTALL_DASHBOARD}" != "true" ]]; then
    warn "INSTALL_DASHBOARD=false — skipping Kubernetes Dashboard."
    return
  fi

  info "Deploying Kubernetes Dashboard v${DASHBOARD_VERSION}..."

  # Apply the official manifest for the pinned version
  kubectl apply -f \
    "https://raw.githubusercontent.com/kubernetes/dashboard/v${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

  kubectl create namespace "$NS_DASHBOARD" --dry-run=client -o yaml | kubectl apply -f -

  # ── Service Account + ClusterRoleBinding for token login ─────────────────────
  kubectl apply -f - <<DASHSA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: ${NS_DASHBOARD}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: dashboard-admin
  namespace: ${NS_DASHBOARD}
DASHSA

  # ── Patch the kubernetes-dashboard Service to NodePort ────────────────────────
  kubectl patch svc kubernetes-dashboard \
    -n "$NS_DASHBOARD" \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"targetPort\":8443,\"nodePort\":${DASHBOARD_NODEPORT}}]}}"

  # ── Create a long-lived token Secret (k8s 1.24+) ─────────────────────────────
  kubectl apply -f - <<DASHTOK
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-admin-token
  namespace: ${NS_DASHBOARD}
  annotations:
    kubernetes.io/service-account.name: dashboard-admin
type: kubernetes.io/service-account-token
DASHTOK

  # Wait for token to be populated (up to 30s)
  local token="" elapsed=0
  while [[ -z "$token" && $elapsed -lt 30 ]]; do
    token=$(kubectl get secret dashboard-admin-token \
      -n "$NS_DASHBOARD" \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
    sleep 2; elapsed=$(( elapsed + 2 ))
  done

  log "Kubernetes Dashboard deployed in namespace ${NS_DASHBOARD}."
  info "URL:   https://${CONTROL_PLANE_IP}:${DASHBOARD_NODEPORT}"
  if [[ -n "$token" ]]; then
    info "Token: ${token}"
    # Also save to a file so it's not lost from terminal scroll
    echo "$token" > /root/dashboard-token.txt
    chmod 600 /root/dashboard-token.txt
    info "Token also saved to /root/dashboard-token.txt"
  else
    info "Retrieve token later with:"
    info "  kubectl get secret dashboard-admin-token -n ${NS_DASHBOARD} -o jsonpath='{.data.token}' | base64 -d"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 13 — vLLM Production Stack
# ──────────────────────────────────────────────────────────────────────────────
install_vllm() {
  section "Step 13 — vLLM Production Stack"
  export KUBECONFIG="/root/.kube/config"

  if [[ "${INSTALL_VLLM}" != "true" ]]; then
    warn "INSTALL_VLLM=false — skipping vLLM stack."
    return
  fi

  if [[ "${INSTALL_NVIDIA}" != "true" ]]; then
    warn "vLLM requires NVIDIA GPU Operator — INSTALL_NVIDIA=false, skipping vLLM."
    return
  fi

  local gpu_nodes
  gpu_nodes=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
  if (( gpu_nodes == 0 )); then
    warn "No nodes labelled nvidia.com/gpu.present=true — vLLM pods will remain Pending."
  else
    info "Found ${gpu_nodes} GPU node(s) — proceeding with vLLM deployment."
  fi

  kubectl create namespace "$VLLM_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # ── Pre-pull the vLLM images on all GPU nodes ─────────────────────────────
  # Pull directly via containerd on each node using our run_on helper.
  # This avoids scheduling constraints entirely — no DaemonSet, no nodeSelector,
  # no dependency on GPU Operator labels being present.
  # lmcache/vllm-openai is ~10 GB; lmcache/lmstack-router is ~2 GB.
  local vllm_image="docker.io/lmcache/vllm-openai:latest"
  local router_image="docker.io/lmcache/lmstack-router:latest"

  # Collect all nodes that will run vLLM pods: all workers (and control plane
  # if it has a GPU).  We pull on every node — harmless no-op if no GPU there.
  local pull_nodes=()
  for w in "${WORKER_IPS[@]:-}"; do
    [[ -n "$w" ]] && pull_nodes+=("$w")
  done
  # Also pull on control plane in case it hosts GPU workloads
  pull_nodes+=("${CONTROL_PLANE_IP}")

  # Deduplicate
  local seen=()
  local unique_nodes=()
  for n in "${pull_nodes[@]}"; do
    local dup=false
    for s in "${seen[@]:-}"; do [[ "$s" == "$n" ]] && dup=true && break; done
    $dup || { unique_nodes+=("$n"); seen+=("$n"); }
  done

  info "Pre-pulling vLLM images on ${#unique_nodes[@]} node(s)..."
  info "  Engine : ${vllm_image}"
  info "  Router : ${router_image}"
  info "This may take 10-30 minutes on first deploy (images are ~10 GB + ~2 GB)."

  local pull_failed=false
  for node in "${unique_nodes[@]}"; do
    info "  Pulling on ${node}..."
    # ctr is the containerd CLI; it requires the k8s.io namespace
    local pull_cmd="ctr --namespace k8s.io images pull ${vllm_image} && ctr --namespace k8s.io images pull ${router_image}"
    run_on "$node" "$pull_cmd" || {
      warn "Image pull on ${node} failed or timed out — Helm deploy may still work if image is cached."
      pull_failed=true
    }
    log "Images pulled on ${node}."
  done

  if $pull_failed; then
    warn "One or more nodes had pull errors. Proceeding with Helm deploy anyway."
  else
    log "All images pre-pulled successfully."
  fi

  # ── PVC check ──────────────────────────────────────────────────────────────
  if [[ "${VLLM_REUSE_PVC:-false}" == "true" ]]; then
    # Verify the named PVC actually exists before we reference it in values
    if kubectl get pvc "${VLLM_PVC_NAME}" -n "$VLLM_NAMESPACE" &>/dev/null 2>&1; then
      log "Reusing existing PVC '${VLLM_PVC_NAME}' in namespace ${VLLM_NAMESPACE}."
    else
      warn "VLLM_REUSE_PVC=true but PVC '${VLLM_PVC_NAME}' not found in ${VLLM_NAMESPACE}."
      warn "The chart will create a new PVC named '${VLLM_PVC_NAME}' with size ${VLLM_STORAGE_SIZE}."
      VLLM_REUSE_PVC="false"
    fi
  else
    info "Chart will create PVC '${VLLM_PVC_NAME}' (${VLLM_STORAGE_SIZE}) via pvcStorage."
  fi

  # ── Build Helm values ──────────────────────────────────────────────────────
  helm repo add vllm https://vllm-project.github.io/production-stack 2>/dev/null || true
  helm repo update

  # ── Derive a short safe name from the model ID for Kubernetes labels ──────
  # e.g. "meta-llama/Llama-3.2-1B-Instruct" → "llama-3-2-1b-instruct"
  local model_name
  model_name=$(echo "${VLLM_MODEL}" \
    | awk -F'/' '{print $NF}' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-40)

  # ── Build extra args YAML list ────────────────────────────────────────────
  # The chart expects extraArgs as an inline YAML list: ["--arg1", "--arg2"]
  local extra_args_list="[]"
  if [[ -n "${VLLM_EXTRA_ARGS:-}" ]]; then
    extra_args_list="["
    for arg in ${VLLM_EXTRA_ARGS}; do
      extra_args_list+="\"${arg}\", "
    done
    extra_args_list="${extra_args_list%, }]"
  fi

  # ── Probe timing — scaled by GPU count as a proxy for model size ──────────
  # vLLM's HTTP server on :8000 only becomes available AFTER the model is
  # fully loaded into GPU memory.  The startup probe must cover:
  #   • image pull time     (first deploy only, skipped if image is cached)
  #   • model download time (first deploy only, skipped if PVC is warm)
  #   • model load time     (every start — depends on model size and disk speed)
  #
  # Budget = initialDelaySeconds + (failureThreshold × periodSeconds)
  # With failureThreshold=120 and periodSeconds=10 → 20 min window after delay.
  local gpu_count="${VLLM_GPU_COUNT:-1}"
  local engine_init_delay=$(( 30 + gpu_count * 15 ))  # 45s for 1 GPU, 60s for 2, …
  local engine_failure_thresh=120                      # 120 × 10s = 20 min window
  local engine_period=10

  # Router probes check the router's own HTTP port (:8080), NOT the engine.
  # The router starts quickly (it's just a Python proxy); its /health returns
  # 200 even with zero backends registered.  A small startup budget is fine.
  # The router's readiness probe is what controls whether it receives traffic.
  local router_init_delay=10
  local router_failure_thresh=30  # 30 × 10s = 5 min window
  local router_period=10

  local values_file="/tmp/vllm-values-$$.yaml"

  # Write values file line-by-line so optional fields are only emitted when
  # they have content.  A heredoc with empty interpolated variables produces
  # blank lines inside YAML sequence items, which breaks the YAML parser
  # ("did not find expected '-' indicator").
  : > "$values_file"   # create/truncate

  cat >> "$values_file" <<EOF
# vLLM production stack — generated by k8s_cluster_setup.sh
# Model   : ${VLLM_MODEL}
# Engine startup probe budget: ${engine_init_delay}s delay + ${engine_failure_thresh}x${engine_period}s = $(( engine_init_delay + engine_failure_thresh * engine_period ))s total

servingEngineSpec:
  runtimeClassName: ""
  imagePullPolicy: "IfNotPresent"
  dnsPolicy: "ClusterFirst"

  startupProbe:
    initialDelaySeconds: ${engine_init_delay}
    periodSeconds: ${engine_period}
    failureThreshold: ${engine_failure_thresh}
    timeoutSeconds: 5

  livenessProbe:
    initialDelaySeconds: 0
    periodSeconds: 30
    failureThreshold: 3
    timeoutSeconds: 10

  readinessProbe:
    initialDelaySeconds: 0
    periodSeconds: 15
    failureThreshold: 3
    timeoutSeconds: 10

  modelSpec:
    - name: "${model_name}"
      repository: "lmcache/vllm-openai"
      tag: "latest"
      modelURL: "${VLLM_MODEL}"
      replicaCount: 1
      requestCPU: ${VLLM_CPU_REQUEST}
      requestMemory: "${VLLM_MEM_REQUEST}"
      requestGPU: ${VLLM_GPU_COUNT}
      limitCPU: "${VLLM_CPU_LIMIT}"
      limitMemory: "${VLLM_MEM_LIMIT}"
EOF

  # Optional fields — only written when non-empty so no blank lines appear
  # in the middle of the modelSpec sequence item.
  [[ -n "${VLLM_STORAGE_SIZE:-}" && "${VLLM_REUSE_PVC:-false}" != "true" ]] && \
    echo "      pvcStorage: \"${VLLM_STORAGE_SIZE}\"" >> "$values_file"
  [[ -n "${VLLM_PVC_NAME:-}" ]] && \
    echo "      existingClaim: ${VLLM_PVC_NAME}"      >> "$values_file"
  [[ -n "${VLLM_HF_TOKEN:-}" ]] && \
    echo "      hf_token: \"${VLLM_HF_TOKEN}\""       >> "$values_file"

  cat >> "$values_file" <<EOF
      vllmConfig:
        dtype: "${VLLM_DTYPE}"
        maxModelLen: ${VLLM_MAX_MODEL_LEN}
        extraArgs: ${extra_args_list}
      nodeSelectorTerms:
        - matchExpressions:
            - key: nvidia.com/gpu.present
              operator: In
              values:
                - "true"

routerSpec:
  repository: "lmcache/lmstack-router"
  tag: "latest"
  imagePullPolicy: "IfNotPresent"
  startupProbe:
    initialDelaySeconds: ${router_init_delay}
    periodSeconds: ${router_period}
    failureThreshold: ${router_failure_thresh}
    timeoutSeconds: 5

  livenessProbe:
    initialDelaySeconds: 0
    periodSeconds: 30
    failureThreshold: 5
    timeoutSeconds: 10

  readinessProbe:
    initialDelaySeconds: 0
    periodSeconds: 15
    failureThreshold: 5
    timeoutSeconds: 10

  resources:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"

  serviceType: "NodePort"
  serviceNodePort: ${VLLM_NODEPORT}
EOF

  # ── Deploy ─────────────────────────────────────────────────────────────────
  # --wait is intentionally omitted: Helm's --wait enforces readiness within
  # --timeout, which is impossible during a first-time model download because
  # readiness only passes after the startup probe succeeds (which can take
  # 20+ minutes for large models).  We use our own poll loop instead.
  info "Deploying vLLM production stack (model: ${VLLM_MODEL})..."
  helm upgrade --install vllm-stack vllm/vllm-stack \
    --namespace "$VLLM_NAMESPACE" \
    --values "$values_file" \
    --timeout 5m || {
      error "Helm install/upgrade failed — chart rendering or API error."
      warn "Dumping generated values file for diagnosis:"
      cat "$values_file" | tee -a "$LOG_FILE" || true
      rm -f "$values_file"
      exit 1
    }

  rm -f "$values_file"

  # ── Post-deploy readiness poll ─────────────────────────────────────────────
  # Poll for up to 30 minutes.  Print progress every interval.
  # Distinguish "still loading" (normal) from hard failures (actionable).
  local poll_max=1800   # 30 minutes — covers large model downloads
  local poll_interval=20
  local elapsed=0
  local router_ready=false
  local engine_ready=false

  info "Waiting for vLLM pods to become ready (up to $((poll_max/60)) min)..."
  info "Note: first-time model download can take many minutes."

  while (( elapsed < poll_max )); do
    local router_status engine_status
    router_status=$(kubectl get pods -n "$VLLM_NAMESPACE" \
      --no-headers 2>/dev/null | awk '/router/ {print $3; exit}')
    engine_status=$(kubectl get pods -n "$VLLM_NAMESPACE" \
      --no-headers 2>/dev/null | awk '!/router/ && NF>0 {print $3; exit}')

    # Detect hard failures immediately
    local failed_status=""
    for s in "$router_status" "$engine_status"; do
      case "$s" in
        CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|Error)
          failed_status="$s"; break ;;
      esac
    done

    if [[ -n "$failed_status" ]]; then
      error "vLLM pod entered failed state: ${failed_status}"
      kubectl get pods -n "$VLLM_NAMESPACE" | tee -a "$LOG_FILE" || true
      warn "Recent events:"
      kubectl get events -n "$VLLM_NAMESPACE" \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -15 | tee -a "$LOG_FILE" || true
      warn "Deployment left in place for manual diagnosis."
      warn "Router logs:  kubectl logs -n ${VLLM_NAMESPACE} -l app=vllm-stack-router"
      warn "Engine logs:  kubectl logs -n ${VLLM_NAMESPACE} -l app=vllm-stack"
      return 1
    fi

    [[ "$router_status" == "Running" ]] && router_ready=true
    [[ "$engine_status" == "Running" ]] && engine_ready=true

    if $router_ready && $engine_ready; then
      log "All vLLM pods Running after ${elapsed}s."
      break
    fi

    info "  [${elapsed}s] router=${router_status:-Pending}  engine=${engine_status:-Pending}"
    sleep $poll_interval
    elapsed=$(( elapsed + poll_interval ))
  done

  if ! $router_ready || ! $engine_ready; then
    warn "vLLM pods did not reach Running state within ${poll_max}s."
    warn "This is normal for very large models still downloading."
    warn "Watch pods:   kubectl get pods -n ${VLLM_NAMESPACE} -w"
    warn "Engine logs:  kubectl logs -n ${VLLM_NAMESPACE} -l app=vllm-stack -f"
    warn "Router logs:  kubectl logs -n ${VLLM_NAMESPACE} -l app=vllm-stack-router -f"
  fi

  log "vLLM production stack deployed in namespace ${VLLM_NAMESPACE}."
  info "Model:             ${VLLM_MODEL}"
  info "Router endpoint:   http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}"
  info "OpenAI API:        http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1"
  info "Model cache PVC:   ${VLLM_PVC_NAME} (${VLLM_STORAGE_SIZE:-reused})"
  info ""
  info "Test: curl http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1/models"
  info ""
  info "Swap model: helm upgrade vllm-stack vllm/vllm-stack -n ${VLLM_NAMESPACE} \\"
  info "  --reuse-values --set 'servingEngineSpec.modelSpec[0].modelURL=<model-id>'"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 14 — Post-install verification
# ──────────────────────────────────────────────────────────────────────────────
verify_cluster() {
  section "Step 14 — Post-install Verification"
  export KUBECONFIG="/root/.kube/config"

  info "Cluster nodes:"
  kubectl get nodes -o wide

  info "All pods (all namespaces):"
  kubectl get pods --all-namespaces

  info "Storage classes:"
  kubectl get storageclasses

  info "Services:"
  kubectl get svc --all-namespaces | grep -E 'NodePort|LoadBalancer'
}

# ──────────────────────────────────────────────────────────────────────────────
# UNINSTALL — Tear down everything installed by this script
# ──────────────────────────────────────────────────────────────────────────────

# Helper: ask a yes/no question directly from /dev/tty (works even when stdin
# is redirected). Returns 0 for yes, 1 for no.
_ask_tty() {
  local question="$1" default="${2:-n}"
  local prompt yn
  if [[ "$default" == "y" ]]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi
  echo -ne "\n  ${BOLD}${CYAN}${question} ${prompt}:${NC} " >/dev/tty
  read -r yn </dev/tty
  yn="${yn:-$default}"
  [[ "$yn" =~ ^[Yy] ]]
}

# Print a stage header for the uninstall flow
_ustage() {
  echo -e "\n${BOLD}${YELLOW}  ▶  $*${NC}" | tee -a "$LOG_FILE"
}

# Run a command that is allowed to fail (cleanup is best-effort)
_try() {
  "$@" 2>&1 | tee -a "$LOG_FILE" || true
}

uninstall_cluster() {
  section "Kubernetes Cluster — UNINSTALL"
  export KUBECONFIG="/root/.kube/config"

  echo -e "${RED}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║                  ⚠  DESTRUCTIVE OPERATION  ⚠                ║"
  echo "  ║                                                              ║"
  echo "  ║  This will permanently remove:                               ║"
  echo "  ║    • All Helm releases (monitoring, NFS, GPU op, dashboard,  ║"
  echo "  ║      vLLM, and any others)                                   ║"
  echo "  ║    • All Kubernetes namespaces and their workloads           ║"
  echo "  ║    • kubeadm / kubelet / kubectl / containerd on ALL nodes   ║"
  echo "  ║    • CNI configuration and iptables rules                    ║"
  echo "  ║    • Kubeconfig files                                        ║"
  echo "  ║                                                              ║"
  echo "  ║  Data on PersistentVolumes may also be deleted.              ║"
  echo "  ║  This action CANNOT be undone.                               ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  _ask_tty "Are you sure you want to completely uninstall the cluster?" "n" || {
    info "Uninstall cancelled."
    exit 0
  }

  # Second confirmation — type the word
  echo -ne "\n  ${BOLD}${RED}Type  DESTROY  to confirm: ${NC}" >/dev/tty
  local confirm_word
  read -r confirm_word </dev/tty
  if [[ "$confirm_word" != "DESTROY" ]]; then
    info "Confirmation word did not match — uninstall cancelled."
    exit 0
  fi

  warn "Starting uninstall... (log: ${LOG_FILE})"

  # ── Stage 1: Remove Helm releases ──────────────────────────────────────────
  _ustage "Stage 1 — Removing Helm releases"
  if command -v helm &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then

    # Collect all releases across all namespaces
    local releases
    releases=$(helm list --all-namespaces --short 2>/dev/null || true)

    if [[ -n "$releases" ]]; then
      info "Found Helm releases:"
      helm list --all-namespaces 2>/dev/null | tee -a "$LOG_FILE" || true

      if _ask_tty "Uninstall all Helm releases?" "y"; then
        while IFS= read -r release_line; do
          [[ -z "$release_line" ]] && continue
          local rel_name rel_ns
          rel_name=$(echo "$release_line" | awk '{print $1}')
          rel_ns=$(helm list --all-namespaces 2>/dev/null \
            | awk -v r="$rel_name" '$1==r {print $2; exit}')
          info "  Uninstalling ${rel_name} from namespace ${rel_ns:-unknown}..."
          _try helm uninstall "$rel_name" \
            ${rel_ns:+--namespace "$rel_ns"} \
            --wait --timeout=3m
        done <<< "$releases"
        log "All Helm releases removed."
      fi
    else
      info "No Helm releases found."
    fi
  else
    warn "kubectl or cluster unreachable — skipping Helm release removal."
  fi

  # ── Stage 2: Delete Kubernetes namespaces ──────────────────────────────────
  _ustage "Stage 2 — Deleting Kubernetes namespaces"
  if kubectl cluster-info &>/dev/null 2>&1; then
    local managed_ns=(
      "${NS_MONITORING:-monitoring}"
      "${NS_NFS:-nfs-provisioner}"
      "${NS_GPU_OPERATOR:-gpu-operator}"
      "${NS_DASHBOARD:-kubernetes-dashboard}"
      "${VLLM_NAMESPACE:-vllm}"
    )

    if _ask_tty "Delete managed namespaces (monitoring, NFS, GPU, dashboard, vLLM)?" "y"; then
      for ns in "${managed_ns[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null 2>&1; then
          info "  Deleting namespace ${ns}..."
          _try kubectl delete namespace "$ns" --timeout=60s
        fi
      done
      log "Managed namespaces deleted."
    fi
  else
    warn "kubectl unreachable — skipping namespace deletion."
  fi

  # ── Stage 3: kubeadm reset on all nodes ────────────────────────────────────
  _ustage "Stage 3 — Running kubeadm reset on all nodes"
  if _ask_tty "Run 'kubeadm reset' on all nodes (removes k8s control plane + worker state)?" "y"; then

    local reset_script="/tmp/kubeadm_reset_$$.sh"
    cat > "$reset_script" <<'RESETSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
echo "[reset] Running kubeadm reset..."
kubeadm reset --force 2>&1 || true

echo "[reset] Flushing iptables..."
iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X \
  && iptables -t mangle -F && iptables -t mangle -X || true
ip6tables -F && ip6tables -X && ip6tables -t nat -F && ip6tables -t nat -X \
  && ip6tables -t mangle -F && ip6tables -t mangle -X 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true

echo "[reset] Removing CNI configuration..."
rm -rf /etc/cni /opt/cni /var/lib/cni /run/flannel 2>/dev/null || true

echo "[reset] Removing Kubernetes state directories..."
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd \
       /var/lib/dockershim /var/run/kubernetes 2>/dev/null || true

echo "[reset] Stopping and disabling kubelet..."
systemctl stop kubelet  2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

echo "[reset] Node reset complete."
RESETSCRIPT
    chmod 600 "$reset_script"

    local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
    for node in "${all_nodes[@]:-}"; do
      [[ -z "$node" ]] && continue
      info "  Resetting node ${node}..."
      run_script_on "$node" "$reset_script" || \
        warn "Reset script returned non-zero on ${node} — continuing."
    done
    rm -f "$reset_script"
    log "kubeadm reset complete on all nodes."
  fi

  # ── Stage 4: Remove Kubernetes packages ────────────────────────────────────
  _ustage "Stage 4 — Removing Kubernetes packages (kubeadm, kubelet, kubectl)"
  if _ask_tty "Remove kubeadm, kubelet, kubectl, and containerd from all nodes?" "y"; then

    local pkg_script="/tmp/k8s_pkg_remove_$$.sh"
    cat > "$pkg_script" <<'PKGSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[pkg-remove] Removing Kubernetes packages..."
apt-get remove -y --purge kubeadm kubelet kubectl 2>&1 || true
apt-get autoremove -y 2>&1 || true

echo "[pkg-remove] Removing Kubernetes apt source..."
rm -f /etc/apt/sources.list.d/kubernetes.list \
      /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true
apt-get update -qq 2>/dev/null || true

echo "[pkg-remove] Removing leftover config files..."
rm -rf /root/.kube /home/*/.kube 2>/dev/null || true
rm -f  /usr/local/bin/helm 2>/dev/null || true

echo "[pkg-remove] Done."
PKGSCRIPT
    chmod 600 "$pkg_script"

    local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
    for node in "${all_nodes[@]:-}"; do
      [[ -z "$node" ]] && continue
      info "  Removing packages on ${node}..."
      run_script_on "$node" "$pkg_script" || \
        warn "Package removal returned non-zero on ${node} — continuing."
    done
    rm -f "$pkg_script"
    log "Kubernetes packages removed from all nodes."
  fi

  # ── Stage 5: Remove containerd ─────────────────────────────────────────────
  _ustage "Stage 5 — Removing containerd"
  if _ask_tty "Remove containerd from all nodes?" "y"; then

    local ctr_script="/tmp/containerd_remove_$$.sh"
    cat > "$ctr_script" <<'CTRSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[containerd-remove] Stopping containerd..."
systemctl stop containerd 2>/dev/null || true
systemctl disable containerd 2>/dev/null || true

echo "[containerd-remove] Removing package..."
apt-get remove -y --purge containerd.io containerd 2>&1 || true
apt-get autoremove -y 2>&1 || true

echo "[containerd-remove] Removing Docker apt source..."
rm -f /etc/apt/sources.list.d/docker.list \
      /etc/apt/keyrings/docker.gpg 2>/dev/null || true

echo "[containerd-remove] Removing state directories..."
rm -rf /var/lib/containerd /etc/containerd /run/containerd 2>/dev/null || true

echo "[containerd-remove] Done."
CTRSCRIPT
    chmod 600 "$ctr_script"

    local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
    for node in "${all_nodes[@]:-}"; do
      [[ -z "$node" ]] && continue
      info "  Removing containerd on ${node}..."
      run_script_on "$node" "$ctr_script" || \
        warn "containerd removal returned non-zero on ${node} — continuing."
    done
    rm -f "$ctr_script"
    log "containerd removed from all nodes."
  fi

  # ── Stage 6: Remove NVIDIA components ──────────────────────────────────────
  if [[ "${INSTALL_NVIDIA:-false}" == "true" ]]; then
    _ustage "Stage 6 — Removing NVIDIA drivers and container toolkit"
    if _ask_tty "Remove NVIDIA drivers and container toolkit from GPU nodes?" "y"; then

      local nv_script="/tmp/nvidia_remove_$$.sh"
      cat > "$nv_script" <<'NVSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# Only run on nodes that have an NVIDIA GPU
if ! lspci 2>/dev/null | grep -qi nvidia; then
  echo "[nvidia-remove] No GPU detected — skipping."
  exit 0
fi

echo "[nvidia-remove] Stopping nvidia-persistenced..."
systemctl stop nvidia-persistenced 2>/dev/null || true
systemctl disable nvidia-persistenced 2>/dev/null || true

echo "[nvidia-remove] Removing NVIDIA packages..."
apt-get remove -y --purge \
  'nvidia-*' \
  'libnvidia-*' \
  nvidia-container-toolkit \
  nvidia-container-runtime \
  nvidia-docker2 \
  2>&1 || true
apt-get autoremove -y 2>&1 || true

echo "[nvidia-remove] Removing NVIDIA apt sources..."
rm -f /etc/apt/sources.list.d/nvidia*.list \
      /etc/apt/sources.list.d/cuda*.list \
      /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
      /etc/apt/keyrings/nvidia*.gpg 2>/dev/null || true

echo "[nvidia-remove] Restoring nouveau (re-enabling)..."
rm -f /etc/modprobe.d/blacklist-nvidia-nouveau.conf 2>/dev/null || true
update-initramfs -u 2>/dev/null || true

echo "[nvidia-remove] Done. A reboot is recommended."
NVSCRIPT
      chmod 600 "$nv_script"

      local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
      for node in "${all_nodes[@]:-}"; do
        [[ -z "$node" ]] && continue
        info "  Removing NVIDIA components on ${node}..."
        run_script_on "$node" "$nv_script" || \
          warn "NVIDIA removal returned non-zero on ${node} — continuing."
      done
      rm -f "$nv_script"
      log "NVIDIA components removed from GPU nodes."
    fi
  fi

  # ── Stage 7: Remove NFS server (optional) ──────────────────────────────────
  if [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_SERVER_IP:-}" ]]; then
    _ustage "Stage 7 — Removing NFS server configuration"
    if _ask_tty "Remove NFS server export and nfs-kernel-server from ${NFS_SERVER_IP}?" "n"; then

      local nfs_rm_script="/tmp/nfs_remove_$$.sh"
      cat > "$nfs_rm_script" <<NFSRM
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[nfs-remove] Unexporting ${NFS_PATH}..."
sed -i "\|${NFS_PATH}|d" /etc/exports 2>/dev/null || true
exportfs -ra 2>/dev/null || true
systemctl stop nfs-kernel-server 2>/dev/null || true
systemctl disable nfs-kernel-server 2>/dev/null || true
apt-get remove -y --purge nfs-kernel-server 2>&1 || true
apt-get autoremove -y 2>&1 || true
echo "[nfs-remove] Done."
NFSRM
      chmod 600 "$nfs_rm_script"
      run_script_on "$NFS_SERVER_IP" "$nfs_rm_script" || \
        warn "NFS removal returned non-zero on ${NFS_SERVER_IP} — continuing."
      rm -f "$nfs_rm_script"

      if _ask_tty "Also delete the NFS data directory ${NFS_PATH} on ${NFS_SERVER_IP}?" "n"; then
        run_on "$NFS_SERVER_IP" "rm -rf '${NFS_PATH}'" || \
          warn "Could not delete ${NFS_PATH} on ${NFS_SERVER_IP}."
        log "NFS data directory ${NFS_PATH} deleted."
      fi
      log "NFS server configuration removed from ${NFS_SERVER_IP}."
    fi
  fi

  # ── Stage 8: Local cleanup ──────────────────────────────────────────────────
  _ustage "Stage 8 — Local cleanup (installer machine)"
  if _ask_tty "Remove local kubeconfig, lock file, and installer temp files?" "y"; then
    _try rm -f /root/.kube/config
    _try rm -f "$LOCK_FILE"
    _try rm -f /tmp/k8s_join_command.txt
    _try rm -f /root/dashboard-token.txt
    log "Local cleanup complete."
  fi

  section "Uninstall Complete"
  log "Cluster has been torn down."
  warn "A reboot of all nodes is recommended to clear any remaining kernel state."
  info "To reinstall, run: sudo bash $(basename "$0")"
}


main() {
  section "Kubernetes Cluster Installer — Ubuntu 24.04"
  info "Log file: ${LOG_FILE}"

  check_root
  check_lock
  validate_config

  setup_ssh_keys
  prepare_all_nodes
  install_nvidia_drivers
  install_k8s_binaries
  init_control_plane
  install_cni
  join_workers
  install_helm
  install_nfs_provisioner
  install_monitoring
  install_gpu_operator
  install_dashboard
  install_vllm
  verify_cluster

  section "Installation Complete!"
  log "Cluster is up and running."
  info "KUBECONFIG: ${HOME}/.kube/config"
  info "Run: export KUBECONFIG=${HOME}/.kube/config"
  info "Then: kubectl get nodes"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI argument support
#   sudo bash k8s_cluster_setup.sh               — full install
#   sudo bash k8s_cluster_setup.sh --step <name> — run one step
#   sudo bash k8s_cluster_setup.sh --uninstall   — interactive teardown
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  check_root
  validate_config
  uninstall_cluster
elif [[ "${1:-}" == "--step" && -n "${2:-}" ]]; then
  check_root
  validate_config
  case "$2" in
    ssh)                            setup_ssh_keys ;;
    prep|"node prep"|"node-prep"|"Node Preparation")
                                    prepare_all_nodes ;;
    nvidia|"nvidia drivers"|"NVIDIA Drivers"|"NVIDIA")
                                    install_nvidia_drivers ;;
    k8s-bins|"k8s bins"|"kubernetes binaries"|"Kubernetes Binaries")
                                    install_k8s_binaries ;;
    init|"control plane"|"Control Plane Init")
                                    init_control_plane ;;
    cni|"CNI"|"CNI Plugin")         install_cni ;;
    workers|"join workers"|"Join Workers")
                                    join_workers ;;
    helm|"Helm"|"Install Helm")     install_helm ;;
    nfs|"NFS"|"NFS Provisioner"|"nfs provisioner")
                                    install_nfs_provisioner ;;
    monitoring|"Monitoring"|"prometheus"|"grafana"|"Prometheus + Grafana")
                                    install_monitoring ;;
    gpu-op|"gpu op"|"GPU Operator"|"gpu operator"|"gpu-operator")
                                    install_gpu_operator ;;
    dashboard|"Dashboard"|"Kubernetes Dashboard"|"kubernetes dashboard")
                                    install_dashboard ;;
    vllm|"vLLM"|"VLLM"|"vLLM Stack"|"vLLM Production Stack"|"vllm stack"|"vllm production stack")
                                    install_vllm ;;
    verify|"Verify"|"Post-install Verification"|"verification")
                                    verify_cluster ;;
    uninstall|"Uninstall")          uninstall_cluster ;;
    *)
      error "Unknown step: $2"
      error ""
      error "Valid step names:"
      error "  ssh  prep  nvidia  k8s-bins  init  cni  workers"
      error "  helm  nfs  monitoring  gpu-op  dashboard  vllm  verify"
      exit 1
      ;;
  esac
else
  main "$@"
fi
