#!/usr/bin/env bash
# =============================================================================
# k8s_configure.sh — Interactive wizard for the Kubernetes cluster installer
#
# Structure:
#   k8s_configure.sh          This file — paths, sourcing, main execution
#   wizard/lib.sh             Shared helpers: prompts, validators, preflight
#   wizard/sections/01_ssh.sh … 10_addons.sh   One section per wizard page
#   wizard/sections/summary.sh   Summary & confirm
#   wizard/sections/config.sh    write_config + patch_installer
#   wizard/sections/launch.sh    offer_launch + run_section_menu + parse_args
# =============================================================================
set -euo pipefail
trap 'echo "[FATAL] Wizard aborted at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIZARD_DIR="${SCRIPT_DIR}/wizard"
CONFIG_FILE="${SCRIPT_DIR}/k8s_cluster.conf"
INSTALLER="${SCRIPT_DIR}/k8s_cluster_setup.sh"
CONF_VERSION=2
TOTAL_SECTIONS=11   # number of collect_* sections (used by show_progress)
CURRENT_SECTION=0   # incremented by show_progress after each section

# ── Source all wizard modules ─────────────────────────────────────────────────
_source_wizard() {
  local missing=0

  if [[ ! -f "${WIZARD_DIR}/lib.sh" ]]; then
    echo "[FATAL] wizard/lib.sh missing — run from the k8s-install directory." >&2
    exit 1
  fi
  # shellcheck source=wizard/lib.sh
  source "${WIZARD_DIR}/lib.sh"

  local section_order=(
    01_ssh 02_nodes 03_k8s 04_nvidia 05_monitoring
    06_nfs 07_dashboard 08_vllm 09_namespaces 10_addons
    summary config launch
  )
  for sec in "${section_order[@]}"; do
    local f="${WIZARD_DIR}/sections/${sec}.sh"
    if [[ ! -f "$f" ]]; then
      echo "[FATAL] Wizard section missing: ${f}" >&2
      missing=$(( missing + 1 ))
    else
      # shellcheck source=/dev/null
      source "$f"
    fi
  done

  if (( missing > 0 )); then
    echo "[FATAL] ${missing} wizard section file(s) missing." >&2
    exit 1
  fi
}

_source_wizard

# ── Main execution ────────────────────────────────────────────────────────────
trap 'echo -e "\n\n  ${YELLOW}${SYM_WARN}  Wizard interrupted — no changes saved.${NC}\n"; exit 130' INT

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
collect_addons
confirm_summary

write_config
patch_installer
run_preflight full
offer_launch
