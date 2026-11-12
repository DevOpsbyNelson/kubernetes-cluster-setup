#!/bin/bash
# Tests for scripts/delete-k8s-resources.sh and for the destroy order in the Infrastructure workflow.
# The aws and kubectl commands are replaced by fakes that record their arguments and print canned
# answers, so nothing touches AWS or a cluster.
# Run from anywhere: bash infrastructure/tests/delete-k8s-resources.test.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../scripts/delete-k8s-resources.sh"
WORKFLOW="$TESTS_DIR/../../.github/workflows/infrastructure.yml"

failures=0
passes=0
pass() { passes=$((passes + 1)); echo "  ok: $1"; }
fail() { failures=$((failures + 1)); echo "  FAIL: $1"; }

expect_call() { # <description> <regex>
  if grep -Eq -- "$2" "$CALLS"; then pass "$1"; else fail "$1 (no call matching: $2)"; fi
}
expect_no_call() { # <description> <regex>
  if grep -Eq -- "$2" "$CALLS"; then fail "$1 (unexpected call: $(grep -E -- "$2" "$CALLS" | head -1))"; else pass "$1"; fi
}

THIS_LB="arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/net/aaaa/1111"
OTHER_LB="arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/net/bbbb/2222"
THIS_TG="arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/k8s-this/3333"
OTHER_TG="arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/other/4444"

# Builds fake aws/kubectl commands in a temporary bin directory and runs the script with them.
# Scenario variables: CLUSTER_STATE (ACTIVE | CREATING | missing), K8S_LB_SERVICES.
run_script() {
  WORK="$(mktemp -d)"
  CALLS="$WORK/calls"
  : > "$CALLS"
  mkdir -p "$WORK/bin"

  cat > "$WORK/bin/aws" << 'EOF'
#!/bin/bash
echo "aws $*" >> "$CALLS"
case "$1 $2" in
  "eks describe-cluster")
    if [ "$CLUSTER_STATE" = "missing" ]; then
      echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found" >&2
      exit 254
    fi
    echo "$CLUSTER_STATE" ;;
  "elbv2 describe-load-balancers") printf '%s\t%s\n' "$THIS_LB" "$OTHER_LB" ;;
  "elbv2 describe-target-groups") printf '%s\t%s\n' "$THIS_TG" "$OTHER_TG" ;;
  "elbv2 describe-tags")
    case "$*" in
      *loadbalancer/*)
        printf '%s\t%s\n' "$THIS_LB" "kubernetes.io/cluster/eks-cluster-production,kubernetes.io/service-name"
        printf '%s\t%s\n' "$OTHER_LB" "kubernetes.io/cluster/eks-cluster-staging" ;;
      *targetgroup/*)
        printf '%s\t%s\n' "$THIS_TG" "kubernetes.io/service-name,kubernetes.io/cluster/eks-cluster-production"
        printf '%s\t%s\n' "$OTHER_TG" "Name" ;;
    esac ;;
  "elb describe-load-balancers") printf '%s\t%s\n' "this-classic" "other-classic" ;;
  "elb describe-tags")
    printf '%s\t%s\n' "this-classic" "kubernetes.io/cluster/eks-cluster-production"
    printf '%s\t%s\n' "other-classic" "kubernetes.io/cluster/eks-cluster-production-old" ;;
  "ec2 describe-security-groups") echo "sg-0123" ;;
  "ec2 describe-volumes") printf '%s\t%s\n' "vol-aaa" "vol-bbb" ;;
esac
exit 0
EOF

  cat > "$WORK/bin/kubectl" << 'EOF'
#!/bin/bash
echo "kubectl $*" >> "$CALLS"
case "$*" in
  "get services"*) printf '%s' "$K8S_LB_SERVICES" ;;
  "get persistentvolumes"*) : ;;
esac
exit 0
EOF
  chmod +x "$WORK/bin/aws" "$WORK/bin/kubectl"

  export CALLS THIS_LB OTHER_LB THIS_TG OTHER_TG
  OUTPUT="$(PATH="$WORK/bin:$PATH" ENVIRONMENT=production POLL_SECONDS=0 bash "$SCRIPT" 2>&1)"
  STATUS=$?
}

echo "Cluster still running: clean up through Kubernetes, then sweep AWS"
CLUSTER_STATE=ACTIVE K8S_LB_SERVICES=$'service service-public\nother-ns web-public\n'
export CLUSTER_STATE K8S_LB_SERVICES
run_script
[ "$STATUS" -eq 0 ] && pass "script succeeds" || fail "script failed: $OUTPUT"
expect_call "connects kubectl to the cluster" '^aws eks update-kubeconfig --name eks-cluster-production'
expect_call "deletes the LoadBalancer Service service/service-public and waits" '^kubectl -n service delete service service-public --wait=true'
expect_call "deletes LoadBalancer Services in other namespaces too" '^kubectl -n other-ns delete service web-public'
expect_call "deletes all Ingresses" '^kubectl delete ingress --all-namespaces --all --wait=true'
expect_call "deletes the app namespaces, which deletes their volumes" '^kubectl delete -f .*cluster/base/namespaces.yaml'
expect_call "deletes this cluster's load balancer left in AWS" "^aws elbv2 delete-load-balancer .*--load-balancer-arn $THIS_LB"
expect_no_call "keeps another cluster's load balancer" "delete-load-balancer .*$OTHER_LB"
expect_call "waits until the load balancer is gone" "^aws elbv2 wait load-balancers-deleted .*$THIS_LB"
expect_call "deletes this cluster's target group" "^aws elbv2 delete-target-group .*$THIS_TG"
expect_no_call "keeps untagged target groups" "delete-target-group .*$OTHER_TG"
expect_call "deletes this cluster's classic load balancer" '^aws elb delete-load-balancer .*--load-balancer-name this-classic'
expect_no_call "keeps a classic load balancer of a cluster with a longer name" 'delete-load-balancer .*other-classic'
expect_call "looks for k8s-elb security groups of this cluster" '^aws ec2 describe-security-groups .*kubernetes.io/cluster/eks-cluster-production.*group-name,Values=k8s-elb-'
expect_call "deletes them" '^aws ec2 delete-security-group .*--group-id sg-0123'
expect_call "only looks for unattached volumes of this cluster" '^aws ec2 describe-volumes .*Name=status,Values=available.*Name=tag:KubernetesCluster,Values=eks-cluster-production'
expect_call "deletes the first volume" '^aws ec2 delete-volume .*--volume-id vol-aaa'
expect_call "deletes the second volume" '^aws ec2 delete-volume .*--volume-id vol-bbb'
rm -rf "$WORK"

echo "Cluster already gone (the case that blocked the VPC): skip Kubernetes, still sweep AWS"
CLUSTER_STATE=missing
run_script
[ "$STATUS" -eq 0 ] && pass "script succeeds without a cluster" || fail "script failed: $OUTPUT"
expect_no_call "doesn't call kubectl" '^kubectl'
expect_call "still deletes the leftover load balancer" "^aws elbv2 delete-load-balancer .*$THIS_LB"
expect_call "still deletes the leftover volumes" '^aws ec2 delete-volume .*vol-aaa'
rm -rf "$WORK"

echo "Cluster not ACTIVE: skip Kubernetes with a warning, still sweep AWS"
CLUSTER_STATE=CREATING
run_script
[ "$STATUS" -eq 0 ] && pass "script succeeds" || fail "script failed: $OUTPUT"
grep -q '::warning::Cluster eks-cluster-production is CREATING' <<< "$OUTPUT" && pass "warns about the cluster state" || fail "no warning: $OUTPUT"
expect_no_call "doesn't call kubectl" '^kubectl'
expect_call "still deletes the leftover load balancer" "^aws elbv2 delete-load-balancer .*$THIS_LB"
rm -rf "$WORK"

echo "Infrastructure workflow: destroy cleans up before Terraform"
cleanup_line="$(grep -n 'scripts/delete-k8s-resources.sh' "$WORKFLOW" | head -1 | cut -d: -f1)"
terraform_line="$(grep -n 'terraform-run.sh destroy' "$WORKFLOW" | head -1 | cut -d: -f1)"
if [ -n "$cleanup_line" ] && [ -n "$terraform_line" ] && [ "$cleanup_line" -lt "$terraform_line" ]; then
  pass "the cleanup runs before terraform destroy"
else
  fail "the cleanup must come before terraform destroy in $WORKFLOW (cleanup line: ${cleanup_line:-none}, destroy line: ${terraform_line:-none})"
fi
step="$(awk '/- name: Delete AWS resources created by Kubernetes/{f=1} f&&/^      - name: Terraform/{exit} f' "$WORKFLOW")"
grep -q "if: env.ACTION == 'destroy'" <<< "$step" && pass "the cleanup only runs on destroy" || fail "the cleanup step must have: if: env.ACTION == 'destroy'"

echo
echo "$passes passed, $failures failed."
[ "$failures" -eq 0 ]
