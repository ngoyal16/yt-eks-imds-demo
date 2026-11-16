#!/usr/bin/env bash
# Tear down everything for yt-eks-imds-demo, then check for leftovers.
source "$(dirname "$0")/lib.sh"
guard_account

# The API endpoint only allows the IP the cluster was created from. If your IP has changed
# (another network), kubectl and eksctl's cleanup can't reach the cluster, so allow it first.
title "0 · Make sure the cluster API is reachable from this machine"
if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  MY_IP="$(curl -s --max-time 10 https://checkip.amazonaws.com)/32"
  CIDRS=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text)
  if [[ " $CIDRS " == *" 0.0.0.0/0 "* || " $CIDRS " == *" $MY_IP "* ]]; then
    note "endpoint already allows $MY_IP"
  else
    say "Endpoint allows [$CIDRS]; adding $MY_IP for teardown"
    aws eks update-cluster-config --name "$CLUSTER" \
      --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs="$MY_IP" >/dev/null
    sleep 30; aws eks wait cluster-active --name "$CLUSTER"
    rm -f "$KUBECONFIG"
  fi
fi

title "1 · Delete demo workloads (PVCs first so EBS volumes are released)"
if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  ensure_kubeconfig
  kubectl delete ns "$DEMO_NS" --ignore-not-found --wait=true --timeout=180s 2>&1 | tail -1
fi

title "2 · Delete pod identity associations"
for a in $(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
            --query 'associations[].[namespace,serviceAccount]' --output text 2>/dev/null | tr '\t' ':'); do
  ns=${a%%:*}; sa=${a##*:}
  run eksctl delete podidentityassociation --cluster "$CLUSTER" --namespace "$ns" --service-account-name "$sa"
done

title "3 · Delete demo S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  run aws s3 rb "s3://$BUCKET" --force
else
  note "bucket $BUCKET not present"
fi

title "4 · eksctl delete cluster"
if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  run eksctl delete cluster -f "$HERE/cluster.yaml" --wait
else
  note "cluster not present"
fi
rm -f "$KUBECONFIG"

title "5 · Leftover check"
say "CloudFormation stacks (eksctl-$CLUSTER-*, not DELETE_COMPLETE):"
aws cloudformation list-stacks \
  --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER') && StackStatus!='DELETE_COMPLETE'].[StackName,StackStatus]" --output text
say "ENIs tagged for the cluster:"
aws ec2 describe-network-interfaces --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text
aws ec2 describe-network-interfaces --filters "Name=description,Values=*$CLUSTER*" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output text
say "Load balancers tagged for the cluster:"
for arn in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text); do
  aws elbv2 describe-tags --resource-arns "$arn" \
    --query "TagDescriptions[?Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER']].ResourceArn" --output text
done
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text | tr '\t' '\n' | \
  while read -r n; do [[ -n "$n" ]] && aws elb describe-tags --load-balancer-names "$n" \
    --query "TagDescriptions[?Tags[?Key=='kubernetes.io/cluster/$CLUSTER']].LoadBalancerName" --output text; done
say "EBS volumes for the cluster:"
aws ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
  --query 'Volumes[].[VolumeId,State]' --output text
aws ec2 describe-volumes --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Volumes[].[VolumeId,State]' --output text
say "IAM roles containing '$CLUSTER':"
aws iam list-roles --query "Roles[?contains(RoleName,'$CLUSTER')].RoleName" --output text
say "Anything still tagged Project=$PROJECT_TAG (tagging API, may lag a few minutes):"
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT_TAG" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
ok "Leftover check finished (empty sections = clean)"
