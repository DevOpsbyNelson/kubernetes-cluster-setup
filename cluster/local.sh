#!/bin/bash
# Runs the service and the observability stack on a local Kubernetes: Docker Desktop or minikube.
#
# Usage, from the repository root (Git Bash on Windows, or any bash):
#   cluster/local.sh up       build the 7 images and deploy cluster/overlays/local
#   cluster/local.sh argocd   build the 7 images, install Argo CD and let it deploy
#                             cluster/overlays/local from GitHub (GitOps, like the EKS clusters)
#   cluster/local.sh status   show the pods and how to reach the apps
#   cluster/local.sh down     delete everything it deployed (volumes included, and Argo CD)
#
# Needs one of:
#   - Docker Desktop with Kubernetes turned on (Settings → Kubernetes → Enable Kubernetes)
#   - minikube, started with `minikube start`, plus Docker to build the images
# Every kubectl command targets the local context explicitly ("docker-desktop" or "minikube"),
# so it can never touch an EKS cluster, whatever your current context is.
#
# Optional environment variables:
#   LOCAL_CONTEXT            kubectl context to deploy to (default: docker-desktop if it exists,
#                            else minikube). For a minikube profile, use the profile name.
#   GRAFANA_ADMIN_PASSWORD   Grafana's admin password (default: admin). Only used on first start.
#   SLACK_WEBHOOK_URL        real Slack webhook for Alertmanager (default: a local placeholder; alerts
#   SLACK_ALERTS_CHANNEL     are then not delivered anywhere)
#   LOCAL_ARGOCD_BRANCH      branch Argo CD deploys from, for `argocd` (default: your current branch;
#                            it must be pushed to GitHub)
#   ARGOCD_ADMIN_PASSWORD    Argo CD's admin password, for `argocd` (default: admin). Set again on
#                            every run, which signs out open sessions. Local only: EKS keeps the
#                            random password Argo CD generates.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$REPO_DIR/cluster/overlays/local"
ARGOCD_INSTALL="$REPO_DIR/cluster/argocd/install"
ARGOCD_APP="$REPO_DIR/cluster/argocd/applications/local.yaml"
IMAGES="service alertmanager alloy grafana loki prometheus tempo"

# A shell alias such as `alias kubectl="minikube kubectl --"` isn't visible to scripts: fall back
# to minikube's bundled kubectl when there is no kubectl binary.
if command -v kubectl > /dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v minikube > /dev/null 2>&1; then
  KUBECTL=(minikube kubectl --)
else
  echo "ERROR: neither kubectl nor minikube is installed." >&2
  exit 1
fi

contexts() { "${KUBECTL[@]}" config get-contexts -o name 2> /dev/null; }

if [[ -n "${LOCAL_CONTEXT:-}" ]]; then
  CONTEXT="$LOCAL_CONTEXT"
elif contexts | grep -qx docker-desktop; then
  CONTEXT=docker-desktop
else
  CONTEXT=minikube
fi

k() { "${KUBECTL[@]}" --context "$CONTEXT" "$@"; }

# minikube names the kubectl context after the profile.
is_minikube() { [[ "$CONTEXT" != docker-desktop ]] && command -v minikube > /dev/null 2>&1 \
  && minikube -p "$CONTEXT" status > /dev/null 2>&1; }

# Windows tools (docker.exe) need Windows paths when Git Bash path conversion is off.
native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

require_cluster() {
  if ! contexts | grep -qx "$CONTEXT"; then
    echo "ERROR: no '$CONTEXT' kubectl context. Start a local cluster first, either:" >&2
    echo "       - Docker Desktop: Settings → Kubernetes → Enable Kubernetes → Apply & restart" >&2
    echo "       - minikube:       minikube start" >&2
    exit 1
  fi
  if ! k get nodes > /dev/null 2>&1; then
    echo "ERROR: the '$CONTEXT' cluster isn't answering. Wait until it's running" >&2
    echo "       (minikube: check with 'minikube status')." >&2
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

# minikube runs its own container runtime, which doesn't see the host's Docker images: copy them
# in. (`minikube image build` isn't used because service/.dockerignore excludes the Dockerfile,
# which minikube's containerd builder then can't find.)
load_images_into_minikube() {
  local name
  is_minikube || return 0
  for name in $IMAGES; do
    echo "Loading local/$name:dev into minikube"
    minikube -p "$CONTEXT" image load --overwrite=true "local/$name:dev"
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

argocd_app_exists() { k -n argocd get applications.argoproj.io eks-cluster > /dev/null 2>&1; }

# Installs Argo CD (the same pinned version as on EKS) and registers the local Application.
install_argocd() {
  local repo branch
  repo="$(sed -n 's/^ *repoURL: *//p' "$ARGOCD_APP")"
  branch="${LOCAL_ARGOCD_BRANCH:-$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)}"
  # Argo CD reads GitHub, not this folder: the branch must exist there.
  if ! git ls-remote --exit-code --heads "$repo" "$branch" > /dev/null 2>&1; then
    echo "ERROR: branch '$branch' isn't on $repo. Push it first, or set LOCAL_ARGOCD_BRANCH." >&2
    exit 1
  fi

  echo "Installing Argo CD"
  # Server-side: the CRDs are too large for a client-side apply.
  k apply --server-side --force-conflicts -k "$(native_path "$ARGOCD_INSTALL")" > /dev/null
  k wait --for condition=established --timeout=2m crd/applications.argoproj.io
  k -n argocd rollout status deployment/argocd-repo-server --timeout=5m
  k -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
  k -n argocd rollout status deployment/argocd-server --timeout=5m

  echo "Argo CD deploys cluster/overlays/local from branch '$branch'"
  sed "s|^\( *targetRevision:\).*|\1 $branch|" "$ARGOCD_APP" | k apply -f -
}

# Sets the admin password to ARGOCD_ADMIN_PASSWORD instead of the random one Argo CD generates.
# Argo CD keeps a bcrypt hash in argocd-secret: the argocd binary in the server pod makes it, so
# nothing extra needs installing here. The server applies the change without a restart.
set_argocd_password() {
  local hash
  hash="$(k -n argocd exec deploy/argocd-server -- argocd account bcrypt --password "${ARGOCD_ADMIN_PASSWORD:-admin}")"
  k -n argocd patch secret argocd-secret --type merge -p \
    "{\"stringData\":{\"admin.password\":\"$hash\",\"admin.passwordMtime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" > /dev/null
  # It only holds the first, random password, which no longer works.
  k -n argocd delete secret argocd-initial-admin-secret --ignore-not-found > /dev/null
  echo "Argo CD admin password set (ARGOCD_ADMIN_PASSWORD, default: admin)"
}

# Waits until Argo CD has deployed the branch's latest commit and every workload is healthy.
wait_for_argocd_sync() {
  local repo branch target revision sync health message attempt
  repo="$(sed -n 's/^ *repoURL: *//p' "$ARGOCD_APP")"
  branch="$(k -n argocd get applications.argoproj.io eks-cluster -o jsonpath='{.spec.source.targetRevision}')"
  target="$(git ls-remote "$repo" "refs/heads/$branch" | cut -f1)"
  k -n argocd annotate applications.argoproj.io eks-cluster argocd.argoproj.io/refresh=hard --overwrite > /dev/null
  status() { k -n argocd get applications.argoproj.io eks-cluster -o jsonpath="$1" 2> /dev/null || true; }
  for attempt in $(seq 1 60); do
    revision="$(status '{.status.sync.revision}')"
    sync="$(status '{.status.sync.status}')"
    health="$(status '{.status.health.status}')"
    message="$(status '{.status.health.message}')"
    echo "Argo CD: revision ${revision:0:7}, sync ${sync:-?}, health ${health:-?}"
    if [[ "$revision" == "$target" && "$sync" == Synced ]]; then
      if [[ "$health" == Healthy ]]; then
        return 0
      fi
      # Argo CD counts a LoadBalancer Service as Progressing until it has an external IP, which
      # minikube only gives while `minikube tunnel` runs. Everything else must be Healthy.
      if is_minikube && [[ "$health" == Progressing && "$message" == "Caused by Service:service/service-public" ]]; then
        echo "Argo CD: everything is Healthy except service-public, which waits for 'minikube tunnel'."
        return 0
      fi
    fi
    sleep 10
  done
  k -n argocd get applications.argoproj.io eks-cluster \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2
  echo "ERROR: Argo CD didn't reach Synced and Healthy for ${target:0:7} in 10 minutes." >&2
  exit 1
}

# The images keep the tag "dev": restart so pods pick up the images just built.
restart_workloads() {
  k -n service rollout restart deployment
  k -n observability rollout restart deployment,statefulset
}

delete_argocd() {
  if argocd_app_exists; then
    # The Application's finalizer deletes everything it deployed before the Application goes.
    echo "Deleting the Argo CD application and what it deployed"
    k -n argocd delete applications.argoproj.io eks-cluster --wait=true --timeout=5m
  fi
  if k get namespace argocd > /dev/null 2>&1; then
    echo "Uninstalling Argo CD"
    k delete -k "$(native_path "$ARGOCD_INSTALL")" --ignore-not-found --wait=true > /dev/null
  fi
}

show_status() {
  if argocd_app_exists; then
    k -n argocd get applications.argoproj.io eks-cluster
    echo
  fi
  k get pods -n service -o wide
  k get pods -n observability -o wide
  echo
  if is_minikube; then
    cat << EOF
The app:        kubectl --context $CONTEXT -n service port-forward svc/service 8080:80
                then http://localhost:8080/health/ping
                (or run 'minikube -p $CONTEXT tunnel' to give service-public an external IP)
EOF
  else
    cat << 'EOF'
The app:        http://localhost:8080          (service-public, a LoadBalancer on localhost)
                http://localhost:8080/health/ping
EOF
  fi
  cat << EOF
Grafana:        kubectl --context $CONTEXT -n observability port-forward svc/grafana 3000:3000
                then http://localhost:3000 (user admin, password GRAFANA_ADMIN_PASSWORD or "admin")
Prometheus:     kubectl --context $CONTEXT -n observability port-forward svc/prometheus 9090:9090
EOF
  if argocd_app_exists; then
    cat << EOF
Argo CD:        kubectl --context $CONTEXT -n argocd port-forward svc/argocd-server 8443:443
                then https://localhost:8443 (accept the self-signed certificate)
                user admin, password ARGOCD_ADMIN_PASSWORD or "admin"
EOF
  fi
}

case "${1:-}" in
  up)
    require_cluster
    build_images
    load_images_into_kind_node
    load_images_into_minikube
    apply_secrets
    if argocd_app_exists; then
      # Applying local files would fight Argo CD, which undoes anything that isn't in Git.
      echo "Argo CD manages this cluster: skipping kubectl apply. It deploys manifests from GitHub."
    else
      k apply -k "$(native_path "$OVERLAY")"
    fi
    restart_workloads
    wait_for_rollout
    show_status
    ;;
  argocd)
    require_cluster
    build_images
    load_images_into_kind_node
    load_images_into_minikube
    apply_secrets
    install_argocd
    set_argocd_password
    wait_for_argocd_sync
    restart_workloads
    wait_for_rollout
    show_status
    ;;
  status)
    require_cluster
    show_status
    ;;
  down)
    require_cluster
    # Argo CD first: otherwise it would recreate what is deleted below.
    delete_argocd
    # Deleting the namespaces also deletes their volumes and the local LoadBalancer.
    k delete -k "$(native_path "$OVERLAY")" --ignore-not-found --wait=true
    echo "Deleted. The local images (local/*:dev) are still in Docker: remove them with"
    echo "docker image rm local/service:dev local/alertmanager:dev local/alloy:dev local/grafana:dev local/loki:dev local/prometheus:dev local/tempo:dev"
    ;;
  *)
    echo "Usage: $0 up | argocd | status | down" >&2
    exit 1
    ;;
esac
