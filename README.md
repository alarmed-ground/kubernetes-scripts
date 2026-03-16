# Kubernetes Cluster Installer — Ubuntu 24.04

Automated, wizard-driven installer for a production-ready Kubernetes cluster on Ubuntu 24.04. Covers everything from SSH key distribution to GPU-accelerated LLM inference, with pre-flight checks, inline section editing, GPU time-slicing, a thorough post-install health check, and a fully interactive uninstaller.

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
10. [GPU Time-Slicing](#gpu-time-slicing)
11. [Uninstalling](#uninstalling)
12. [Permission Model](#permission-model)
13. [Troubleshooting](#troubleshooting)

---

## Features

| Feature | Details |
|---|---|
| **Interactive wizard** | 10-section guided setup with real-time validation, inline section re-editing at the summary screen, and pre-flight checks before saving |
| **Pre-flight checks** | Ping reachability, SSH port check, SSH key auth test, local disk space, NFS export reachability, NodePort conflict detection |
| **SSH key management** | Auto-generates a 4096-bit RSA key, distributes it to all nodes, verifies passwordless access |
| **Node preparation** | Swap disabled, sysctl tuning, kernel modules, containerd with SystemdCgroup, systemd-resolved stub DNS fix, pod CIDR masquerade rule |
| **NVIDIA driver install** | Per-branch selection (525-590), open or proprietary kernel modules, Fabric Manager, automatic reboot-and-wait with SSH stability confirmation |
| **GPU time-slicing** | Expose multiple virtual GPUs per physical GPU via the device plugin — works on any NVIDIA GPU, configurable replica count |
| **Kubernetes binaries** | Official `pkgs.k8s.io` repository, version-pinned, held against unintended upgrades |
| **CNI plugin** | Flannel (pinned v0.26.2, VXLAN) or Calico (v3.28.0, VXLAN mode), auto-selected pod CIDR defaults, retry on `kubectl apply` |
| **Single-node support** | Control-plane `NoSchedule` taint automatically removed when no workers are configured |
| **GPU Operator** | NVIDIA GPU Operator via Helm, DCGM exporter, Prometheus ServiceMonitor |
| **NFS provisioner** | Dynamic PVC provisioning, optional NFS server setup, default StorageClass; auto-disabled when `NFS_SERVER_IP` is empty |
| **Monitoring stack** | kube-prometheus-stack — Prometheus, Grafana, and Alertmanager with persistent storage; NodePorts validated for conflicts |
| **Kubernetes Dashboard** | Official v2.7.0, NodePort HTTPS access, long-lived admin token |
| **vLLM production stack** | GPU-accelerated LLM inference — images pre-pulled via `ctr`, router service patched to NodePort, startup probe sized by model class (1B to 70B), gated model detection |
| **Apt reliability** | Clock sync before update, `Check-Valid-Until=false`, exponential-backoff retry |
| **Smart step counter** | Section headers show the current step number dynamically — no hardcoded numbers that drift |
| **Latest log symlink** | `k8s_install_latest.log` always points to the most recent run |
| **Thorough verification** | Post-install check covers node readiness, pod failures, CoreDNS resolution, storage classes, and NodePort reachability |
| **Interactive uninstaller** | 8-stage teardown with per-stage confirmation |
| **Single-step re-run** | `--step <n>` reruns any individual phase |
| **Wizard re-run** | `--section <n>` re-runs a single wizard section against the existing config |

---

## Files

| File | Purpose |
|---|---|
| `k8s_configure.sh` | Interactive wizard — **run this first** |
| `k8s_cluster_setup.sh` | Main installer — run as root after the wizard |
| `k8s_cluster.conf` | Generated config file — auto-created by the wizard, `chmod 600` |
| `k8s_smoke_test.sh` | Post-install smoke test script |
| `README.md` | This file |

---

## Prerequisites

- **OS**: Ubuntu 24.04 on all nodes (control plane and workers)
- **Network**: The machine running the scripts must have TCP/SSH access to all node IPs
- **SSH**: Password authentication must be enabled initially (`PasswordAuthentication yes` in `/etc/ssh/sshd_config`)
- **Sudo**: `SSH_USER` must have passwordless sudo, or you will be prompted once per session
- **Helm**: Installed automatically
- **GPU nodes** *(optional)*: NVIDIA GPU present and recognised by `lspci`

---

## Quick Start

```bash
# Step 1 — run the wizard (no root required)
bash k8s_configure.sh

# Step 2 — run the installer (root required)
sudo bash k8s_cluster_setup.sh

# Step 3 — verify (also runs automatically at the end of the install)
sudo bash k8s_cluster_setup.sh --step verify
```

The wizard saves all settings to `k8s_cluster.conf`. The installer sources this file automatically. Every run writes a timestamped log and updates the `k8s_install_latest.log` symlink.

---

## Configuration Wizard

`k8s_configure.sh` validates every input in real time, runs pre-flight checks before saving, shows a full summary, and lets you jump back to any section inline without restarting.

### Wizard CLI Flags

| Flag | Description |
|---|---|
| *(no flags)* | Full wizard |
| `--section <name>` | Re-run one section against the existing config |
| `--preflight` | Run pre-flight checks only |
| `--show` | Print the current config file and exit |
| `--help` | Usage reference |

**Section names:** `ssh` `nodes` `k8s` `nvidia` `monitoring` `nfs` `dashboard` `vllm` `namespaces`

### Wizard Sections

| # | Section | What it configures |
|---|---|---|
| 1 | SSH & Access | Remote username, SSH key path (auto-generated if missing) |
| 2 | Cluster Nodes | Control plane IP, worker IPs |
| 3 | Kubernetes | Version, CNI plugin, pod CIDR (auto-defaulted per CNI), Helm version |
| 4 | NVIDIA Drivers | Enable/skip, driver branch, open vs proprietary kernel, Fabric Manager, **GPU time-slicing** (replica count), reboot timeout |
| 5 | Monitoring | Enable/skip, chart version, namespace, NodePorts (range-validated, conflict-checked), Grafana password with strength check and confirmation, retention, PVC size |
| 6 | NFS Provisioner | Enable/skip, server IP, export path, namespace, StorageClass, default StorageClass |
| 7 | Kubernetes Dashboard | Enable/skip, NodePort, namespace |
| 8 | vLLM Stack | Enable/skip, model menu (6 presets + custom), HuggingFace token with gated model detection, dtype, context length, GPU count (auto-suggested from worker count), CPU/memory limits (auto-scaled by GPU count), memory warning for large models, extra engine flags, PVC |
| 9 | Namespaces | GPU Operator namespace |
| 10 | Summary & Confirm | Full review — type `1`-`9` to edit any section, `p` for pre-flight, `y` to save |

### Pre-flight Checks

Run automatically before saving (and via `--preflight`):

- **Ping** — ICMP reachability for each node
- **SSH port** — TCP port 22 open (`nc` with `/dev/tcp` fallback)
- **SSH auth** — key-based login test (non-fatal before first install)
- **Disk space** — warns if installer machine has less than 500 MB free
- **NFS** — `showmount -e` or port 2049 check when NFS is enabled
- **NodePort conflicts** — all configured NodePorts must be unique

---

## Configuration Reference

All variables can be set in `k8s_cluster.conf` or via the wizard. Unset variables fall back to the defaults shown.

### SSH

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | `ubuntu` | Username on all remote nodes |
| `SSH_KEY_PATH` | `~/.ssh/k8s_cluster_rsa` | SSH private key path — auto-generated if missing |

### Nodes

| Variable | Default | Description |
|---|---|---|
| `CONTROL_PLANE_IP` | *(required)* | Control plane node IP |
| `WORKER_IPS` | `()` | Bash array of worker IPs, e.g. `("10.0.0.2" "10.0.0.3")`. Empty = single-node cluster. |

### Kubernetes

| Variable | Default | Description |
|---|---|---|
| `K8S_VERSION` | `1.31` | Minor version from `pkgs.k8s.io` |
| `POD_CIDR` | `10.244.0.0/16` | Pod CIDR — auto-defaults to `192.168.0.0/16` for Calico |
| `CNI_PLUGIN` | `flannel` | `flannel` (recommended for VMs) or `calico` (NetworkPolicy support) |
| `HELM_VERSION` | `3.16.2` | Helm version — upgraded automatically if a different version is installed |

### NVIDIA Drivers

| Variable | Default | Description |
|---|---|---|
| `INSTALL_NVIDIA` | `true` | `false` skips drivers and GPU Operator |
| `NVIDIA_DRIVER_VERSION` | `590` | Branch: `590` (LATEST), `580`, `570`, `565`, `560`, `550` (LTS), `535`, `525` |
| `NVIDIA_OPEN_KERNEL` | `false` | `true` installs `nvidia-driver-<ver>-open` — required for Blackwell, recommended for Turing+ |
| `NVIDIA_FABRIC_MANAGER` | `auto` | `auto` (detect NVSwitch), `true` (always), `false` (never) |
| `NVIDIA_REBOOT_TIMEOUT` | `300` | Seconds per node to wait for SSH after reboot |

> **Branch guide:** `590`/`580`/`570` for Blackwell and RTX 50xx. `565`/`560` for RTX 40xx and Ampere/Hopper server GPUs. `550` is the recommended LTS for most deployments. `535`/`525` for older Ampere DataCenter cards.

> **Fabric Manager** is required for NVSwitch/NVLink systems (A100 SXM4, H100 SXM5, DGX, HGX). Not needed for PCIe single-GPU nodes.

### GPU Time-Slicing

| Variable | Default | Description |
|---|---|---|
| `GPU_TIMESLICING_ENABLED` | `false` | `true` enables time-slicing via the device plugin ConfigMap |
| `GPU_TIMESLICE_COUNT` | `4` | Virtual GPUs per physical GPU |

### Monitoring

| Variable | Default | Description |
|---|---|---|
| `INSTALL_MONITORING` | `true` | `false` skips the monitoring stack |
| `PROM_STACK_VERSION` | `65.1.0` | `kube-prometheus-stack` chart version |
| `NS_MONITORING` | `monitoring` | Namespace for Prometheus, Grafana, Alertmanager |
| `GRAFANA_ADMIN_PASSWORD` | *(set by wizard)* | Grafana `admin` password — masked in log output |
| `GRAFANA_NODEPORT` | `32000` | Grafana NodePort |
| `PROMETHEUS_NODEPORT` | `32001` | Prometheus NodePort |
| `ALERTMANAGER_NODEPORT` | `32002` | Alertmanager NodePort |
| `PROM_RETENTION` | `30d` | Metrics retention period |
| `PROM_STORAGE_SIZE` | `20Gi` | Prometheus PVC size |

### NFS Storage Provisioner

| Variable | Default | Description |
|---|---|---|
| `INSTALL_NFS` | `true` | `false` skips NFS; auto-disabled if `NFS_SERVER_IP` is empty |
| `NFS_SERVER_IP` | `CONTROL_PLANE_IP` | NFS server IP |
| `NFS_PATH` | `/srv/nfs/k8s` | Export path |
| `NS_NFS` | `nfs-provisioner` | Provisioner namespace |
| `NFS_STORAGE_CLASS` | `nfs-client` | StorageClass name |
| `NFS_DEFAULT_SC` | `true` | Make this the cluster-wide default StorageClass |

> If `NFS_SERVER_IP` is a cluster node the installer configures `nfs-kernel-server` automatically. For external NFS servers the export must exist before the installer runs.

### Kubernetes Dashboard

| Variable | Default | Description |
|---|---|---|
| `INSTALL_DASHBOARD` | `false` | `true` deploys the Dashboard |
| `DASHBOARD_VERSION` | `2.7.0` | Pinned to official v2.7.0 manifest |
| `DASHBOARD_NODEPORT` | `32443` | HTTPS NodePort |
| `NS_DASHBOARD` | `kubernetes-dashboard` | Dashboard namespace |

> Token is saved to `/root/dashboard-token.txt` (mode 600). Retrieve later with:
> ```bash
> kubectl get secret dashboard-admin-token -n kubernetes-dashboard \
>   -o jsonpath='{.data.token}' | base64 -d
> ```

### vLLM Production Stack

| Variable | Default | Description |
|---|---|---|
| `INSTALL_VLLM` | `false` | `true` deploys vLLM — requires `INSTALL_NVIDIA=true` |
| `VLLM_NAMESPACE` | `vllm` | vLLM namespace |
| `VLLM_NODEPORT` | `32080` | Router NodePort (OpenAI-compatible API) |
| `VLLM_MODEL` | `meta-llama/Llama-3.2-1B-Instruct` | HuggingFace model ID |
| `VLLM_HF_TOKEN` | *(blank)* | HuggingFace token — required for gated models (Llama, Gemma, Mistral) |
| `VLLM_DTYPE` | `auto` | `auto`, `float16`, `bfloat16`, or `float32` |
| `VLLM_MAX_MODEL_LEN` | `4096` | Max context length in tokens |
| `VLLM_GPU_COUNT` | `1` | GPUs per replica — >1 enables tensor parallelism |
| `VLLM_CPU_REQUEST` | `4` | CPU cores requested per replica |
| `VLLM_CPU_LIMIT` | `8` | CPU cores limit per replica |
| `VLLM_MEM_REQUEST` | `16Gi` | Memory requested per replica |
| `VLLM_MEM_LIMIT` | `32Gi` | Memory limit per replica |
| `VLLM_EXTRA_ARGS` | *(blank)* | Extra engine flags (e.g. `--enable-chunked-prefill --quantization awq`) |
| `VLLM_STORAGE_SIZE` | `50Gi` | Model cache PVC size (ignored when `VLLM_REUSE_PVC=true`) |
| `VLLM_REUSE_PVC` | `false` | `true` mounts an existing PVC |
| `VLLM_PVC_NAME` | `vllm-model-cache` | PVC name to create or reuse |

> The HuggingFace token is never written to log files.

### GPU Operator

| Variable | Default | Description |
|---|---|---|
| `NS_GPU_OPERATOR` | `gpu-operator` | GPU Operator namespace |

---

## Installation Steps

The installer runs 15 steps in order. Each step is idempotent. Step numbers appear dynamically in log output and always match execution order.

| Step | `--step` name | What it does |
|---|---|---|
| 1 | `ssh` | Generates SSH keypair if needed, copies public key to all nodes, verifies passwordless access |
| 2 | `prep` | Disables swap, fixes `/etc/resolv.conf` DNS stub, adds pod CIDR masquerade rule, applies sysctl, loads kernel modules, installs containerd with `SystemdCgroup = true` |
| 3 | `nvidia` | Detects GPU via `lspci`, installs driver (Phase 1), reboots with SSH stability confirmation, completes driver setup and container toolkit (Phase 2) |
| 4 | `k8s-bins` | Adds Kubernetes apt repo (quoted heredoc + sed injection — no unbound variable risk), installs `kubeadm`/`kubelet`/`kubectl`/`kubernetes-cni`, fallback CNI plugins tarball if loopback is missing |
| 5 | `init` | Runs `kubeadm init`, writes kubeconfig, generates join command; removes `NoSchedule` taint on single-node clusters |
| 6 | `cni` | Deploys Flannel (v0.26.2) or Calico (v3.28.0, VXLAN mode) with retry logic |
| 7 | `workers` | Writes join command to a temp script and runs via `run_script_on` (avoids word-splitting of tokens), waits for all nodes `Ready` |
| 8 | `helm` | Installs Helm; upgrades if installed version != `HELM_VERSION` |
| 9 | `nfs` | Configures NFS server if it is a cluster node, verifies reachability, deploys provisioner |
| 10 | `monitoring` | Resolves StorageClass, pre-creates Prometheus PVC, deploys `kube-prometheus-stack` |
| 11 | `gpu-op` | Deploys GPU Operator, labels GPU nodes via Kubernetes API (not `hostname`), enables DCGM exporter |
| 12 | `gpu-timeslice` | Creates device plugin ConfigMap, patches ClusterPolicy, labels nodes, restarts device plugin, verifies virtual GPU count |
| 13 | `dashboard` | Deploys Dashboard, creates admin ServiceAccount + ClusterRoleBinding, saves long-lived token |
| 14 | `vllm` | Pre-pulls images on all nodes via `ctr` using `run_script_on` (handles local node correctly), deploys via Helm, patches router service to NodePort, polls readiness |
| 15 | `verify` | Checks node readiness, pod failure states, pending pods, CoreDNS resolution, StorageClasses, NodePort reachability |

### Apt Cache Reliability

Before every `apt-get update` the installer: syncs the clock (`chronyc makestep`, fallback to `ntpdate` or installs chrony), passes `Acquire::Check-Valid-Until=false`, and retries up to 3 times with 15 s / 30 s / 60 s back-off. Apt failures are never fatal.

### systemd-resolved DNS Fix (Step 2)

Ubuntu 24.04 symlinks `/etc/resolv.conf` to `127.0.0.53` — unreachable from inside pod network namespaces, causing `Temporary failure in name resolution` in containers. The installer re-links to `/run/systemd/resolve/resolv.conf` with three fallback levels (symlink → `resolvectl` extraction → `8.8.8.8`).

**Manual fix for existing clusters:**

```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
cat /etc/resolv.conf          # confirm no 127.0.0.53
sudo systemctl restart kubelet
kubectl delete pods -n vllm -l app=vllm-stack
```

### NVIDIA Driver Reboot Sequence (Step 3)

- **Phase 1**: Blacklist nouveau, install driver + DKMS, enable Fabric Manager if required
- **Reboot**: Sends reboot, waits for SSH to go down, waits for it to come back, adds a 5 s stability pause to avoid false-positive detection, waits for `systemctl is-system-running`
- **Phase 2**: Verify `nvidia-smi`, install container toolkit, configure containerd runtime, enable nvidia-persistenced

### vLLM Startup Probe Sizing (Step 14)

The probe budget is automatically calculated from the model ID so the pod is never killed while the model is loading:

| Model class | Initial delay | Failure threshold | Total budget |
|---|---|---|---|
| 1-3B | 300 s | 210 x 10 s | ~40 min |
| 7-8B | 480 s | 210 x 10 s | ~43 min |
| 13-14B | 720 s | 210 x 10 s | ~47 min |
| 34B | 1200 s | 240 x 10 s | ~60 min |
| 70B | 2400 s | 300 x 10 s | ~90 min |

Multi-GPU deployments add 60 s per extra GPU for NCCL initialisation. `initialDelaySeconds` is intentionally long — the probe does not fire at all during this window.

### vLLM Router NodePort (Step 14)

The `vllm-stack` chart creates the router service as `ClusterIP` — `serviceType`/`serviceNodePort` are not valid chart values. After Helm deploys, the installer locates the router service by label and patches it to `NodePort` with `kubectl patch svc`.

---

## Access Endpoints

| Service | URL | Default Port | Credentials |
|---|---|---|---|
| Grafana | `http://<CONTROL_PLANE_IP>:<GRAFANA_NODEPORT>` | 32000 | `admin` / your password |
| Prometheus | `http://<CONTROL_PLANE_IP>:<PROMETHEUS_NODEPORT>` | 32001 | — |
| Alertmanager | `http://<CONTROL_PLANE_IP>:<ALERTMANAGER_NODEPORT>` | 32002 | — |
| Kubernetes Dashboard | `https://<CONTROL_PLANE_IP>:<DASHBOARD_NODEPORT>` | 32443 | Token from `/root/dashboard-token.txt` |
| vLLM API | `http://<CONTROL_PLANE_IP>:<VLLM_NODEPORT>/v1` | 32080 | — |

### vLLM API Usage

```bash
# Health check
curl http://<CONTROL_PLANE_IP>:32080/health

# List models (use the exact ID returned here in all requests)
curl http://<CONTROL_PLANE_IP>:32080/v1/models | python3 -m json.tool

# Chat completion
curl http://<CONTROL_PLANE_IP>:32080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.2-1B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 256
  }'

# Python (OpenAI SDK drop-in)
python3 -c "
from openai import OpenAI
client = OpenAI(base_url='http://<CONTROL_PLANE_IP>:32080/v1', api_key='none')
r = client.chat.completions.create(
    model='meta-llama/Llama-3.2-1B-Instruct',
    messages=[{'role':'user','content':'Hello!'}]
)
print(r.choices[0].message.content)
"
```

### Swapping the vLLM Model

```bash
helm upgrade vllm-stack vllm/vllm-stack -n vllm \
  --reuse-values \
  --set 'servingEngineSpec.modelSpec[0].modelURL=<huggingface-model-id>'
```

---

## Running Individual Steps

```bash
sudo bash k8s_cluster_setup.sh --step <step-name>
```

| Short name | Aliases | Phase |
|---|---|---|
| `ssh` | — | SSH key setup |
| `prep` | `node-prep`, `Node Preparation` | Node preparation |
| `nvidia` | `nvidia drivers`, `NVIDIA` | NVIDIA driver install |
| `k8s-bins` | `k8s bins`, `Kubernetes Binaries` | Kubernetes binaries |
| `init` | `control plane`, `Control Plane Init` | Control plane init |
| `cni` | `CNI`, `CNI Plugin` | CNI plugin |
| `workers` | `join workers`, `Join Workers` | Join worker nodes |
| `helm` | `Helm`, `Install Helm` | Install Helm |
| `nfs` | `NFS`, `NFS Provisioner` | NFS provisioner |
| `monitoring` | `prometheus`, `grafana`, `Prometheus + Grafana` | Monitoring stack |
| `gpu-op` | `gpu operator`, `GPU Operator`, `gpu-operator` | GPU Operator |
| `gpu-timeslice` | `timeslice`, `time-slicing`, `gpu-timeslicing` | GPU time-slicing |
| `dashboard` | `Dashboard`, `Kubernetes Dashboard` | Kubernetes Dashboard |
| `vllm` | `vLLM`, `vLLM Stack`, `vLLM Production Stack` | vLLM stack |
| `verify` | `Verify`, `verification` | Post-install health check |

---

## GPU Time-Slicing

GPU time-slicing lets multiple pods share a single physical GPU by time-multiplexing. Each physical GPU appears as `GPU_TIMESLICE_COUNT` virtual GPUs to the scheduler. Pods request `nvidia.com/gpu: 1` as normal.

### When to use it

- One physical GPU shared across multiple inference pods
- Lightweight models (1-3B) where VRAM is not the bottleneck
- Dev/test environments without strict isolation requirements

### Limitations

- **No memory isolation** — all pods on a GPU share its VRAM; an OOM in one slice can affect all of them
- **Context-switch overhead** — heavy workloads see latency spikes at slice boundaries
- **Not suitable for training** — use MIG (requires Ampere+) for hard memory partitioning

### Configuration

```bash
# k8s_cluster.conf
GPU_TIMESLICING_ENABLED="true"
GPU_TIMESLICE_COUNT="4"    # each physical GPU appears as 4 virtual GPUs
```

Or run standalone after the GPU Operator is installed:

```bash
sudo bash k8s_cluster_setup.sh --step gpu-timeslice
```

### Verifying

```bash
kubectl get nodes -o json | python3 -c "
import sys, json
for n in json.load(sys.stdin)['items']:
    gpus = n['status']['allocatable'].get('nvidia.com/gpu','0')
    print(n['metadata']['name'], '->', gpus, 'virtual GPU(s)')
"
```

### Disabling

```bash
kubectl delete configmap time-slicing-config -n gpu-operator
kubectl patch clusterpolicy gpu-cluster-policy -n gpu-operator \
  --type=merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":""}}}}'
```

---

## Uninstalling

```bash
sudo bash k8s_cluster_setup.sh --uninstall
```

Requires two confirmations: a yes/no prompt then typing **`DESTROY`** exactly. Each stage has its own yes/no prompt.

| Stage | What it removes | Default |
|---|---|---|
| 1 | Helm releases — all releases in all namespaces | yes |
| 2 | Namespaces — monitoring, NFS, GPU Operator, Dashboard, vLLM | yes |
| 3 | kubeadm reset — `kubeadm reset --force`, iptables/ipvs flush, CNI dirs, kubelet stopped | yes |
| 4 | Kubernetes packages — kubeadm, kubelet, kubectl purged; apt source, keyring, `~/.kube`, Helm removed | yes |
| 5 | containerd — stopped, purged, Docker apt source removed, `/var/lib/containerd` deleted | yes |
| 6 | NVIDIA components *(INSTALL_NVIDIA=true only)* — all nvidia-* packages, container toolkit, nouveau blacklist removed | yes |
| 7 | NFS server *(INSTALL_NFS=true only)* — export removed, nfs-kernel-server purged; separate prompt to delete data dir | **no** |
| 8 | Local cleanup — `/root/.kube/config`, lock file, join command, Dashboard token | yes |

> Reboot all nodes after uninstalling to clear remaining kernel state.

---

## Permission Model

| Context | How commands run |
|---|---|
| Installer | Must run as root: `sudo bash k8s_cluster_setup.sh` |
| Wizard | Any user — root not required |
| Remote commands | SSH as `SSH_USER`, escalated with `sudo bash` on the remote |
| Sudo password | Prompted once per session; cached in memory |
| Local node detection | `is_local_node()` checks all local IPs — local nodes run directly, never SSH to themselves |
| kubeconfig | `/root/.kube/config` on control plane; fetched to installer machine if remote |
| `KUBECONFIG` | Exported globally in `main()` after `init_control_plane` — all steps inherit it |
| Dashboard token | `/root/dashboard-token.txt`, mode 600 |
| Config file | `k8s_cluster.conf`, mode 600 |
| Log files | `k8s_install_<date>.log` per run; `k8s_install_latest.log` symlink always points to the most recent |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| SSH key copy fails | Password auth disabled on target | Add `PasswordAuthentication yes` to `/etc/ssh/sshd_config` and `systemctl reload ssh` |
| `"Release file is not valid yet"` | Node clock behind apt mirror | Installer syncs clock automatically; if persistent: `chronyc makestep` |
| `CNI_VER: unbound variable` | Unquoted heredoc expanded outer-shell variables | Fixed — `generate_k8s_binaries_script` uses a quoted heredoc with `sed` injection |
| `ok: command not found` | Wizard helper function leaked into installer | Fixed — installer uses `log()`/`warn()`/`info()` only |
| kubeadm init fails | kubelet not running | `journalctl -xeu kubelet` on the control plane |
| Nodes stuck `NotReady` | CNI pods not running | `kubectl get pods -n kube-flannel` or `kubectl get pods -n calico-system` |
| Single-node pods all `Pending` | Control-plane `NoSchedule` taint set | Fixed — taint removed automatically; manual: `kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-` |
| GPU node not labelled | Driver not loaded | `nvidia-smi` on the node; reboot if driver was just installed |
| vLLM pods stuck `Pending` | No GPU-labelled nodes | `kubectl get nodes -l nvidia.com/gpu.present=true`; check GPU Operator health |
| vLLM startup probe kills pod | Probe budget exhausted before model loaded | Budget is now sized by model class (40-90 min); patch manually: `kubectl patch deployment <engine> -n vllm --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":360}]'` |
| No service on port 32080 | Router service left as ClusterIP by Helm chart | Fixed — installer patches to NodePort after deploy; manual: `kubectl patch svc <router-svc> -n vllm --type=json -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"replace","path":"/spec/ports/0/nodePort","value":32080}]'` |
| vLLM pod DNS failure (`Errno -3`) | `/etc/resolv.conf` points to `127.0.0.53` stub | `sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && sudo systemctl restart kubelet` on every node, then delete vLLM pods |
| vLLM image pre-pull fails on local node | `scp_and_run` tried to SSH to itself | Fixed — prepull uses `run_script_on` which handles local nodes |
| Gated model returns 401 | HuggingFace token missing or invalid | Set `VLLM_HF_TOKEN` in `k8s_cluster.conf` and re-run `--step vllm` |
| GPU time-slicing shows 0 virtual GPUs | Device plugin still restarting | Wait 60 s; `kubectl get pods -n gpu-operator` |
| NFS PVC stuck `Pending` | NFS server unreachable | `showmount -e <NFS_SERVER_IP>`; confirm ports 2049/tcp and 111/tcp+udp are open |
| `INSTALL_NFS=true` but NFS silently skipped | `NFS_SERVER_IP` was empty | Fixed — installer auto-sets `INSTALL_NFS=false` with a warning |
| Helm not upgrading | Old version already installed | Fixed — installer compares versions and upgrades if different |
| Prometheus CrashLoopBackOff | Insufficient node memory | Nodes need at least 4 GB RAM; `kubectl describe pod -n monitoring` |
| Dashboard shows `unknown authority` | Self-signed TLS certificate | Accept browser exception or use `kubectl proxy` |
| Uninstall leaves stale iptables rules | Kernel rules not cleared | Reboot the node, or `iptables -F && iptables -X && iptables -t nat -F` |
| NodePort conflict between services | Two services on the same port | Wizard detects this in pre-flight; re-run `bash k8s_configure.sh --section monitoring` to change ports |
| Calico IPIP not working on VMs | Hypervisor drops IP protocol 4 | Fixed — Calico is patched to VXLAN immediately after apply |
| `rp_filter` dropping pod UDP | Ubuntu 24.04 defaults `rp_filter=2` (strict) | Fixed — installer sets `rp_filter=0` in sysctl on all nodes |
