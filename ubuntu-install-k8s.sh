#!/bin/bash
set -euo pipefail

############################################
# Logging
############################################
mkdir -p ./logs
LOG_FILE="./logs/k8s-gpu-cluster.log"
exec > >(tee -a "$LOG_FILE") 2>&1

############################################
# Globals
############################################
K8S_VERSION="1.29"
POD_CIDR="10.244.0.0/16"

declare -A NODE_ROLE
declare -A NODE_STATUS
declare -A NODE_READY
declare -A NODE_GPU
declare -A NODE_GPUMODEL
declare -A NODE_LASTLOG

TOTAL_NODES=0
COMPLETED=0
NFS_ENABLED=false
NFS_SERVER=""
NFS_PATH=""

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

############################################
# Utility: Safe IP input
############################################
get_node_list() {
  local prompt="$1"
  local raw_input
  read -rp "$prompt (space, comma, or newline separated): " raw_input
  echo "$raw_input" | tr ',' ' ' | tr '\n' ' ' | tr -s ' '
}

############################################
# Dashboard
############################################
dashboard() {
clear
echo -e "${CYAN}===========================================================================================${RESET}"
echo -e "${CYAN}                    KUBERNETES CLUSTER PROVISIONING DASHBOARD${RESET}"
echo -e "${CYAN}===========================================================================================${RESET}"

printf "%-15s %-13s %-15s %-8s %-8s %-20s %-35s\n" \
"NODE" "ROLE" "STATUS" "READY" "GPU" "GPU MODEL" "LAST LOG"
echo "-------------------------------------------------------------------------------------------"

for NODE in "${!NODE_STATUS[@]}"; do
  STATUS="${NODE_STATUS[$NODE]}"
  READY="${NODE_READY[$NODE]:--}"
  GPU="${NODE_GPU[$NODE]:--}"
  MODEL="${NODE_GPUMODEL[$NODE]:--}"
  LAST="${NODE_LASTLOG[$NODE]:-Waiting...}"

  case "$STATUS" in
    INIT_CP) COLOR=$BLUE ;;
    CP_READY) COLOR=$GREEN ;;
    JOINING) COLOR=$YELLOW ;;
    NODE_READY) COLOR=$GREEN ;;
    GPU_INSTALL) COLOR=$BLUE ;;
    GPU_OK) COLOR=$GREEN ;;
    GPU_FAIL) COLOR=$RED ;;
    REBOOTING) COLOR=$YELLOW ;;
    REMOVING) COLOR=$YELLOW ;;
    REMOVED) COLOR=$RED ;;
    QUEUED) COLOR=$CYAN ;;
    *) COLOR=$RESET ;;
  esac

  printf "%-15s ${COLOR}%-15s${RESET} %-8s %-8s %-20s %-35s\n" \
    "$NODE" \
    "${NODE_ROLE[$NODE]}" \
    "$STATUS" \
    "$READY" \
    "$GPU" \
    "${MODEL:0:20}" \
    "${LAST:0:35}"
done

echo "-------------------------------------------------------------------------------------------"
percent=0
[[ $TOTAL_NODES -gt 0 ]] && percent=$((COMPLETED*100/TOTAL_NODES))
filled=$((percent/2))
empty=$((50-filled))
printf "Progress: %d / %d\n" "$COMPLETED" "$TOTAL_NODES"
printf "["
printf "%0.s#" $(seq 1 $filled 2>/dev/null)
printf "%0.s-" $(seq 1 $empty 2>/dev/null)
printf "] %d%%\n" "$percent"
echo -e "${CYAN}===========================================================================================${RESET}"
}

############################################
# Passwordless SSH + sudo
############################################
setup_passwordless_ssh() {
  WORKERS=$(get_node_list "Enter worker IPs")
  read -rp "SSH username: " SSH_USER

  [[ ! -f ~/.ssh/id_rsa ]] && ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

  for NODE in $WORKERS; do
    ssh-copy-id "$SSH_USER@$NODE"
    ssh "$SSH_USER@$NODE" "
      echo '$SSH_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/99-$SSH_USER
      sudo chmod 440 /etc/sudoers.d/99-$SSH_USER
    "
  done
  echo "Passwordless SSH + sudo configured."
}

############################################
# Prerequisites
############################################
configure_prereqs() {
  sudo swapoff -a || true
  sudo sed -i '/ swap / s/^/#/' /etc/fstab || true
  sudo modprobe overlay
  sudo modprobe br_netfilter
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
  sudo sysctl --system
}

install_containerd() {
  sudo apt update
  sudo apt install -y containerd
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  sudo systemctl enable containerd
}

############################################
# Control Plane
############################################
deploy_control_plane() {
  CP_NODE=$(get_node_list "Enter control plane IP")
  read -rp "SSH username for control plane: " SSH_USER

  TOTAL_NODES=$((TOTAL_NODES+1))
  NODE_ROLE[$CP_NODE]="control-plane"
  NODE_STATUS[$CP_NODE]="INIT_CP"
  NODE_LASTLOG[$CP_NODE]="Initializing control plane..."
  dashboard

  ssh "$SSH_USER@$CP_NODE" "
    $(typeset -f configure_prereqs)
    $(typeset -f install_containerd)
    configure_prereqs
    install_containerd
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt update
    sudo apt install -y kubelet kubeadm kubectl
    sudo kubeadm init --pod-network-cidr=${POD_CIDR}
    mkdir -p \$HOME/.kube
    sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config
    sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml
  "

  NODE_STATUS[$CP_NODE]="CP_READY"
  NODE_READY[$CP_NODE]="YES"
  NODE_LASTLOG[$CP_NODE]="Control plane initialized"
  dashboard

  JOIN_CMD=$(ssh "$SSH_USER@$CP_NODE" "kubeadm token create --print-join-command")
  echo "$JOIN_CMD" > ./logs/kube_join.sh
}

############################################
# Worker Node Join
############################################
join_workers() {
  WORKERS=$(get_node_list "Enter worker IPs")
  read -rp "SSH username for workers: " SSH_USER

  for NODE in $WORKERS; do
    ((TOTAL_NODES++))
    NODE_ROLE[$NODE]="worker"
    NODE_STATUS[$NODE]="JOINING"
    NODE_READY[$NODE]="-"
    NODE_LASTLOG[$NODE]="Joining cluster..."
    dashboard

    ssh "$SSH_USER@$NODE" "sudo $(cat ./logs/kube_join.sh)"

    NODE_STATUS[$NODE]="NODE_READY"
    NODE_READY[$NODE]="YES"
    NODE_LASTLOG[$NODE]="Node joined cluster"
    ((COMPLETED++))
    dashboard
  done
}

############################################
# Parallel NVIDIA Install
############################################
install_nvidia_parallel() {
  WORKERS=$(get_node_list "Enter worker IPs")
  read -rp "SSH username: " SSH_USER
  read -rp "Max parallel installs [5]: " MAX
  MAX=${MAX:-5}

  mkdir -p ./logs/nvidia
  COMPLETED=0
  for NODE in $WORKERS; do
    NODE_STATUS[$NODE]="GPU_INSTALL"
    NODE_GPU[$NODE]="-"
    NODE_GPUMODEL[$NODE]="-"
    NODE_LASTLOG[$NODE]="Waiting..."
  done
  dashboard

  install_node() {
    NODE=$1
    LOG_FILE="./logs/nvidia/$NODE.log"

    ssh "$SSH_USER@$NODE" "cat > /tmp/install_nvidia.sh" << 'EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v nvidia-smi >/dev/null 2>&1; then exit 0; fi
sudo apt update
sudo apt install -y ubuntu-drivers-common linux-headers-$(uname -r)
DRIVER=$(ubuntu-drivers devices | awk '/recommended/ {print $3}')
sudo apt install -y $DRIVER
sudo reboot
EOF

    ssh "$SSH_USER@$NODE" "bash /tmp/install_nvidia.sh" > "$LOG_FILE" 2>&1 &

    PID=$!
    while kill -0 $PID 2>/dev/null; do
      NODE_LASTLOG[$NODE]=$(tail -n1 "$LOG_FILE")
      dashboard
      sleep 2
    done
    wait $PID || true

    NODE_STATUS[$NODE]="REBOOTING"
    NODE_LASTLOG[$NODE]="Waiting for reboot..."
    dashboard
    sleep 10

    until ssh -o ConnectTimeout=5 "$SSH_USER@$NODE" "echo up" >/dev/null 2>&1; do
      sleep 5
      NODE_LASTLOG[$NODE]="Rebooting..."
      dashboard
    done

    if ssh "$SSH_USER@$NODE" "nvidia-smi" >/dev/null 2>&1; then
      NODE_STATUS[$NODE]="GPU_OK"
      NODE_GPU[$NODE]="YES"
      NODE_GPUMODEL[$NODE]=$(ssh "$SSH_USER@$NODE" "nvidia-smi --query-gpu=name --format=csv,noheader | head -n1")
      NODE_LASTLOG[$NODE]="Driver verified"
    else
      NODE_STATUS[$NODE]="GPU_FAIL"
      NODE_GPU[$NODE]="NO"
      NODE_GPUMODEL[$NODE]="-"
      NODE_LASTLOG[$NODE]="Verification failed"
    fi

    ((COMPLETED++))
    dashboard
  }

  running=0
  for NODE in $WORKERS; do
    install_node "$NODE" &
    ((running++))
    if [[ $running -ge $MAX ]]; then
      wait -n
      ((running--))
    fi
  done
  wait
}

############################################
# NFS Setup
############################################
setup_nfs() {
  read -rp "Use NFS for Prometheus/Grafana PVCs? (y/n): " USE
  USE=${USE,,}
  [[ "$USE" != "y" ]] && { NFS_ENABLED=false; echo "Skipping NFS"; return; }
  NFS_ENABLED=true
  read -rp "NFS server IP: " NFS_SERVER
  read -rp "NFS path: " NFS_PATH
}

############################################
# Prometheus
############################################
deploy_prometheus() {
  [[ "$NFS_ENABLED" != true ]] && { echo "NFS not enabled. Skipping Prometheus."; return; }
  mkdir -p ./logs/prometheus
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: $NFS_SERVER
    path: $NFS_PATH/prometheus
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 20Gi
EOF

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm install prometheus prometheus-community/prometheus \
    --set server.persistentVolume.existingClaim=prometheus-pvc
}

############################################
# Grafana
############################################
deploy_grafana() {
  [[ "$NFS_ENABLED" != true ]] && { echo "NFS not enabled. Skipping Grafana."; return; }
  mkdir -p ./logs/grafana
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: $NFS_SERVER
    path: $NFS_PATH/grafana
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
EOF

  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update
  helm install grafana grafana/grafana \
    --set persistence.existingClaim=grafana-pvc \
    --set adminUser=admin \
    --set adminPassword=admin
}

############################################
# DCGM Exporter
############################################
deploy_dcgm_exporter() {
  kubectl create namespace gpu-metrics || true
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: gpu-metrics
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
    spec:
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: dcgm-exporter
        image: nvcr.io/nvidia/k8s/dcgm-exporter:2.5.13-2.6.8-ubuntu24.04
        resources:
          limits:
            nvidia.com/gpu: 1
        ports:
        - containerPort: 9400
          name: metrics
EOF
}

configure_prometheus_for_gpu() {
  kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-servicemonitor
  namespace: default
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  namespaceSelector:
    matchNames:
      - gpu-metrics
  endpoints:
  - port: metrics
    interval: 30s
EOF
}

############################################
# Uninstall Cluster
############################################
uninstall_cluster() {
  read -rp "SSH username for all nodes: " SSH_USER
  ALL_NODES=$(get_node_list "Enter all node IPs (control-plane + workers)")

  echo -e "${RED}WARNING: Will remove Kubernetes, NVIDIA, Prometheus/Grafana, DCGM on all nodes!${RESET}"
  read -rp "Continue? (y/n): " CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && return

  for NODE in $ALL_NODES; do
    NODE_STATUS[$NODE]="REMOVING"
    NODE_LASTLOG[$NODE]="Uninstalling..."
    dashboard

    ssh "$SSH_USER@$NODE" bash -c "'
      set -e
      sudo systemctl stop kubelet containerd || true
      sudo kubeadm reset -f || true
      sudo apt-get purge -y kubelet kubeadm kubectl || true
      sudo apt-get purge -y nvidia-* || true
      sudo apt-get autoremove -y
      sudo rm -rf ~/.kube /etc/kubernetes /var/lib/etcd /var/lib/kubelet /mnt/prometheus /mnt/grafana
      kubectl delete daemonset dcgm-exporter -n gpu-metrics --ignore-not-found
      kubectl delete namespace gpu-metrics --ignore-not-found
    '"

    NODE_STATUS[$NODE]="REMOVED"
    NODE_READY[$NODE]="NO"
    NODE_GPU[$NODE]="-"
    NODE_GPUMODEL[$NODE]="-"
    NODE_LASTLOG[$NODE]="Removed"
    dashboard
  done
  echo -e "${GREEN}Cluster uninstalled on all nodes.${RESET}"
}

############################################
# Single-Node PoC Deployment
############################################
single_node_poc() {
  echo -e "${YELLOW}Starting single-node PoC deployment...${RESET}"
  LOCAL_NODE=$(hostname -I | awk '{print $1}')
  TOTAL_NODES=1
  NODE_ROLE[$LOCAL_NODE]="control-plane+worker"
  NODE_STATUS[$LOCAL_NODE]="INIT_CP"
  NODE_READY[$LOCAL_NODE]="NO"
  NODE_GPU[$LOCAL_NODE]="-"
  NODE_GPUMODEL[$LOCAL_NODE]="-"
  NODE_LASTLOG[$LOCAL_NODE]="Initializing..."
  dashboard

  configure_prereqs
  install_containerd

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt update
  sudo apt install -y kubelet kubeadm kubectl
  sudo kubeadm init --pod-network-cidr=${POD_CIDR} --ignore-preflight-errors=all
  mkdir -p $HOME/.kube
  sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml

  NODE_STATUS[$LOCAL_NODE]="NODE_READY"
  NODE_READY[$LOCAL_NODE]="YES"
  NODE_LASTLOG[$LOCAL_NODE]="Single-node cluster ready"
  COMPLETED=1
  dashboard
}

############################################
# Main Menu
############################################
while true; do
  echo ""
  echo "1) Setup Passwordless SSH + sudo"
  echo "2) Deploy Control Plane"
  echo "3) Join Worker Nodes"
  echo "4) Parallel NVIDIA Install + GPU Dashboard"
  echo "5) Setup NFS for Prometheus/Grafana"
  echo "6) Deploy Prometheus with PVC"
  echo "7) Deploy Grafana with PVC and dashboards"
  echo "8) Deploy NVIDIA DCGM Exporter"
  echo "9) Configure Prometheus to scrape GPU metrics"
  echo "10) Single-Node PoC Deployment"
  echo "11) Uninstall entire cluster"
  echo "12) Exit"
  echo ""

  read -rp "Select: " opt
  case $opt in
    1) setup_passwordless_ssh ;;
    2) deploy_control_plane ;;
    3) join_workers ;;
    4) install_nvidia_parallel ;;
    5) setup_nfs ;;
    6) deploy_prometheus ;;
    7) deploy_grafana ;;
    8) deploy_dcgm_exporter ;;
    9) configure_prometheus_for_gpu ;;
    10) single_node_poc ;;
    11) uninstall_cluster ;;
    12) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
