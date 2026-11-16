#!/usr/bin/env bash
# EKS IMDS hop-limit validation lab.
#   ./demo.sh          run all steps
#   ./demo.sh 3        run only step 3 (for per-step recordings)
#   ./demo.sh prep     pre-create namespace/bucket so takes are clean
#   ./demo.sh reset    undo steps 5-6 so they can be re-recorded
#   PAUSE=5 ./demo.sh  longer pauses
source "$(dirname "$0")/lib.sh"

# Runs INSIDE the pod: reachability check only. It reads the role NAME and stops;
# it never requests the credentials document.
read -r -d '' PROBE <<'EOS'
IMDS=http://169.254.169.254
echo "[1] PUT $IMDS/latest/api/token  (IMDSv2 session token, 3s timeout)"
START=$(date +%s)
TOKEN=$(curl -s -m 3 -X PUT "$IMDS/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ELAPSED=$(( $(date +%s) - START ))
if [ -z "$TOKEN" ]; then
  echo "    no response after ${ELAPSED}s -> IMDS is NOT reachable from this pod"
  echo "RESULT: NOT EXPOSED"
  exit 0
fi
echo "    endpoint responded in ${ELAPSED}s (token received, not shown)"
echo "[2] GET $IMDS/latest/meta-data/iam/security-credentials/"
ROLE=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/latest/meta-data/iam/security-credentials/")
echo "    node role exposed to this pod: ${ROLE:-<none>}"
echo "RESULT: EXPOSED (pod can reach IMDS and sees the node role)"
EOS

ensure_ns() {
  kubectl get ns "$DEMO_NS" >/dev/null 2>&1 || kubectl create ns "$DEMO_NS" >/dev/null
  kubectl -n "$DEMO_NS" get sa s3-reader >/dev/null 2>&1 || kubectl -n "$DEMO_NS" create sa s3-reader >/dev/null
}

ensure_bucket() {
  if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    aws s3api put-bucket-tagging --bucket "$BUCKET" \
      --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG}]"
    echo "hello from the s3-reader pod's own identity" | \
      aws s3 cp - "s3://$BUCKET/hello.txt" >/dev/null
  fi
}

step1() {
  title "STEP 1 · Hop limit on each node group"
  for ng in default-config hardened; do
    local id; id=$(nodegroup_instance "$ng")
    say "$ng  ($id)"
    run aws ec2 describe-instances --instance-ids $id \
      --query 'Reservations[0].Instances[0].MetadataOptions.{HttpTokens:HttpTokens,HopLimit:HttpPutResponseHopLimit,Endpoint:HttpEndpoint}' \
      --output table
  done
  note "Hop limit 2 = the extra hop through the pod network can still reach IMDS."
  pause
}

step2() {
  title "STEP 2 · CHECK: pod with no AWS identity on the default-config node"
  say "Pod uses the default service account (no Pod Identity, no IRSA)."
  pause
  run_pod imds-check-default default-config default "$PROBE"
  note "This is the condition we want to eliminate."
  pause
}

step3() {
  title "STEP 3 · What the exposed node role can do"
  local role_arn role
  role_arn=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name default-config \
              --query nodegroup.nodeRole --output text)
  role=${role_arn##*/}
  say "Node role: $role"
  run aws iam list-attached-role-policies --role-name "$role" --output table
  run aws iam list-role-policies --role-name "$role" --output table
  note "Any pod that inherits this role gets ECR pull, EC2/ENI describe+modify (CNI),"
  note "SSM agent access and node-level EKS permissions. Not what an app pod needs."
  pause
}

step4() {
  title "STEP 4 · VERIFY FIX: same pod spec on the hardened node (hop limit 1)"
  pause
  run_pod imds-check-hardened hardened default "$PROBE"
  note "The PUT response is dropped after 1 hop, so the pod never gets a token."
  pause
}

step5() {
  title "STEP 5 · CORRECT PATTERN: give the pod its own least-privilege identity"
  ensure_ns; ensure_bucket
  if aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
       --namespace "$DEMO_NS" --service-account s3-reader \
       --query 'associations[0].associationId' --output text | grep -q '^a-'; then
    say "Pod identity association already exists:"
  else
    sed "s#__BUCKET__#$BUCKET#g" "$HERE/pod-identity-s3.yaml" > "$HERE/.pod-identity-s3.rendered.yaml"
    run eksctl create podidentityassociation -f "$HERE/.pod-identity-s3.rendered.yaml"
  fi
  run eksctl get podidentityassociation --cluster "$CLUSTER" --namespace "$DEMO_NS"
  pause
  read -r -d '' APP <<EOS
echo "[1] Credential source injected by EKS Pod Identity:"
echo "    AWS_CONTAINER_CREDENTIALS_FULL_URI=\$AWS_CONTAINER_CREDENTIALS_FULL_URI"
echo "[2] Who am I?"
aws sts get-caller-identity --query Arn --output text
echo "[3] Read the one allowed bucket:"
aws s3 ls s3://$BUCKET/
echo "[4] Try something not granted (list all buckets):"
aws s3 ls 2>&1 | tail -1
EOS
  run_pod s3-reader-hardened hardened s3-reader "$APP"
  note "Own role, scoped to one bucket, works on the hop-limit-1 node."
  note "Pod Identity uses the node-local agent (169.254.170.23), not IMDS."
  pause
}

EBS_CONFIG='{"controller":{"nodeSelector":{"demo/imds":"hardened"},"replicaCount":1,"extraVolumeTags":{"Project":"yt-eks-imds-demo"}},"node":{"nodeSelector":{"demo/imds":"hardened"}}}'

ebs_controller_status() {
  kubectl -n kube-system get pods -l app=ebs-csi-controller 2>&1 | awk '{printf "  %-40s %-6s %-18s %s\n", $1, $2, $3, $4}'
}

restart_ebs_controller() {
  kubectl -n kube-system rollout restart deploy/ebs-csi-controller >/dev/null
}

step6() {
  title "STEP 6 · Gotcha: add-ons that read IMDS (EBS CSI driver)"
  if ! aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
    say "Installing aws-ebs-csi-driver pinned to the hardened node (no identity yet)"
    aws eks create-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver \
      --tags Project=$PROJECT_TAG --configuration-values "$EBS_CONFIG" >/dev/null
    aws eks wait addon-active --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver 2>/dev/null || true
  fi
  # Start from the broken state so the take is repeatable
  if aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --namespace kube-system \
       --service-account ebs-csi-controller-sa --query 'associations[0].associationId' --output text | grep -q '^a-'; then
    eksctl delete podidentityassociation --cluster "$CLUSTER" --namespace kube-system \
      --service-account-name ebs-csi-controller-sa >/dev/null 2>&1
    sleep 10; restart_ebs_controller
  fi

  say "6a · Controller with NO identity on a hop-limit-1 node"
  note "It used to get the node role from IMDS. With hop limit 1 it can't."
  sleep 45
  ebs_controller_status
  say "Controller log:"
  kubectl -n kube-system logs deploy/ebs-csi-controller -c ebs-plugin --tail=40 2>&1 \
    | grep -m1 -E "IAM credentials|get identity|IMDS" | sed -E 's/^.*(DescribeAvailabilityZones, )/\1/; s/"$//' \
    | mask | fold -s -w 100 | head -4 | sed 's/^/  /'
  say "Node DaemonSet log (handles this on its own):"
  kubectl -n kube-system logs ds/ebs-csi-node -c ebs-plugin 2>&1 | grep -m1 "Retrieved metadata" | cut -c1-120
  pause

  say "6b · Fix: give the controller its own identity (Pod Identity)"
  run eksctl create podidentityassociation -f "$HERE/pod-identity-ebs.yaml"
  note "Wait a few seconds so new pods get the identity injected, then restart."
  sleep 15; restart_ebs_controller
  run kubectl -n kube-system rollout status deploy/ebs-csi-controller --timeout=180s
  ebs_controller_status
  say "Credential source now injected (names only):"
  kubectl -n kube-system get pod -l app=ebs-csi-controller --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[-1:].spec.containers[?(@.name=="ebs-plugin")].env[*]}{.name}{"\n"}{end}' \
    | grep -E 'AWS_CONTAINER_CREDENTIALS_FULL_URI|AWS_REGION' | sed 's/^/  /'
  pause

  say "6c · Prove it: provision a volume for a pod on the hardened node"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: demo-gp3 }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters: { type: gp3, tagSpecification_1: "Project=$PROJECT_TAG" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: demo-pvc, namespace: $DEMO_NS }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: demo-gp3
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: pvc-writer, namespace: $DEMO_NS }
spec:
  nodeSelector: { demo/imds: hardened }
  containers:
  - name: app
    image: public.ecr.aws/docker/library/busybox:1.37
    command: ["sh", "-c", "echo written-on-hardened-node > /data/proof && sleep 3600"]
    volumeMounts: [{ name: data, mountPath: /data }]
  volumes: [{ name: data, persistentVolumeClaim: { claimName: demo-pvc } }]
EOF
  kubectl -n "$DEMO_NS" wait --for=condition=Ready pod/pvc-writer --timeout=180s >/dev/null 2>&1
  run kubectl -n "$DEMO_NS" get pvc demo-pvc
  run kubectl -n "$DEMO_NS" exec pvc-writer -- cat /data/proof
  note "Lesson: before moving to hop limit 1, find every pod that silently used the"
  note "node role (CSI drivers, scanners, agents) and give it its own identity."
  pause
}

step7() {
  title "STEP 7 · Check YOUR cluster: who can reach IMDS, who depends on it"
  run "$HERE/audit.sh" "$CLUSTER"
  pause
}

prep()  { ensure_kubeconfig; ensure_ns; ensure_bucket; ok "namespace + bucket ready"; }
reset() {
  eksctl delete podidentityassociation --cluster "$CLUSTER" --namespace "$DEMO_NS" \
    --service-account-name s3-reader 2>&1 | tail -2
  kubectl -n "$DEMO_NS" delete pod pvc-writer --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$DEMO_NS" delete pvc demo-pvc --ignore-not-found --wait=true >/dev/null 2>&1
  ok "steps 5-6 reset (step 6 resets its own identity each run)"
}

main() {
  guard_account
  ensure_kubeconfig
  ensure_ns
  case "${1:-all}" in
    1|2|3|4|5|6|7) "step$1" ;;
    prep)  prep ;;
    reset) reset ;;
    all)   for s in 1 2 3 4 5 6 7; do "step$s"; done ;;
    *) echo "usage: $0 [1-7|all|prep|reset]"; exit 2 ;;
  esac
}
main "$@"
