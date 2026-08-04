#!/bin/bash
# =============================================================================
# Dynamo on Brev - Idempotent cluster setup
#
# Intended for Brev oncreate lifecycle (curl | bash), often as root.
# Safe to re-run: each step checks before acting.
#
# Idempotency / failure-hardening ideas adapted from woodgaines
# (https://github.com/mjhermanson-nv/dynamo-grove-brev/pull/1).
# =============================================================================

set -euo pipefail

# --- Colors / step helpers ---------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

step_num=0

# Print a numbered step banner.
# Input: human-readable step title
step() {
    step_num=$((step_num + 1))
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Step $step_num: $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Echo then run a command (so logs show what executed).
# Input: command + args
run() {
    echo -e "${YELLOW}  ▶ $*${NC}"
    "$@"
}

# Mark a step as already satisfied.
# Input: short reason string
skip() {
    echo -e "${GREEN}  ✓ Already done: $1${NC}"
}

# Fail the script if a check command exits non-zero.
# Input: $1 description, $2 shell expression to evaluate
validate() {
    echo -e "${YELLOW}  🔍 Validating: $1${NC}"
    if eval "$2"; then
        echo -e "${GREEN}  ✓ Validated${NC}"
    else
        echo -e "${RED}  ✗ Validation failed: $1${NC}"
        exit 1
    fi
}

# When lifecycle runs as root, chown paths back to the Brev user.
# Input: one or more filesystem paths
fix_owner() {
    if [ "$(id -u)" -eq 0 ]; then
        chown -R "$USER:$USER" "$@"
    fi
}

# Detect Brev user (handles ubuntu, nvidia, shadeform, etc.)
# Returns: username on stdout
detect_brev_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
        return
    fi
    for user_home in /home/*; do
        username=$(basename "$user_home")
        [ "$username" = "launchpad" ] && continue
        if ls "$user_home"/.lifecycle-script-ls-*.log 2>/dev/null | grep -q . || \
           [ -f "$user_home/.verb-setup.log" ] || \
           { [ -L "$user_home/.cache" ] && [ "$(readlink "$user_home/.cache")" = "/ephemeral/cache" ]; }; then
            echo "$username"
            return
        fi
    done
    [ -d "/home/nvidia" ] && echo "nvidia" && return
    [ -d "/home/ubuntu" ] && echo "ubuntu" && return
    echo "ubuntu"
}

# Brev oncreate often invokes this as root; remap HOME/USER to the instance user
# so kubeconfig and shell rc updates land in the right place.
if [ "$(id -u)" -eq 0 ] || [ "${USER:-}" = "root" ]; then
    DETECTED_USER=$(detect_brev_user)
    export USER="$DETECTED_USER"
    export HOME="/home/$DETECTED_USER"
fi

export RELEASE_VERSION="${RELEASE_VERSION:-0.7.1}"
export NAMESPACE="${NAMESPACE:-dynamo}"
export CACHE_PATH="${CACHE_PATH:-/data/huggingface-cache}"

echo "☸️  Setting up Kubernetes with Dynamo..."
echo "User: $USER  HOME: $HOME"

# =============================================================================
# Step 1: microk8s
# =============================================================================
step "Install microk8s"

if snap list microk8s &>/dev/null; then
    skip "microk8s is installed"
else
    run sudo snap install microk8s --classic
fi

if ! groups "$USER" | grep -q microk8s; then
    run sudo usermod -a -G microk8s "$USER"
else
    skip "$USER is in microk8s group"
fi

# Brev bootstrap sometimes writes disabled_plugins = ["cri"] into containerd
# configs. That URI is invalid on current containerd and prevents microk8s from
# becoming ready. Strip it if present, then restart containerd only when needed.
if grep -q 'disabled_plugins.*"cri"' /var/snap/microk8s/*/args/containerd.toml 2>/dev/null || \
   grep -q 'disabled_plugins.*"cri"' /var/snap/microk8s/*/args/containerd-template.toml 2>/dev/null; then
    echo -e "${YELLOW}  ⚠ Fixing corrupted containerd config (removing invalid 'cri' plugin entry)${NC}"
    sudo sed -i '/disabled_plugins.*cri/d' /var/snap/microk8s/*/args/containerd.toml 2>/dev/null || true
    sudo sed -i '/disabled_plugins.*cri/d' /var/snap/microk8s/*/args/containerd-template.toml 2>/dev/null || true
    if [ -f /etc/containerd/config.toml ] && grep -q 'disabled_plugins.*"cri"' /etc/containerd/config.toml; then
        sudo bash -c 'echo "version = 2" > /etc/containerd/config.toml'
    fi
    sudo systemctl reset-failed snap.microk8s.daemon-containerd 2>/dev/null || true
    sudo systemctl restart snap.microk8s.daemon-containerd
    sleep 5
fi

echo -e "${YELLOW}  ▶ sudo microk8s status --wait-ready${NC}"
sudo microk8s status --wait-ready
validate "microk8s is running" "sudo microk8s status | grep -q 'microk8s is running'"

# =============================================================================
# Step 2: addons (dns + nvidia; skip Kubernetes Dashboard)
# Dashboard is deprecated upstream, not used by the labs, and the wait path on
# main broke when microk8s moved it out of kube-system.
# =============================================================================
step "Enable microk8s addons (dns, nvidia)"

if sudo microk8s status --addon dns 2>&1 | grep -q "enabled"; then
    skip "dns addon enabled"
else
    run sudo microk8s enable dns
fi

if sudo microk8s status --addon nvidia 2>&1 | grep -q "enabled"; then
    skip "nvidia addon enabled"
else
    run sudo microk8s enable nvidia
fi

validate "dns addon enabled" "sudo microk8s status --addon dns 2>&1 | grep -q 'enabled'"
validate "nvidia addon enabled" "sudo microk8s status --addon nvidia 2>&1 | grep -q 'enabled'"

# =============================================================================
# Step 3: kubeconfig (always refresh so partial runs do not leave a stale file)
# =============================================================================
step "Configure kubeconfig"

mkdir -p "$HOME/.kube"
echo -e "${YELLOW}  ▶ sudo microk8s config > ~/.kube/config${NC}"
sudo microk8s config > "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
fix_owner "$HOME/.kube"

export KUBECONFIG="$HOME/.kube/config"

for shell_config in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$shell_config" ] && ! grep -q "KUBECONFIG.*kube/config" "$shell_config"; then
        {
            echo ""
            echo "# Kubernetes config"
            echo 'export KUBECONFIG=$HOME/.kube/config'
        } >> "$shell_config"
        fix_owner "$shell_config"
    fi
done

# Retry for up to 60s — nvidia GPU operator install can briefly churn the API server,
# and standalone kubectl isn't installed until Step 6 so fall back to microk8s kubectl.
echo -e "${YELLOW}  🔍 Validating: cluster reachable (retrying up to 60s)${NC}"
CLUSTER_OK=0
for i in $(seq 1 12); do
    if kubectl cluster-info &>/dev/null 2>&1 || sudo microk8s kubectl cluster-info &>/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Validated${NC}"
        CLUSTER_OK=1
        break
    fi
    echo -e "${YELLOW}  ⏳ API server not ready yet, retrying ($i/12)...${NC}"
    sleep 5
done
if [ "$CLUSTER_OK" -eq 0 ]; then
    echo -e "${RED}  ✗ Validation failed: cluster reachable${NC}"
    exit 1
fi

# =============================================================================
# Step 4: Dynamo env vars
# =============================================================================
step "Set Dynamo environment variables"

for shell_config in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$shell_config" ] && ! grep -q "DYNAMO\|RELEASE_VERSION" "$shell_config"; then
        cat >> "$shell_config" <<'DYNAMO_ENV'

# NVIDIA Dynamo configuration
export RELEASE_VERSION="0.7.1"
export NAMESPACE="dynamo"
export CACHE_PATH="/data/huggingface-cache"
DYNAMO_ENV
        fix_owner "$shell_config"
    else
        [ -f "$shell_config" ] && skip "Dynamo vars already in $(basename "$shell_config")"
    fi
done

validate "RELEASE_VERSION is set" '[ -n "$RELEASE_VERSION" ]'

# =============================================================================
# Step 5: Hugging Face cache dir
# =============================================================================
step "Create cache directory"

if [ -d "$CACHE_PATH" ]; then
    skip "$CACHE_PATH exists"
else
    run sudo mkdir -p "$CACHE_PATH"
fi
# World-writable so notebook / container users can share the HF cache volume.
run sudo chmod 777 "$CACHE_PATH"
validate "cache dir writable" "[ -w \"$CACHE_PATH\" ]"

# =============================================================================
# Step 6: standalone kubectl (fallback to microk8s binary on download failure)
# =============================================================================
step "Install standalone kubectl"

sudo snap unalias kubectl 2>/dev/null || true

if [ -x /usr/local/bin/kubectl ]; then
    skip "kubectl at /usr/local/bin/kubectl"
else
    KUBECTL_VERSION=$(curl -fsSL --connect-timeout 10 --max-time 30 https://dl.k8s.io/release/stable.txt 2>/dev/null | head -n 1 | tr -d '\r\n') || true
    if [ -z "$KUBECTL_VERSION" ] || ! echo "$KUBECTL_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo -e "${YELLOW}  ⚠ Could not determine kubectl version, falling back to microk8s symlink${NC}"
        run sudo ln -sf /snap/microk8s/current/kubectl /usr/local/bin/kubectl
    elif ! curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 5 \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl 2>/dev/null; then
        echo -e "${YELLOW}  ⚠ Download failed, falling back to microk8s symlink${NC}"
        run sudo ln -sf /snap/microk8s/current/kubectl /usr/local/bin/kubectl
    else
        run chmod +x /tmp/kubectl
        run sudo mv /tmp/kubectl /usr/local/bin/kubectl
    fi
fi

validate "kubectl works" "kubectl version --client &>/dev/null"

# =============================================================================
# Step 7: standalone helm
# =============================================================================
step "Install standalone helm"

if command -v helm &>/dev/null; then
    skip "helm is installed"
else
    echo -e "${YELLOW}  ▶ curl ... | bash (helm installer)${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

validate "helm works" "helm version --short &>/dev/null"

# =============================================================================
# Step 8: k9s (optional; non-fatal)
# =============================================================================
step "Install k9s (optional)"

if command -v k9s &>/dev/null; then
    skip "k9s is installed"
else
    if wget -q --timeout=15 https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz -O /tmp/k9s_Linux_amd64.tar.gz 2>/dev/null; then
        tar -xzf /tmp/k9s_Linux_amd64.tar.gz -C /tmp
        sudo chmod +x /tmp/k9s
        sudo mv /tmp/k9s /usr/local/bin/
        rm -f /tmp/k9s_Linux_amd64.tar.gz /tmp/LICENSE /tmp/README.md 2>/dev/null || true
        echo -e "${GREEN}  ✓ k9s installed${NC}"
    else
        echo -e "${YELLOW}  ⚠ k9s download failed, skipping (not required for tutorial)${NC}"
    fi
fi

# =============================================================================
# Step 9: uv (Python tooling used by notebooks)
# =============================================================================
step "Install uv"

# Newer uv installs to ~/.local/bin; older installers used ~/.cargo/bin.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

if command -v uv &>/dev/null; then
    skip "uv is installed ($(command -v uv))"
else
    echo -e "${YELLOW}  ▶ curl ... | sh (uv installer)${NC}"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    fix_owner "$HOME/.local" "$HOME/.cargo" 2>/dev/null || true
fi

if command -v uv &>/dev/null; then
    echo -e "${GREEN}  ✓ uv at $(command -v uv)${NC}"
else
    echo -e "${YELLOW}  ⚠ uv not found on PATH after install, continuing${NC}"
fi

# =============================================================================
# Step 10: local-path storage provisioner
# =============================================================================
step "Install local-path storage provisioner"

if kubectl get deployment local-path-provisioner -n local-path-storage &>/dev/null; then
    skip "local-path-provisioner deployed"
else
    run kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml
    echo -e "${YELLOW}  ▶ Waiting for provisioner...${NC}"
    kubectl wait --for=condition=available --timeout=60s deployment/local-path-provisioner -n local-path-storage
fi

if kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q "true"; then
    skip "local-path is default storage class"
else
    run kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

validate "storage class exists" "kubectl get storageclass local-path &>/dev/null"

# =============================================================================
# Step 11: Prometheus + Grafana (keep dashboard sidecars for Lab 2 ConfigMaps)
# =============================================================================
step "Install Prometheus + Grafana"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

if helm repo list 2>/dev/null | grep -q prometheus-community; then
    skip "prometheus-community helm repo"
else
    run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
run helm repo update

# Write values even on re-run so upgrades pick up current settings.
# Use a quoted heredoc + placeholder so password generation cannot break YAML.
if command -v openssl >/dev/null 2>&1; then
    GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/')
else
    GRAFANA_ADMIN_PASSWORD="admin-$(date +%s)"
fi

cat <<'VALEOF' | sed "s/__GRAFANA_PASSWORD__/${GRAFANA_ADMIN_PASSWORD}/" >/tmp/kube-prometheus-stack-values.yaml
grafana:
  enabled: true
  adminPassword: "__GRAFANA_PASSWORD__"
  grafana.ini:
    auth:
      disable_login_form: true
    auth.anonymous:
      enabled: true
      org_role: Viewer
    server:
      root_url: ""
  service:
    type: NodePort
    nodePort: 30080
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL
      env:
        SKIP_TLS_VERIFY: "true"
    datasources:
      enabled: true
      env:
        SKIP_TLS_VERIFY: "true"
VALEOF

if helm list -n monitoring 2>/dev/null | grep -q kube-prometheus-stack; then
    echo -e "${YELLOW}  ▶ helm upgrade kube-prometheus-stack (existing release)${NC}"
else
    echo -e "${YELLOW}  ▶ helm install kube-prometheus-stack (this takes several minutes)${NC}"
fi

MAX_RETRIES=3
RETRY_COUNT=0
while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
    if helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        -n monitoring \
        -f /tmp/kube-prometheus-stack-values.yaml \
        --wait \
        --timeout 10m; then
        echo -e "${GREEN}  ✓ kube-prometheus-stack installed/upgraded${NC}"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
            echo -e "${YELLOW}  ⚠ Helm install failed (attempt $RETRY_COUNT/$MAX_RETRIES), retrying in 10s...${NC}"
            sleep 10
        else
            echo -e "${RED}  ✗ Helm install failed after $MAX_RETRIES attempts${NC}"
            echo "    Retry manually with:"
            echo "    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring -f /tmp/kube-prometheus-stack-values.yaml --wait --timeout 10m"
            exit 1
        fi
    fi
done

# =============================================================================
# Step 12: Grove dashboards via ConfigMaps (sidecar auto-loads them for Lab 2)
# =============================================================================
step "Provision Grafana dashboard ConfigMaps"

kubectl apply -n monitoring -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster-overview
  labels:
    grafana_dashboard: "1"
data:
  cluster-overview.json: |
    {
      "annotations": {
        "list": [
          {
            "builtIn": 1,
            "datasource": "-- Grafana --",
            "enable": true,
            "hide": true,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard"
          }
        ]
      },
      "panels": [
        {
          "type": "stat",
          "title": "Nodes",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "count(kube_node_info)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "type": "stat",
          "title": "Pods",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "count(kube_pod_info)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 }
        },
        {
          "type": "stat",
          "title": "CPU Usage (cores)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{job=\"kubelet\",image!=\"\"}[5m]))",
              "refId": "A"
            }
          ],
          "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 }
        },
        {
          "type": "stat",
          "title": "Memory Usage (bytes)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{job=\"kubelet\",image!=\"\"})",
              "refId": "A"
            }
          ],
          "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "CPU Usage by Node",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) by (instance)", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        }
      ],
      "schemaVersion": 36,
      "title": "Kubernetes Cluster Overview",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-nats
  labels:
    grafana_dashboard: "1"
data:
  nats.json: |
    {
      "annotations": { "list": [] },
      "panels": [
        {
          "type": "stat",
          "title": "Connections",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_connections", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "type": "stat",
          "title": "In Msgs",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_in_msgs", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 }
        },
        {
          "type": "stat",
          "title": "Out Msgs",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_out_msgs", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 }
        },
        {
          "type": "stat",
          "title": "CPU (%)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_cpu", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "Message Rate",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "rate(nats_varz_in_msgs[5m])", "refId": "A" },
            { "expr": "rate(nats_varz_out_msgs[5m])", "refId": "B" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        }
      ],
      "schemaVersion": 36,
      "title": "NATS Overview",
      "uid": "04a62f8c-0edb-4cbc-911d-4618788b3189",
      "version": 2,
      "refresh": "30s",
      "timezone": "browser"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-etcd
  labels:
    grafana_dashboard: "1"
data:
  etcd.json: |
    {
      "annotations": { "list": [] },
      "panels": [
        {
          "type": "stat",
          "title": "Has Leader",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "max(etcd_server_has_leader)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "type": "stat",
          "title": "DB Size (bytes)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "max(etcd_mvcc_db_total_size_in_bytes)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "Proposals Committed",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "rate(etcd_server_proposals_committed_total[5m])", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        }
      ],
      "schemaVersion": 36,
      "title": "etcd Overview",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-dynamo-operator
  labels:
    grafana_dashboard: "1"
data:
  dynamo-operator.json: |
    {
      "annotations": { "list": [] },
      "panels": [
        {
          "type": "text",
          "title": "Notes",
          "options": {
            "content": "This dashboard uses controller-runtime metrics. If you have custom Dynamo metrics, update the queries accordingly.",
            "mode": "markdown"
          },
          "gridPos": { "h": 4, "w": 24, "x": 0, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "Reconciles (total)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(controller_runtime_reconcile_total{job=~\".*dynamo.*\"}[5m]))", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        },
        {
          "type": "timeseries",
          "title": "Reconcile Errors",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(controller_runtime_reconcile_errors_total{job=~\".*dynamo.*\"}[5m]))", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 }
        },
        {
          "type": "timeseries",
          "title": "Workqueue Depth",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(workqueue_depth{name=~\".*dynamo.*\"})", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 }
        }
      ],
      "schemaVersion": 36,
      "title": "Dynamo Operator",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
EOF

# Wait for the Grafana Deployment; do not hard-fail on HTTP health (NodePort /
# InternalIP reachability varies on Brev).
if kubectl wait --for=condition=available --timeout=180s deployment/kube-prometheus-stack-grafana -n monitoring; then
    echo -e "${GREEN}  ✓ Grafana deployment available${NC}"
else
    echo -e "${YELLOW}  ⚠ Grafana deployment not ready within timeout; check: kubectl get pods -n monitoring${NC}"
fi

echo -e "${GREEN}  ✓ Grove dashboards ConfigMaps applied (sidecar loads them for Lab 2)${NC}"
echo "    (NATS and etcd panels populate once Lab 3 installs those components)"

# Final permission fix for any files created while running as root
if [ "$(id -u)" -eq 0 ] && [ -d "$HOME/.kube" ]; then
    chown -R "$USER:$USER" "$HOME/.kube" 2>/dev/null || true
fi

# =============================================================================
# Summary
# =============================================================================
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)

echo ""
echo "Verifying installation..."
sudo microk8s status || true

echo ""
echo "kubectl binary: $(command -v kubectl)"
echo "helm binary:    $(command -v helm)"
echo "k9s binary:     $(command -v k9s 2>/dev/null || echo 'not installed')"
echo "uv binary:      $(command -v uv 2>/dev/null || echo 'not installed')"

export KUBECONFIG="$HOME/.kube/config"
kubectl version --client || true
echo ""
echo "Testing cluster access..."
kubectl get nodes 2>/dev/null && echo "✓ kubectl can access cluster without group membership!" || echo "⚠️  kubectl will work after sourcing shell config"

echo ""
echo "Testing helm..."
helm version --short 2>/dev/null && echo "✓ helm is ready!" || echo "⚠️  helm will work after sourcing shell config"

echo ""
echo "Verifying storage class..."
kubectl get storageclass || true

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ Kubernetes ready for Dynamo!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Kubeconfig: ~/.kube/config"
echo ""
echo "Quick start:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo "  kubectl get storageclass"
echo "  helm version"
echo "  k9s"
echo ""
echo "Grafana:"
if [ -n "${NODE_IP:-}" ]; then
    echo "  URL: http://${NODE_IP}:30080"
else
    echo "  URL: http://<node-ip>:30080"
fi
echo "  Anonymous access enabled as Viewer (no login required)"
echo "  Hint: kubectl get nodes -o wide"
echo ""
echo "Next steps:"
echo "  1. NGC auth for Dynamo images:"
echo "     helm registry login nvcr.io"
echo "     Username: \$oauthtoken"
echo "     Password: <NGC API key from https://ngc.nvidia.com/>"
echo ""
echo "  2. Start the guides:"
echo "     jupyter lab"
echo "     Then open: 01-dynamo-deployment-guide.ipynb"
echo ""
