#!/bin/bash
# Delete the AWS resources that Kubernetes created for a cluster, before Terraform destroys it.
# Usage: ENVIRONMENT=production ./scripts/delete-k8s-resources.sh
#
# Kubernetes creates AWS resources that Terraform doesn't track:
#   - load balancers (and their target groups and security groups) for LoadBalancer Services and
#     Ingresses: they keep using the public subnets, so deleting the VPC fails with DependencyViolation;
#   - EBS volumes for PersistentVolumeClaims: they outlive the cluster and keep billing.
#
# Two passes, so it also works when the cluster is already gone:
#   1. Through Kubernetes, if the cluster is ACTIVE: delete LoadBalancer Services, Ingresses and the
#      app namespaces, and wait until AWS has removed what they created.
#   2. Through the AWS API, always: delete what is still left, found by the tags Kubernetes puts on it
#      (kubernetes.io/cluster/<cluster> on load balancers, KubernetesCluster=<cluster> on volumes).
#
# Needs the AWS CLI and kubectl. Tests: infrastructure/tests/delete-k8s-resources.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${ENVIRONMENT:?ERROR: ENVIRONMENT is required (development | staging | production)}"
PROJECT_NAME="${PROJECT_NAME:-eks-cluster}"
CLUSTER="$PROJECT_NAME-$ENVIRONMENT"
REGION="${AWS_REGION:-us-east-1}"
NAMESPACES_FILE="${NAMESPACES_FILE:-$REPO_DIR/cluster/base/namespaces.yaml}"
POLL_SECONDS="${POLL_SECONDS:-10}" # tests set 0
CLUSTER_TAG="kubernetes.io/cluster/$CLUSTER"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

warn() { echo "::warning::$*"; }

# Prints the names in the first column whose comma-separated tag keys (second column) include
# CLUSTER_TAG. Input lines: "<name or ARN><TAB><key1,key2,...>", as AWS CLI text output gives them.
tagged_for_cluster() {
  awk -F '\t' -v tag="$CLUSTER_TAG" '{ n = split($2, keys, ","); for (i = 1; i <= n; i++) if (keys[i] == tag) { print $1; break } }'
}

# Splits whitespace-separated words into groups of at most 20 per line (AWS limit for describe-tags).
in_groups_of_20() { tr -s ' \t' '\n\n' | grep -v '^$' | grep -v '^None$' | paste -d ' ' - - - - - - - - - - - - - - - - - - - - | sed 's/ *$//'; }

# --- 1. Through Kubernetes --------------------------------------------------------------------
delete_through_kubernetes() {
  local status remaining=0
  if ! status="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.status --output text 2> "$TMP_DIR/describe.err")"; then
    if grep -q ResourceNotFoundException "$TMP_DIR/describe.err"; then
      echo "Cluster $CLUSTER doesn't exist: skipping the Kubernetes pass."
      return 0
    fi
    cat "$TMP_DIR/describe.err" >&2
    return 1
  fi
  if [ "$status" != "ACTIVE" ]; then
    warn "Cluster $CLUSTER is $status: skipping the Kubernetes pass, the AWS pass still runs."
    return 0
  fi

  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" > /dev/null

  # Deleting a LoadBalancer Service or an Ingress waits for its finalizer, which is only removed
  # once AWS has deleted the load balancer.
  kubectl get services --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    > "$TMP_DIR/services"
  while read -r namespace name; do
    [ -n "${name:-}" ] || continue
    echo "Deleting LoadBalancer Service $namespace/$name"
    kubectl -n "$namespace" delete service "$name" --wait=true --timeout=10m
  done < "$TMP_DIR/services"
  kubectl delete ingress --all-namespaces --all --wait=true --timeout=10m

  # The app namespaces hold the PersistentVolumeClaims; the EBS CSI driver (still running in
  # kube-system) deletes the volume behind each one.
  kubectl delete -f "$NAMESPACES_FILE" --ignore-not-found --wait=true --timeout=15m
  for _ in $(seq 1 30); do
    remaining="$(kubectl get persistentvolumes --no-headers 2> /dev/null | grep -c . || true)"
    [ "$remaining" -eq 0 ] && break
    echo "Waiting for $remaining PersistentVolume(s) to be deleted..."
    sleep "$POLL_SECONDS"
  done
  if [ "$remaining" -ne 0 ]; then
    warn "$remaining PersistentVolume(s) were not deleted through Kubernetes; the AWS pass will look for their volumes."
  fi
}

# --- 2. Through the AWS API -------------------------------------------------------------------
delete_load_balancers_v2() {
  local arns tagged=""
  arns="$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text)"
  while read -r group; do
    [ -n "$group" ] || continue
    # shellcheck disable=SC2086 # one argument per ARN
    tagged+="$(aws elbv2 describe-tags --region "$REGION" --resource-arns $group \
      --query 'TagDescriptions[].[ResourceArn, join(`,`, Tags[].Key)]' --output text | tagged_for_cluster)"$'\n'
  done < <(printf '%s\n' "$arns" | in_groups_of_20)

  for arn in $tagged; do
    echo "Deleting load balancer $arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn"
    aws elbv2 wait load-balancers-deleted --region "$REGION" --load-balancer-arns "$arn"
  done
}

delete_target_groups() {
  local arns tagged=""
  arns="$(aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[].TargetGroupArn' --output text)"
  while read -r group; do
    [ -n "$group" ] || continue
    # shellcheck disable=SC2086
    tagged+="$(aws elbv2 describe-tags --region "$REGION" --resource-arns $group \
      --query 'TagDescriptions[].[ResourceArn, join(`,`, Tags[].Key)]' --output text | tagged_for_cluster)"$'\n'
  done < <(printf '%s\n' "$arns" | in_groups_of_20)

  for arn in $tagged; do
    echo "Deleting target group $arn"
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn"
  done
}

# Classic load balancers: what a LoadBalancer Service gets without the "nlb" annotation.
delete_classic_load_balancers() {
  local names tagged=""
  names="$(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text)"
  while read -r group; do
    [ -n "$group" ] || continue
    # shellcheck disable=SC2086
    tagged+="$(aws elb describe-tags --region "$REGION" --load-balancer-names $group \
      --query 'TagDescriptions[].[LoadBalancerName, join(`,`, Tags[].Key)]' --output text | tagged_for_cluster)"$'\n'
  done < <(printf '%s\n' "$names" | in_groups_of_20)

  for name in $tagged; do
    echo "Deleting classic load balancer $name"
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name"
  done
}

# Security groups Kubernetes creates for classic load balancers (k8s-elb-...). Their network
# interfaces take a moment to go away after the load balancer, hence the retries.
delete_load_balancer_security_groups() {
  local ids
  ids="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag-key,Values=$CLUSTER_TAG" "Name=group-name,Values=k8s-elb-*" \
    --query 'SecurityGroups[].GroupId' --output text)"
  for id in $ids; do
    [ "$id" != "None" ] || continue
    echo "Deleting security group $id"
    for attempt in $(seq 1 18); do
      aws ec2 delete-security-group --region "$REGION" --group-id "$id" 2> "$TMP_DIR/sg.err" && break
      if [ "$attempt" -eq 18 ]; then
        cat "$TMP_DIR/sg.err" >&2
        warn "Security group $id could not be deleted."
      fi
      sleep "$POLL_SECONDS"
    done
  done
}

delete_volumes() {
  local ids
  ids="$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" "Name=tag:KubernetesCluster,Values=$CLUSTER" \
    --query 'Volumes[].VolumeId' --output text)"
  for id in $ids; do
    [ "$id" != "None" ] || continue
    echo "Deleting volume $id"
    aws ec2 delete-volume --region "$REGION" --volume-id "$id"
  done
}

echo "Cleaning up AWS resources created by Kubernetes for $CLUSTER..."
delete_through_kubernetes
delete_load_balancers_v2
delete_target_groups
delete_classic_load_balancers
delete_load_balancer_security_groups
delete_volumes
echo "Done: no Kubernetes-created load balancers or volumes are left for $CLUSTER."
