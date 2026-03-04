#!/bin/bash
set -euo pipefail

############################################
# Logging
############################################
LOG_FILE="/var/log/k8s-gpu-installer.log"
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== Kubernetes GPU Cluster Installer Started $(date) ====="

############################################
# Variables
############################################
K8S_VERSION="1.29"
POD_NETWORK_CIDR="192.168.0.0/16"

############################################
# Helpers
############################################
pause(){ read -rp "Press Enter to continue..."; }
ns_exists(){ kubectl get ns "$1" >/dev/null 2>&1; }
helm_exists(){ helm status "$1" -n "$2" >/dev/null 2>&1; }
require_root(){ [[ $EUID -ne 0 ]] && echo "Run as root or with sudo" && exit 1; }

############################################
# SSH Setup (Passwordless + Sudo Fix)
############################################
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
# NVIDIA Install (Remote)
############################################
install_nvidia_workers() {
  read -rp "Worker IPs: " WORKERS
  read -rp "SSH username: " SSH_USER

  for NODE in $WORKERS; do
    echo "========== $NODE =========="

    echo "Creating remote install script..."

    cat <<'EOS' > /tmp/install_nvidia.sh
#!/bin/bash
set -e

if ! sudo -n true 2>/dev/null; then
  echo "ERROR: Passwordless sudo is NOT configured."
  exit 1
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "NVIDIA already installed."
  exit 0
fi

echo "Installing prerequisites..."
sudo apt update
sudo apt install -y ubuntu-drivers-common software-properties-common

echo "Detecting recommended driver..."
sudo ubuntu-drivers devices

echo "Installing driver..."
sudo ubuntu-drivers autoinstall

echo "Installation complete. Rebooting..."
sudo reboot
EOS

    chmod +x /tmp/install_nvidia.sh

    echo "Copying script to $NODE"
    scp /tmp/install_nvidia.sh ${SSH_USER}@${NODE}:/tmp/

    echo "Executing install script on $NODE"
    set +e
    ssh ${SSH_USER}@${NODE} "bash /tmp/install_nvidia.sh"
    set -e

    echo "Waiting for node to reboot..."

    sleep 10

    # Wait until node is down
    while ssh -o ConnectTimeout=3 ${SSH_USER}@${NODE} "echo up" >/dev/null 2>&1; do
      sleep 5
    done

    echo "Node is rebooting..."

    # Wait until node comes back
    until ssh -o ConnectTimeout=5 ${SSH_USER}@${NODE} "echo online" >/dev/null 2>&1; do
      echo "Waiting for $NODE..."
      sleep 10
    done

    echo "$NODE is back online."

    echo "Verifying NVIDIA installation..."
    ssh ${SSH_USER}@${NODE} "nvidia-smi || echo 'Driver not detected!'"

    echo "========== DONE $NODE =========="
  done
}

configure_k8s_kernel() {

  echo "Configuring kernel modules for Kubernetes..."

  # Load required modules immediately
  sudo modprobe overlay
  sudo modprobe br_netfilter

  # Persist modules
  cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  echo "Configuring sysctl settings..."

  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sudo sysctl --system

  echo "Kernel configuration complete."
}
############################################
# NVIDIA Local
############################################
install_nvidia_local() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "NVIDIA already installed."
    return
  fi
  sudo apt update
  sudo apt install -y ubuntu-drivers-common
  sudo ubuntu-drivers autoinstall
  echo "Reboot required. Re-run script after reboot."
  exit 0
}

############################################
# Kubernetes Control Plane
############################################
install_control_plane() {

  if kubectl cluster-info >/dev/null 2>&1; then
    echo "Cluster already exists."
    return
  fi
  configure_k8s_kernel
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab

  sudo apt update
  sudo apt install -y containerd curl gnupg apt-transport-https ca-certificates

  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  sudo systemctl enable containerd

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt update
  sudo apt install -y kubelet kubeadm kubectl
  sudo kubeadm init --pod-network-cidr=${POD_NETWORK_CIDR}

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
  kubeadm token create --print-join-command > /var/tmp/k8s_join.sh
  chmod +x /var/tmp/k8s_join.sh
  echo "Join command saved to /var/tmp/k8s_join.sh"
}

############################################
# Bootstrap Workers
############################################
bootstrap_workers() {
  read -rp "Worker IPs: " WORKERS
  read -rp "SSH username: " SSH_USER
  JOIN_CMD=$(cat /var/tmp/k8s_join.sh)

  for NODE in $WORKERS; do
    echo "Bootstrapping $NODE"
    ssh -tt ${SSH_USER}@${NODE} <<EOF
set -e
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo apt update
sudo apt install -y containerd curl gnupg apt-transport-https ca-certificates
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo apt install -y kubelet kubeadm
sudo ${JOIN_CMD}
EOF
  done
}

############################################
# NFS Provisioner
############################################
install_nfs() {
  read -rp "NFS Server IP: " NFS_SERVER
  read -rp "NFS Path: " NFS_PATH

  helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ || true
  helm repo update
  ns_exists nfs-storage || kubectl create ns nfs-storage

  helm_exists nfs-provisioner nfs-storage && echo "NFS already installed." && return

  helm install nfs-provisioner \
    nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    -n nfs-storage \
    --set nfs.server=${NFS_SERVER} \
    --set nfs.path=${NFS_PATH} \
    --set storageClass.name=nfs-client \
    --set storageClass.defaultClass=true
}

############################################
# GPU Operator (DCGM Enabled)
############################################
install_gpu_operator() {
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
  helm repo update
  ns_exists gpu-operator || kubectl create ns gpu-operator

  helm_exists gpu-operator gpu-operator && echo "GPU Operator already installed." && return

  helm install gpu-operator nvidia/gpu-operator \
    -n gpu-operator \
    --set dcgmExporter.enabled=true
}

############################################
# Prometheus (NFS PVC Required)
############################################
install_prometheus() {

  kubectl get sc nfs-client >/dev/null 2>&1 || { echo "Deploy NFS first."; return; }

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update
  ns_exists monitoring || kubectl create ns monitoring

  helm_exists prometheus monitoring && echo "Prometheus already installed." && return

  cat <<EOF > prom-values.yaml
server:
  persistentVolume:
    enabled: true
    storageClass: nfs-client
    size: 50Gi
  retention: 30d
alertmanager:
  persistentVolume:
    enabled: true
    storageClass: nfs-client
    size: 10Gi
EOF

  helm install prometheus prometheus-community/prometheus -n monitoring -f prom-values.yaml
}

############################################
# Grafana (Auto Dashboard)
############################################
install_grafana() {

  kubectl get sc nfs-client >/dev/null 2>&1 || { echo "Deploy NFS first."; return; }

  helm repo add grafana https://grafana.github.io/helm-charts || true
  helm repo update
  ns_exists monitoring || kubectl create ns monitoring

  helm_exists grafana monitoring && echo "Grafana already installed." && return

  cat <<EOF > grafana-values.yaml
adminPassword: admin123
persistence:
  enabled: true
  storageClassName: nfs-client
  size: 10Gi
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-server.monitoring.svc.cluster.local
      access: proxy
      isDefault: true
dashboards:
  default:
    gpu-dashboard:
      gnetId: 12239
      revision: 1
      datasource: Prometheus
EOF

  helm install grafana grafana/grafana -n monitoring -f grafana-values.yaml
}

############################################
# Untaint Control Plane
############################################
untaint_control_plane(){
  NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  kubectl taint nodes "$NODE" node-role.kubernetes.io/control-plane- || true
}

############################################
# Single Node PoC
############################################
single_node_poc(){
  install_nvidia_local
  install_control_plane
  untaint_control_plane
  install_gpu_operator
  echo "PoC setup complete."
}

############################################
# Uninstall Entire Kubernetes Cluster
############################################
uninstall_cluster() {

  echo "⚠ WARNING: This will REMOVE the entire Kubernetes cluster."
  read -rp "Are you sure? (yes/no): " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && echo "Cancelled." && return

  echo "Removing Helm releases (if present)..."

  helm uninstall grafana -n monitoring 2>/dev/null || true
  helm uninstall prometheus -n monitoring 2>/dev/null || true
  helm uninstall gpu-operator -n gpu-operator 2>/dev/null || true
  helm uninstall nfs-provisioner -n nfs-storage 2>/dev/null || true

  echo "Deleting namespaces..."
  kubectl delete ns monitoring --ignore-not-found
  kubectl delete ns gpu-operator --ignore-not-found
  kubectl delete ns nfs-storage --ignore-not-found

  echo "Resetting control plane..."
  sudo kubeadm reset -f || true

  echo "Removing Kubernetes packages..."
  sudo apt purge -y kubeadm kubelet kubectl kubernetes-cni || true
  sudo apt autoremove -y

  echo "Stopping kubelet..."
  sudo systemctl stop kubelet || true
  sudo systemctl disable kubelet || true

  echo "Removing CNI configs..."
  sudo rm -rf /etc/cni/net.d
  sudo rm -rf /var/lib/cni/
  sudo rm -rf /var/lib/kubelet/
  sudo rm -rf /etc/kubernetes/
  sudo rm -rf $HOME/.kube

  echo "Flushing iptables..."
  sudo iptables -F
  sudo iptables -X
  sudo iptables -t nat -F
  sudo iptables -t nat -X
  sudo iptables -t mangle -F
  sudo iptables -t mangle -X

  echo "Restarting containerd..."
  sudo systemctl restart containerd || true

  echo "Cluster removal complete on control plane."

  read -rp "Do you want to uninstall worker nodes as well? (yes/no): " REMOVE_WORKERS

  if [[ "$REMOVE_WORKERS" == "yes" ]]; then
    read -rp "Worker IPs (space separated): " WORKERS
    read -rp "SSH username: " SSH_USER

    for NODE in $WORKERS; do
      echo "Removing Kubernetes from $NODE"

      ssh ${SSH_USER}@${NODE} <<'EOF'
sudo kubeadm reset -f || true
sudo apt purge -y kubeadm kubelet kubectl kubernetes-cni || true
sudo apt autoremove -y
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /etc/kubernetes/
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo systemctl restart containerd || true
EOF

      echo "$NODE cleaned."
    done
  fi

  echo "Kubernetes cluster fully removed."
}

############################################
# Menu
############################################
while true; do
  echo ""
  echo "1) Single Node PoC Setup"
  echo "2) Setup SSH + Passwordless Sudo"
  echo "3) Install NVIDIA Drivers on Workers"
  echo "4) Install Control Plane"
  echo "5) Generate Join Command"
  echo "6) Bootstrap Workers"
  echo "7) Install NFS"
  echo "8) Install GPU Operator"
  echo "9) Install Prometheus"
  echo "10) Install Grafana"
  echo "11) Untaint Control Plane"
  echo "12) Uninstall Entire Cluster"
  echo "13) Exit"
read -rp "Select option: " opt

case $opt in
    1) single_node_poc ;;
    2) setup_ssh ;;
    3) install_nvidia_workers ;;
    4) install_control_plane ;;
    5) generate_join ;;
    6) bootstrap_workers ;;
    7) install_nfs ;;
    8) install_gpu_operator ;;
    9) install_prometheus ;;
    10) install_grafana ;;
    11) untaint_control_plane ;;
    12) uninstall_cluster ;;
    13) break ;;
    *) echo "Invalid option" ;;
  esac

  pause
done

echo "===== Installer Finished $(date) ====="
