#!/bin/bash
set -euo pipefail

############################################
# Logging
############################################
LOG_FILE="/var/log/k8s-gpu-cluster.log"
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

############################################
# Globals
############################################
K8S_VERSION="1.29"
POD_CIDR="192.168.0.0/16"
declare -A NODE_STATUS
declare -A NODE_GPU
TOTAL_NODES=0
COMPLETED=0

############################################
# Dashboard UI
############################################
dashboard() {
  clear
  echo "======================================================"
  echo "        KUBERNETES GPU CLUSTER PROVISIONING"
  echo "======================================================"
  printf "%-18s %-15s %-10s\n" "NODE" "STATUS" "GPU"
  echo "------------------------------------------------------"

  for NODE in "${!NODE_STATUS[@]}"; do
    printf "%-18s %-15s %-10s\n" "$NODE" "${NODE_STATUS[$NODE]}" "${NODE_GPU[$NODE]:-N/A}"
  done

  echo "------------------------------------------------------"
  echo "Progress: $COMPLETED / $TOTAL_NODES"
  percent=0
  [[ $TOTAL_NODES -gt 0 ]] && percent=$((COMPLETED*100/TOTAL_NODES))
  filled=$((percent/2))
  empty=$((50-filled))
  printf "["
  printf "%0.s#" $(seq 1 $filled 2>/dev/null)
  printf "%0.s-" $(seq 1 $empty 2>/dev/null)
  printf "] %d%%\n" "$percent"
  echo "======================================================"
}
######################################################################
#####SSH SETUP####
######################################################################
setup_ssh() {
  read -rp "Worker IPs (space separated): " WORKERS
  read -rp "SSH username: " SSH_USER

  if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
  fi

  for NODE in $WORKERS; do
    echo "Setting up SSH for $NODE"
    ssh-copy-id ${SSH_USER}@${NODE}

    echo "Configuring passwordless sudo on $NODE"
    ssh -t ${SSH_USER}@${NODE} "
      echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/99-${SSH_USER} &&
      sudo chmod 440 /etc/sudoers.d/99-${SSH_USER}
    "
  done

  echo "SSH and sudo configuration completed."
}

############################################
# Ubuntu 24.04 Prereqs
############################################
configure_prereqs() {
  sudo apt install curl ethtool nload ipmitool smartmontools git
  sudo swapoff -a || true
  sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

  sudo modprobe overlay
  sudo modprobe br_netfilter

  cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

  sudo sysctl --system
}

############################################
# Containerd
############################################
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
install_control_plane() {

  if kubectl cluster-info >/dev/null 2>&1; then
    echo "Cluster already initialized."
    return
  fi

  configure_prereqs
  install_containerd

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt update
  sudo apt install -y kubelet kubeadm kubectl
  sudo kubeadm init --pod-network-cidr=${POD_CIDR}

  mkdir -p $HOME/.kube
  sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml

  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

############################################
# Generate Join
############################################
generate_join() {
  kubeadm token create --print-join-command > /tmp/k8s_join.sh
  chmod +x /tmp/k8s_join.sh
}

############################################
# Parallel Worker Provision
############################################
bootstrap_workers_parallel() {

  read -rp "Worker IPs: " WORKERS
  read -rp "SSH User: " SSH_USER
  read -rp "Max parallel [5]: " MAX
  MAX=${MAX:-5}

  TOTAL_NODES=$(echo $WORKERS | wc -w)
  COMPLETED=0

  JOIN_CMD=$(cat /tmp/k8s_join.sh)

  provision_node() {
    NODE=$1
    NODE_STATUS[$NODE]="BOOTSTRAP"
    dashboard

    ssh ${SSH_USER}@${NODE} "
      sudo swapoff -a
      sudo modprobe overlay
      sudo modprobe br_netfilter
      sudo apt update
      sudo apt install -y containerd kubelet kubeadm
      sudo ${JOIN_CMD}
    " >/dev/null 2>&1

    NODE_STATUS[$NODE]="JOINED"
    ((COMPLETED++))
    dashboard
  }

  running=0
  for NODE in $WORKERS; do
    provision_node "$NODE" &
    ((running++))
    if [[ $running -ge $MAX ]]; then
      wait -n
      ((running--))
    fi
  done
  wait
}

############################################
# Parallel NVIDIA Install
############################################
install_nvidia_parallel() {

  read -rp "Worker IPs: " WORKERS
  read -rp "SSH User: " SSH_USER
  read -rp "Max parallel [5]: " MAX
  MAX=${MAX:-5}

  TOTAL_NODES=$(echo $WORKERS | wc -w)
  COMPLETED=0

  install_node() {
    NODE=$1
    NODE_STATUS[$NODE]="INSTALLING"
    dashboard

    ssh ${SSH_USER}@${NODE} "
      if command -v nvidia-smi >/dev/null 2>&1; then exit 0; fi
      sudo apt update
      sudo apt install -y ubuntu-drivers-common linux-headers-\$(uname -r)
      DRIVER=\$(ubuntu-drivers devices | awk '/recommended/ {print \$3}')
      sudo apt install -y \$DRIVER
      sudo reboot
    " >/dev/null 2>&1 || true

    sleep 10
    until ssh -o ConnectTimeout=5 ${SSH_USER}@${NODE} "echo up" >/dev/null 2>&1; do
      sleep 5
    done

    if ssh ${SSH_USER}@${NODE} "nvidia-smi" >/dev/null 2>&1; then
      NODE_STATUS[$NODE]="GPU_OK"
      NODE_GPU[$NODE]="YES"
    else
      NODE_STATUS[$NODE]="GPU_FAIL"
      NODE_GPU[$NODE]="NO"
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
# GPU Operator
############################################
install_gpu_operator() {
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
  helm repo update
  kubectl create ns gpu-operator 2>/dev/null || true
  helm install gpu-operator nvidia/gpu-operator \
    -n gpu-operator \
    --set dcgmExporter.enabled=true || true
}

############################################
# Prometheus (NFS Required)
############################################
install_prometheus() {
  kubectl get sc nfs-client || { echo "Deploy NFS first."; return; }
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update
  kubectl create ns monitoring 2>/dev/null || true

  helm install prometheus prometheus-community/prometheus \
    -n monitoring \
    --set server.persistentVolume.enabled=true \
    --set server.persistentVolume.storageClass=nfs-client \
    --set server.persistentVolume.size=50Gi || true
}

############################################
# Grafana
############################################
install_grafana() {
  helm repo add grafana https://grafana.github.io/helm-charts || true
  helm repo update
  kubectl create ns monitoring 2>/dev/null || true

  helm install grafana grafana/grafana -n monitoring \
    --set persistence.enabled=true \
    --set persistence.storageClassName=nfs-client \
    --set persistence.size=10Gi \
    --set adminPassword=admin123 \
    --set datasources."datasources\.yaml".apiVersion=1 \
    --set dashboards.default.gpu.gnetId=12239 \
    --set dashboards.default.gpu.datasource=Prometheus || true
}

############################################
# Uninstall
############################################
uninstall_cluster() {
  sudo kubeadm reset -f || true
  sudo apt purge -y kubelet kubeadm kubectl containerd || true
  sudo rm -rf /etc/kubernetes ~/.kube
}

############################################
# Menu
############################################
while true; do
  echo ""
  echo "1) Install Control Plane"
  echo "2) Setup SSH and Passwordless login"
  echo "3) Generate Join Command"
  echo "4) Parallel Worker Provision"
  echo "5) Parallel NVIDIA Install + Dashboard"
  echo "6) Install GPU Operator"
  echo "7) Install Prometheus"
  echo "8) Install Grafana"
  echo "9) Uninstall Cluster"
  echo "10) Exit"
  echo ""

  read -rp "Select: " opt

  case $opt in
    1) install_control_plane ;;
    2) setup_ssh ;;
    3) generate_join ;;
    4) bootstrap_workers_parallel ;;
    5) install_nvidia_parallel ;;
    6) install_gpu_operator ;;
    7) install_prometheus ;;
    8) install_grafana ;;
    9) uninstall_cluster ;;
    10) exit 0 ;;
  esac
done
