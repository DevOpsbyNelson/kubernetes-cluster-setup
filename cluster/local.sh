#!/bin/bash
# Runs the service and the observability stack on Docker Desktop's Kubernetes.
#
# Usage, from the repository root (Git Bash on Windows, or any bash):
#   cluster/local.sh up       build the 7 images and deploy cluster/overlays/local
#   cluster/local.sh status   show the pods and how to reach the apps
#   cluster/local.sh down     delete everything it deployed (volumes included)
#
# Needs Docker Desktop with Kubernetes turned on (Settings → Kubernetes → Enable Kubernetes).
# Every kubectl command targets the "docker-desktop" context explicitly, so it can never touch
# an EKS cluster, whatever your current context is.
#
# Optional environment variables:
#   GRAFANA_ADMIN_PASSWORD   Grafana's admin password (default: admin). Only used on first start.
#   SLACK_WEBHOOK_URL        real Slack webhook for Alertmanager (default: a local placeholder; alerts
#   SLACK_ALERTS_CHANNEL     are then not delivered anywhere)

set -euo pipefail

CONTEXT=docker-desktop
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$REPO_DIR/cluster/overlays/local"
k() { kubectl --context "$CONTEXT" "$@"; }

# Windows tools (docker.exe) need Windows paths when Git Bash path conversion is off.
native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

require_cluster() {
  if ! kubectl config get-contexts -o name 2> /dev/null | grep -qx "$CONTEXT"; then
    echo "ERROR: no '$CONTEXT' kubectl context. Turn on Kubernetes in Docker Desktop:" >&2
    echo "       Settings → Kubernetes → Enable Kubernetes → Apply & restart." >&2
    exit 1
  fi
  if ! k get nodes > /dev/null 2>&1; then
    echo "ERROR: Docker Desktop's Kubernetes isn't answering yet. Wait until it shows as running." >&2
    exit 1
  fi
}

build_images() {
  local entry name context
  for entry in service=service alertmanager=observability/alertmanager alloy=observability/alloy \
    grafana=observability/grafana loki=observability/loki prometheus=observability/prometheus \
    tempo=observability/tempo; do
    name="${entry%%=*}"
    context="${entry#*=}"
    echo "Building local/$name:dev"
    docker build --quiet --tag "local/$name:dev" "$(native_path "$REPO_DIR/$context")" > /dev/null
  done
}

# Docker Desktop has two Kubernetes modes. "kubeadm" uses Docker's own images. "kind" runs the
# node in a container (desktop-control-plane) with its own containerd image store, which doesn't
# see what `docker build` produces: copy the images into it.
load_images_into_kind_node() {
  local node=desktop-control-plane name
  docker inspect "$node" > /dev/null 2>&1 || return 0
  for name in service alertmanager alloy grafana loki prometheus tempo; do
    echo "Loading local/$name:dev into the kind node"
    docker save "local/$name:dev" | docker exec -i "$node" ctr -n k8s.io images import - > /dev/null
  done
}

apply_secrets() {
  local dir
  dir="$(mktemp -d)"
  # Not a Slack URL on purpose: alerts go nowhere locally, and a webhook-shaped placeholder would
  # trip secret scanners.
  printf '%s' "${SLACK_WEBHOOK_URL:-http://localhost:9/no-slack-locally}" > "$dir/SLACK_WEBHOOK_URL"
  printf '%s' "${SLACK_ALERTS_CHANNEL:-#local}" > "$dir/SLACK_ALERTS_CHANNEL"
  printf '%s' "${GRAFANA_ADMIN_PASSWORD:-admin}" > "$dir/GF_SECURITY_ADMIN_PASSWORD"
  printf '%s' "false" > "$dir/GF_AUTH_GITHUB_ENABLED"
  : > "$dir/GF_AUTH_GITHUB_CLIENT_ID"
  : > "$dir/GF_AUTH_GITHUB_CLIENT_SECRET"

  k apply -f "$(native_path "$REPO_DIR/cluster/base/namespaces.yaml")"
  k -n observability create secret generic alertmanager-slack \
    --from-file=SLACK_WEBHOOK_URL="$(native_path "$dir/SLACK_WEBHOOK_URL")" \
    --from-file=SLACK_ALERTS_CHANNEL="$(native_path "$dir/SLACK_ALERTS_CHANNEL")" \
    --dry-run=client -o yaml | k apply -f -
  k -n observability create secret generic grafana \
    --from-file=GF_SECURITY_ADMIN_PASSWORD="$(native_path "$dir/GF_SECURITY_ADMIN_PASSWORD")" \
    --from-file=GF_AUTH_GITHUB_ENABLED="$(native_path "$dir/GF_AUTH_GITHUB_ENABLED")" \
    --from-file=GF_AUTH_GITHUB_CLIENT_ID="$(native_path "$dir/GF_AUTH_GITHUB_CLIENT_ID")" \
    --from-file=GF_AUTH_GITHUB_CLIENT_SECRET="$(native_path "$dir/GF_AUTH_GITHUB_CLIENT_SECRET")" \
    --dry-run=client -o yaml | k apply -f -
  rm -rf "$dir"
}

wait_for_rollout() {
  local namespace workload
  for namespace in service observability; do
    for workload in $(k -n "$namespace" get deployment,statefulset -o name); do
      k -n "$namespace" rollout status "$workload" --timeout=10m
    done
  done
}

show_status() {
  k get pods -n service -o wide
  k get pods -n observability -o wide
  cat << 'EOF'

The app:        http://localhost:8080          (service-public, a LoadBalancer on localhost)
                http://localhost:8080/health/ping
Grafana:        kubectl --context docker-desktop -n observability port-forward svc/grafana 3000:3000
                then http://localhost:3000 (user admin, password GRAFANA_ADMIN_PASSWORD or "admin")
Prometheus:     kubectl --context docker-desktop -n observability port-forward svc/prometheus 9090:9090
EOF
}

case "${1:-}" in
  up)
    require_cluster
    build_images
    load_images_into_kind_node
    apply_secrets
    k apply -k "$(native_path "$OVERLAY")"
    # The images keep the tag "dev": restart so pods pick up the images just built.
    k -n service rollout restart deployment
    k -n observability rollout restart deployment,statefulset
    wait_for_rollout
    show_status
    ;;
  status)
    require_cluster
    show_status
    ;;
  down)
    require_cluster
    # Deleting the namespaces also deletes their volumes and the local LoadBalancer.
    k delete -k "$(native_path "$OVERLAY")" --ignore-not-found --wait=true
    echo "Deleted. The local images (local/*:dev) are still in Docker: remove them with"
    echo "docker image rm local/service:dev local/alertmanager:dev local/alloy:dev local/grafana:dev local/loki:dev local/prometheus:dev local/tempo:dev"
    ;;
  *)
    echo "Usage: $0 up | status | down" >&2
    exit 1
    ;;
esac
