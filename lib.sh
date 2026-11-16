#!/usr/bin/env bash
# Shared settings + helpers for demo.sh / teardown.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Your account settings live in config.env (git-ignored). Copy config.env.example to start.
[[ -f "$HERE/config.env" ]] && source "$HERE/config.env"
export AWS_PROFILE="${AWS_PROFILE:?set AWS_PROFILE in config.env}"
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_PAGER=""
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:?set EXPECTED_ACCOUNT in config.env (scripts refuse to run anywhere else)}"
CLUSTER=yt-eks-imds-demo
PROJECT_TAG=yt-eks-imds-demo
BUCKET="${BUCKET:-yt-eks-imds-demo-${EXPECTED_ACCOUNT}-${AWS_REGION}}"
DEMO_NS=demo
POD_IMAGE=public.ecr.aws/aws-cli/aws-cli:2.31.0
export KUBECONFIG="$HERE/.kubeconfig"
PAUSE="${PAUSE:-3}"

BOLD=$'\033[1m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'

# Mask credential values: keep first 4 chars, then ****.
# Handles JSON ("Key" : "value") and env/text (Key=value, Key: value).
mask() {
  sed -E 's/("?(AccessKeyId|SecretAccessKey|SessionToken|Token)"?[[:space:]]*[:=][[:space:]]*"?)([A-Za-z0-9/+=]{4})[A-Za-z0-9/+=_-]*/\1\3****/g'
}

title() { printf '\n%s%s━━ %s ━━%s\n' "$BOLD" "$CYAN" "$*" "$RST"; }
say()   { printf '%s▸ %s%s\n' "$BOLD" "$*" "$RST"; }
ok()    { printf '%s✔ %s%s\n' "$GREEN" "$*" "$RST"; }
bad()   { printf '%s✘ %s%s\n' "$RED" "$*" "$RST"; }
note()  { printf '%s%s%s\n' "$DIM" "$*" "$RST"; }
pause() { sleep "$PAUSE"; }
# Show a command, then run it with masked output
run()   { printf '%s$ %s%s\n' "$DIM" "$*" "$RST"; "$@" 2>&1 | mask; }

guard_account() {
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  if [[ "$acct" != "$EXPECTED_ACCOUNT" ]]; then
    bad "Account is '${acct:-unknown}', expected $EXPECTED_ACCOUNT. Refusing to continue."
    exit 1
  fi
}

ensure_kubeconfig() {
  [[ -s "$KUBECONFIG" ]] || aws eks update-kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
}

nodegroup_instance() { # $1 = nodegroup name -> instance id
  aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" "Name=tag:eks:nodegroup-name,Values=$1" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# run_pod NAME NODE_LABEL SERVICE_ACCOUNT SCRIPT
# Runs a one-shot aws-cli pod pinned to a node group, prints masked logs, deletes the pod.
run_pod() {
  local name=$1 node=$2 sa=$3 script=$4
  kubectl -n "$DEMO_NS" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $DEMO_NS
spec:
  restartPolicy: Never
  serviceAccountName: $sa
  nodeSelector:
    demo/imds: $node
  containers:
  - name: aws
    image: $POD_IMAGE
    command: ["bash", "-c"]
    args:
    - |
$(printf '%s\n' "$script" | sed 's/^/      /')
    env:
    - { name: AWS_DEFAULT_REGION, value: "$AWS_REGION" }
    - { name: AWS_METADATA_SERVICE_TIMEOUT, value: "2" }
    - { name: AWS_METADATA_SERVICE_NUM_ATTEMPTS, value: "1" }
EOF
  note "pod/$name  node=demo/imds=$node  serviceAccount=$sa"
  local phase=""
  for _ in $(seq 1 90); do
    phase=$(kubectl -n "$DEMO_NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 2
  done
  kubectl -n "$DEMO_NS" logs "$name" 2>&1 | mask
  kubectl -n "$DEMO_NS" delete pod "$name" --wait=false >/dev/null 2>&1
}
