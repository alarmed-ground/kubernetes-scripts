# Kubernetes Cluster Installer — Ubuntu 24.04

Automated, wizard-driven installer for a production-ready Kubernetes cluster on Ubuntu 24.04. Covers everything from SSH key distribution to GPU-accelerated LLM inference with a fully interactive uninstaller.

---

## Table of Contents

1. [Features](#features)
2. [Files](#files)
3. [Prerequisites](#prerequisites)
4. [Quick Start](#quick-start)
5. [Configuration Wizard](#configuration-wizard)
6. [Configuration Reference](#configuration-reference)
7. [Installation Steps](#installation-steps)
8. [Access Endpoints](#access-endpoints)
9. [Running Individual Steps](#running-individual-steps)
10. [Uninstalling](#uninstalling)
11. [Permission Model](#permission-model)
12. [Troubleshooting](#troubleshooting)

---

## Features

| Feature | Details |
|---|---|
| **Interactive wizard** | 10-section guided setup with real-time validation and a full summary review before saving |
| **SSH key management** | Auto-generates a 4096-bit RSA key, distributes it to all nodes, verifies passwordless access |
| **Node preparation** | Swap disabled, sysctl tuning, kernel modules, containerd with SystemdCgroup, systemd-resolved stub DNS fix |
| **NVIDIA driver install** | Per-branch selection, open or proprietary kernel modules, Fabric Manager, automatic reboot-and-wait |
| **Kubernetes binaries** | Official `pkgs.k8s.io` repository, version-pinned, held against unintended upgrades |
| **CNI plugin** | Flannel or Calico, fully configurable pod CIDR |
| **GPU Operator** | NVIDIA GPU Operator via Helm, DCGM exporter, Prometheus ServiceMonitor |
| **NFS provisioner** | Dynamic PVC provisioning, optional NFS server setup, default StorageClass |
| **Monitoring stack** | kube-prometheus-stack — Prometheus, Grafana, and Alertmanager with persistent storage |
| **Kubernetes Dashboard** | Official v2.7.0, NodePort HTTPS access, long-lived admin token |
| **vLLM production stack** | GPU-accelerated LLM inference — images pre-pulled via `ctr` before Helm deploy, correct `lmcache/*` images, `IfNotPresent` pull policy, generous startup probe timing, OpenAI-compatible router |
| **Apt reliability** | Clock sync before update, `Check-Valid-Until=false` flag, exponential-backoff retry on failure |
| **Interactive uninstaller** | 8-stage teardown — Helm releases, namespaces, kubeadm reset, packages, containerd, NVIDIA, NFS, local cleanup |
| **Single-step re-run** | `--step <n>` reruns any individual phase; accepts full section names as well as short keys |

---

## Files

| File | Purpose |
|---|---|
| `k8s_configure.sh` | Interactive wizard — **run this first** |
| `k8s_cluster_setup.sh` | Main installer — run as root after the wizard |
| `k8s_cluster.conf` | Generated config file — auto-created by the wizard, `chmod 600` |
| `k8s_smoke_test.sh` | Post-install verification script |
| `README.md` | This file |

---

## Prerequisites

- **OS**: Ubuntu 24.04 on all nodes (control plane and workers)
- **Network**: The machine running the scripts must have TCP/SSH access to all node IPs
- **SSH**: Password authentication must be enabled initially on each node so the wizard can copy the key (`PasswordAuthentication yes` in `/etc/ssh/sshd_config`)
- **Sudo**: `SSH_USER` must have passwordless sudo, or you will be prompted for the sudo password once per session
- **Helm**: Installed automatically — does not need to be pre-installed
- **GPU nodes** *(optional)*: NVIDIA GPU present and recognised by `lspci`

---

## Quick Start

```bash
# Step 1 — run the wizard (no root required)
bash k8s_configure.sh

# Step 2 — run the installer (root required)
sudo bash k8s_cluster_setup.sh

# Step 3 — verify the install
bash k8s_smoke_test.sh
```

The wizard saves all settings to `k8s_cluster.conf`. The installer sources this file automatically at startup.

---

## Configuration Wizard

`k8s_configure.sh` is an interactive terminal wizard. It validates every input in real time, shows a full summary of all settings before saving, and offers to launch the installer immediately on completion. Root is not required.

### Wizard Sections

| # | Section | What it configures |
|---|---|---|
| 1 | SSH & Access | Remote username, SSH key path (auto-generated if missing) |
| 2 | Cluster Nodes | Control plane IP, worker IPs — enter one per line, blank line to finish |
| 3 | Kubernetes | Minor version, CNI plugin, pod CIDR, Helm version |
| 4 | NVIDIA Drivers | Enable/skip, driver branch, open vs proprietary kernel, Fabric Manager, reboot timeout |
| 5 | Monitoring | Enable/skip, chart version, namespace, NodePorts, Grafana admin password, retention period, PVC size |
| 6 | NFS Provisioner | Enable/skip, server IP, export path, namespace, StorageClass name, default StorageClass |
| 7 | Kubernetes Dashboard | Enable/skip, NodePort, namespace |
| 8 | vLLM Stack | Enable/skip, model ID, HuggingFace token, dtype, context length, GPU count, CPU/memory limits, extra engine flags, model cache PVC (new or reuse) |
| 9 | Namespaces | GPU Operator namespace |
| 10 | Summary & Confirm | Full review of all settings — press `n` to go back and re-run the wizard |

On completion the wizard prints the exact `--step` commands for every phase so you can re-run any individual step later.

---

## Configuration Reference

The wizard writes all settings to `k8s_cluster.conf`. You can also edit this file directly before running the installer. Variables not present in the file fall back to the defaults listed below.

### SSH

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | `ubuntu` | Username on all remote nodes |
| `SSH_KEY_PATH` | `~/.ssh/k8s_cluster_rsa` | Path to the SSH private key — generated automatically if the file does not exist |

### Nodes

| Variable | Default | Description |
|---|---|---|
| `CONTROL_PLANE_IP` | *(required)* | IP address of the Kubernetes control plane node |
| `WORKER_IPS` | `()` | Bash array of worker node IPs — e.g. `("10.0.0.2" "10.0.0.3")`. Leave empty for a single-node cluster. |

### Kubernetes

| Variable | Default | Description |
|---|---|---|
| `K8S_VERSION` | `1.31` | Kubernetes minor version to install from `pkgs.k8s.io` |
| `POD_CIDR` | `10.244.0.0/16` | Pod network CIDR — must not overlap with node or service networks |
| `CNI_PLUGIN` | `flannel` | CNI plugin to deploy: `flannel` or `calico` |
| `HELM_VERSION` | `3.16.2` | Helm binary version installed on the control plane |

### NVIDIA Drivers

| Variable | Default | Description |
|---|---|---|
| `INSTALL_NVIDIA` | `true` | Set to `false` to skip driver installation and GPU Operator entirely |
| `NVIDIA_DRIVER_VERSION` | `550` | Driver branch: `550`, `545`, `535`, or `525` |
| `NVIDIA_OPEN_KERNEL` | `false` | Set to `true` to use the open-source kernel module package (`nvidia-driver-<ver>-open`) |
| `NVIDIA_FABRIC_MANAGER` | `auto` | Fabric Manager for NVSwitch/NVLink: `auto` (detect at install time), `true` (always install), `false` (never install) |
| `NVIDIA_REBOOT_TIMEOUT` | `300` | Seconds to wait per node for SSH to come back after the driver reboot — increase to 600 for slow hardware |

> **Fabric Manager** is required on multi-GPU SXM platforms such as A100 SXM4, H100 SXM5, H200, DGX, and HGX systems. Not needed for single PCIe GPU nodes. `auto` checks for NVSwitch presence at install time.

### Monitoring (kube-prometheus-stack)

| Variable | Default | Description |
|---|---|---|
| `INSTALL_MONITORING` | `true` | Set to `false` to skip the monitoring stack |
| `PROM_STACK_VERSION` | `65.1.0` | Helm chart version for `kube-prometheus-stack` |
| `NS_MONITORING` | `monitoring` | Kubernetes namespace for Prometheus, Grafana, and Alertmanager |
| `GRAFANA_ADMIN_PASSWORD` | *(set by wizard)* | Grafana `admin` account password |
| `GRAFANA_NODEPORT` | `32000` | NodePort for the Grafana web UI |
| `PROMETHEUS_NODEPORT` | `32001` | NodePort for the Prometheus web UI |
| `ALERTMANAGER_NODEPORT` | `32002` | NodePort for the Alertmanager web UI |
| `PROM_RETENTION` | `30d` | How long Prometheus retains metrics |
| `PROM_STORAGE_SIZE` | `20Gi` | PVC size for Prometheus time-series data |

### NFS Storage Provisioner

| Variable | Default | Description |
|---|---|---|
| `INSTALL_NFS` | `true` | Set to `false` to skip NFS provisioner deployment |
| `NFS_SERVER_IP` | `CONTROL_PLANE_IP` | IP of the NFS server — can be any reachable host |
| `NFS_PATH` | `/srv/nfs/k8s` | Export path on the NFS server |
| `NS_NFS` | `nfs-provisioner` | Namespace for the NFS provisioner pod |
| `NFS_STORAGE_CLASS` | `nfs-client` | Name of the StorageClass created by the provisioner |
| `NFS_DEFAULT_SC` | `true` | Annotate this StorageClass as the cluster-wide default |

> If `NFS_SERVER_IP` resolves to one of the cluster nodes, the installer configures `nfs-kernel-server` and `/etc/exports` on that node automatically. If it is an external host, the export must already exist and be reachable before the installer runs.

### Kubernetes Dashboard

| Variable | Default | Description |
|---|---|---|
| `INSTALL_DASHBOARD` | `false` | Set to `true` to deploy the Dashboard |
| `DASHBOARD_VERSION` | `2.7.0` | Dashboard version — pinned to the official v2.7.0 manifest |
| `DASHBOARD_NODEPORT` | `32443` | NodePort for Dashboard HTTPS |
| `NS_DASHBOARD` | `kubernetes-dashboard` | Namespace for the Dashboard deployment |

> After deployment the admin token is printed to the terminal and saved to `/root/dashboard-token.txt` (mode 600). To retrieve it later:
> ```bash
> kubectl get secret dashboard-admin-token \
>   -n kubernetes-dashboard \
>   -o jsonpath='{.data.token}' | base64 -d
> ```

### vLLM Production Stack

| Variable | Default | Description |
|---|---|---|
| `INSTALL_VLLM` | `false` | Set to `true` to deploy vLLM — requires `INSTALL_NVIDIA=true` |
| `VLLM_NAMESPACE` | `vllm` | Kubernetes namespace for all vLLM workloads |
| `VLLM_NODEPORT` | `32080` | NodePort for the OpenAI-compatible vLLM router |
| `VLLM_MODEL` | `meta-llama/Llama-3.2-1B-Instruct` | HuggingFace model ID to load and serve |
| `VLLM_HF_TOKEN` | *(blank)* | HuggingFace access token — required for gated models such as Llama, Gemma, and Mistral |
| `VLLM_DTYPE` | `auto` | Tensor dtype: `auto` (recommended), `float16`, `bfloat16`, or `float32` |
| `VLLM_MAX_MODEL_LEN` | `4096` | Maximum model context length in tokens |
| `VLLM_GPU_COUNT` | `1` | GPUs allocated per vLLM replica — values greater than 1 enable tensor parallelism |
| `VLLM_CPU_REQUEST` | `4` | CPU cores requested per replica pod |
| `VLLM_CPU_LIMIT` | `8` | CPU cores limit per replica pod |
| `VLLM_MEM_REQUEST` | `16Gi` | Memory requested per replica pod |
| `VLLM_MEM_LIMIT` | `32Gi` | Memory limit per replica pod |
| `VLLM_EXTRA_ARGS` | *(blank)* | Additional vLLM engine flags, space-separated (e.g. `--enable-chunked-prefill --quantization awq`) |
| `VLLM_STORAGE_SIZE` | `50Gi` | Size of the model cache PVC — ignored when `VLLM_REUSE_PVC=true` |
| `VLLM_REUSE_PVC` | `false` | Set to `true` to mount an existing PVC instead of creating a new one |
| `VLLM_PVC_NAME` | `vllm-model-cache` | Name of the PVC to create or reuse |

> The HuggingFace token is passed inline to the chart's `modelSpec[].hf_token` field and is never written to log files.
>
> The model cache PVC is managed by the chart via `pvcStorage` and mounted at `/root/.cache/huggingface`, so downloaded weights survive pod restarts without re-downloading.

### GPU Operator

| Variable | Default | Description |
|---|---|---|
| `NS_GPU_OPERATOR` | `gpu-operator` | Namespace for the NVIDIA GPU Operator |

---

## Installation Steps

The installer runs the following 14 steps in order. Each step is idempotent — safe to re-run on a partially or fully configured cluster.

| Step | `--step` name | What it does |
|---|---|---|
| 1 | `ssh` | Generates an SSH keypair if needed, distributes the public key to all nodes, verifies passwordless access |
| 2 | `prep` | Disables swap, fixes `/etc/resolv.conf` systemd-resolved stub, applies sysctl networking parameters, loads kernel modules, installs and configures containerd with `SystemdCgroup = true` |
| 3 | `nvidia` | Detects GPUs via `lspci`, installs the driver (Phase 1), reboots the node, waits for SSH to return, completes driver setup and container toolkit configuration (Phase 2) |
| 4 | `k8s-bins` | Adds the official Kubernetes apt repository, installs and holds `kubeadm`, `kubelet`, and `kubectl` at the configured version |
| 5 | `init` | Runs `kubeadm init` on the control plane, writes kubeconfig to `/root/.kube/config`, generates the worker join command |
| 6 | `cni` | Deploys Flannel or Calico into the cluster |
| 7 | `workers` | Runs `kubeadm join` on each worker node, waits for all nodes to reach `Ready` state |
| 8 | `helm` | Downloads and installs the Helm binary on the control plane |
| 9 | `nfs` | Configures the NFS server if it is a cluster node, verifies export reachability, deploys `nfs-subdir-external-provisioner` |
| 10 | `monitoring` | Resolves the StorageClass, pre-creates the Prometheus PVC, deploys `kube-prometheus-stack` |
| 11 | `gpu-op` | Deploys the NVIDIA GPU Operator, labels GPU nodes, verifies the DCGM exporter |
| 12 | `dashboard` | Deploys the Kubernetes Dashboard, creates the admin ServiceAccount with `ClusterRoleBinding`, creates and retrieves the long-lived token Secret |
| 13 | `vllm` | Pre-pulls `lmcache/vllm-openai` and `lmcache/lmstack-router` on all nodes via `ctr`, deploys the vLLM production stack via Helm with `IfNotPresent` pull policy and generous startup probe timing |
| 14 | `verify` | Prints all node status, all pods across namespaces, StorageClasses, and NodePort/LoadBalancer services |

### Apt Cache Reliability

Before every `apt-get update` on every node the installer:

1. Syncs the system clock with `chronyc makestep`. If chrony is not installed it tries `ntpdate`, and if neither is available it installs chrony first.
2. Passes `-o Acquire::Check-Valid-Until=false` to tolerate residual small clock skew.
3. Retries up to three times with exponential back-off: 15 s, 30 s, 60 s.
4. Never aborts the installation on an apt cache failure — logs a warning and continues.

### systemd-resolved DNS Fix (Step 2)

Ubuntu 24.04 symlinks `/etc/resolv.conf` to the systemd-resolved stub at `127.0.0.53`. That address is only reachable on the node's loopback interface — pods in their own network namespace cannot reach it, causing `Temporary failure in name resolution` inside containers (e.g. vLLM downloading model weights from huggingface.co).

During node preparation the installer re-links `/etc/resolv.conf` to `/run/systemd/resolve/resolv.conf`, which contains real upstream nameserver IPs. Three fallback levels are applied:

1. Symlink to `/run/systemd/resolve/resolv.conf`
2. Extract real nameservers from `resolvectl status` and write a static file
3. Fall back to `8.8.8.8` / `8.8.4.4` as a last resort with a visible warning

**To fix an existing cluster manually** (run on every node as root, then delete the affected pods):

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
cat /etc/resolv.conf          # confirm no 127.0.0.53
sudo systemctl restart kubelet
kubectl delete pods -n vllm -l app=vllm-stack
```

### NVIDIA Driver Reboot Sequence

Driver installation is split into two phases separated by a controlled node reboot:

- **Phase 1**: Install driver and DKMS packages, blacklist nouveau, install the container toolkit, write the containerd runtime config.
- **Reboot**: The installer sends the reboot command and polls SSH every 10 seconds until the node responds, up to `NVIDIA_REBOOT_TIMEOUT` seconds.
- **Phase 2**: Wait for DKMS to finish compiling the kernel module, load `nvidia` with `modprobe`, run `nvidia-smi` to verify, enable Fabric Manager if required, restart containerd.

### vLLM Image Pre-pull (Step 13)

Before Helm deploys any pods the installer pulls both vLLM images directly on every node using `ctr` (the containerd CLI):

```
docker.io/lmcache/vllm-openai:latest    (~10 GB)
docker.io/lmcache/lmstack-router:latest (~2 GB)
```

This prevents the `context canceled` pull failure that occurs when containerd's download is interrupted by a pod being rescheduled or a startup probe firing before the pull completes. The chart is deployed with `imagePullPolicy: IfNotPresent` so Kubernetes never re-pulls an already-cached image.

---

## Access Endpoints

All services are exposed via NodePort and accessible at the control plane IP.

| Service | URL | Default Port | Credentials |
|---|---|---|---|
| Grafana | `http://<CONTROL_PLANE_IP>:<GRAFANA_NODEPORT>` | 32000 | `admin` / `GRAFANA_ADMIN_PASSWORD` |
| Prometheus | `http://<CONTROL_PLANE_IP>:<PROMETHEUS_NODEPORT>` | 32001 | — |
| Alertmanager | `http://<CONTROL_PLANE_IP>:<ALERTMANAGER_NODEPORT>` | 32002 | — |
| Kubernetes Dashboard | `https://<CONTROL_PLANE_IP>:<DASHBOARD_NODEPORT>` | 32443 | Token from `/root/dashboard-token.txt` |
| vLLM API | `http://<CONTROL_PLANE_IP>:<VLLM_NODEPORT>/v1` | 32080 | — |

### vLLM API Usage

```bash
# List loaded models
curl http://<CONTROL_PLANE_IP>:32080/v1/models

# Chat completion (OpenAI-compatible)
curl http://<CONTROL_PLANE_IP>:32080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.2-1B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Updating the vLLM Model After Deployment

```bash
helm upgrade vllm-stack vllm/vllm-stack \
  -n vllm \
  --reuse-values \
  --set 'servingEngineSpec.modelSpec[0].modelURL=<huggingface-model-id>'
```

---

## Running Individual Steps

Any step can be re-run on its own without affecting other components:

```bash
sudo bash k8s_cluster_setup.sh --step <step-name>
```

### Available Step Names

| Short name | Aliases accepted | Phase |
|---|---|---|
| `ssh` | — | SSH key setup |
| `prep` | `node-prep`, `Node Preparation` | Node preparation |
| `nvidia` | `nvidia drivers`, `NVIDIA Drivers` | NVIDIA driver install |
| `k8s-bins` | `k8s bins`, `Kubernetes Binaries` | Kubernetes binaries |
| `init` | `control plane`, `Control Plane Init` | Control plane init |
| `cni` | `CNI`, `CNI Plugin` | CNI plugin |
| `workers` | `join workers`, `Join Workers` | Join worker nodes |
| `helm` | `Helm`, `Install Helm` | Install Helm |
| `nfs` | `NFS`, `NFS Provisioner` | NFS provisioner |
| `monitoring` | `prometheus`, `grafana`, `Prometheus + Grafana` | Monitoring stack |
| `gpu-op` | `gpu operator`, `GPU Operator`, `gpu-operator` | GPU Operator |
| `dashboard` | `Dashboard`, `Kubernetes Dashboard` | Kubernetes Dashboard |
| `vllm` | `vLLM`, `vLLM Stack`, `vLLM Production Stack` | vLLM stack |
| `verify` | `Verify`, `verification` | Post-install check |

This is useful for re-applying a failed step, reinstalling a single component after changing its config, or adding an optional component (Dashboard, vLLM) to an existing cluster. Set the relevant `INSTALL_*` variable to `true` in `k8s_cluster.conf` and run the corresponding step.

---

## Uninstalling

```bash
sudo bash k8s_cluster_setup.sh --uninstall
```

You will be asked to confirm twice: first with a yes/no prompt, then by typing **`DESTROY`** exactly. Each of the eight stages then presents its own yes/no prompt so you can skip individual stages.

| Stage | What it removes | Default |
|---|---|---|
| 1 | **Helm releases** — all releases in all namespaces | yes |
| 2 | **Namespaces** — monitoring, NFS, GPU Operator, Dashboard, and vLLM namespaces | yes |
| 3 | **kubeadm reset** — `kubeadm reset --force` on every node, iptables/ipvs flushed, CNI directories removed, kubelet stopped and disabled | yes |
| 4 | **Kubernetes packages** — `kubeadm`, `kubelet`, `kubectl` purged, apt source and keyring removed, `~/.kube` and Helm binary deleted | yes |
| 5 | **containerd** — stopped, purged, Docker apt source removed, `/var/lib/containerd` deleted | yes |
| 6 | **NVIDIA components** *(only when `INSTALL_NVIDIA=true`)* — all `nvidia-*` packages and the container toolkit purged, nouveau blacklist removed, initramfs rebuilt | yes |
| 7 | **NFS server** *(only when `INSTALL_NFS=true`)* — export entry removed, `nfs-kernel-server` stopped and purged. A separate prompt offers to delete the data directory. | **no** |
| 8 | **Local cleanup** — `/root/.kube/config`, lock file, join command file, Dashboard token file | yes |

> A reboot of all nodes is recommended after uninstalling to clear any remaining kernel state.

---

## Permission Model

| Context | How commands run |
|---|---|
| Installer | Must run as root: `sudo bash k8s_cluster_setup.sh` |
| Wizard | Runs as any user — root not required |
| Remote commands | SSH as `SSH_USER`, then escalated with `sudo bash -c` on the remote node |
| Sudo password | Prompted once per session if NOPASSWD is not configured; cached in memory |
| kubeconfig | Written to `/root/.kube/config` on the control plane |
| Dashboard token | Saved to `/root/dashboard-token.txt` with mode 600 |
| Config file | `k8s_cluster.conf` saved with mode 600 (owner read only) |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| SSH key copy fails | Password authentication disabled on target | Add `PasswordAuthentication yes` to `/etc/ssh/sshd_config` and run `systemctl reload ssh` |
| `"Release file is not valid yet"` | Node clock behind the apt mirror | The installer syncs the clock automatically — if it persists, run `chronyc makestep` manually |
| kubeadm init fails | kubelet not running or misconfigured | `journalctl -xeu kubelet` on the control plane node |
| Nodes stuck `NotReady` | CNI pods not running | `kubectl get pods -n kube-flannel` or `kubectl get pods -n calico-system` |
| GPU node not labelled | NVIDIA driver not loaded | Run `nvidia-smi` on the node; reboot if the driver was just installed |
| vLLM pods stuck `Pending` | No GPU-labelled nodes or insufficient GPU resources | `kubectl get nodes -l nvidia.com/gpu.present=true` and check GPU Operator health |
| vLLM pod DNS failure (`Errno -3`) | `/etc/resolv.conf` points to systemd stub `127.0.0.53` — unreachable from pod network namespace | Run `sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && sudo systemctl restart kubelet` on every node, then `kubectl delete pods -n vllm -l app=vllm-stack` |
| vLLM image pull cancelled mid-stream | Large image (~10 GB) interrupted by pod reschedule or probe timeout | Images are pre-pulled via `ctr` before Helm deploys — re-run `--step vllm` to retry |
| `ctr` image pull DNS error | `ctr` does not assume Docker Hub — needs full `docker.io/` prefix | The installer uses `docker.io/lmcache/...` explicitly |
| `Unknown step: vLLM Production Stack` | Passing the section title instead of the step key | Use `--step vllm` — or any alias from the step names table above |
| vLLM YAML parse error on deploy | Empty optional fields producing blank lines inside YAML sequence item | Fixed — values file is written line-by-line with conditional `echo` |
| vLLM startup probe fails immediately | Router probing engine before model has loaded | Startup probe budget is sized per GPU count: 45 s delay + 120 × 10 s window = ~21 min total |
| vLLM model download takes a long time | Large model weights over a slow connection | Expected on first deploy — monitor with `kubectl logs -n vllm -l app=vllm-stack -f` |
| Gated model returns 401 | HuggingFace token missing or invalid | Set `VLLM_HF_TOKEN` in `k8s_cluster.conf` and re-run `--step vllm` |
| NFS PVC stuck `Pending` | NFS server unreachable from the cluster | `showmount -e <NFS_SERVER_IP>` — check ports 2049/tcp and 111/tcp+udp are open |
| Prometheus CrashLoopBackOff | Insufficient node memory | Nodes should have at least 4 GB RAM; inspect with `kubectl describe pod -n monitoring` |
| Dashboard shows `unknown authority` | Self-signed TLS certificate | Accept the browser certificate exception, or use `kubectl proxy` |
| Uninstall leaves stale iptables rules | Kernel-level rules not cleared by userspace reset | Reboot the node, or run `iptables -F && iptables -X` manually |
