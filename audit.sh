#!/usr/bin/env bash
# audit.sh <cluster-name>
# Read-only check of one EKS cluster:
#   1. Which nodes let pods reach IMDS (hop limit > 1, IMDSv1 allowed)
#   2. Whether node groups will launch NEW nodes fixed (launch template settings)
#   3. Which pods have no AWS identity of their own (they use the node role via IMDS
#      today, or will break when you move to hop limit 1)
# Needs: aws CLI, kubectl pointed at the cluster, python3. Changes nothing.
set -uo pipefail
CLUSTER=${1:?usage: audit.sh <cluster-name>}
export AWS_PAGER=""
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 1. Nodes: can pods reach IMDS?"
kubectl get nodes -o json > "$TMP/nodes.json"
IDS=$(python3 -c 'import json,sys
for n in json.load(open(sys.argv[1]))["items"]:
    print(n["spec"].get("providerID","").rsplit("/",1)[-1])' "$TMP/nodes.json" | tr '\n' ' ')
aws ec2 describe-instances --instance-ids $IDS --output json > "$TMP/inst.json"
python3 - "$TMP/nodes.json" "$TMP/inst.json" > "$TMP/hop.tsv" <<'PY'
import json, sys
nodes = json.load(open(sys.argv[1]))["items"]
inst = {i["InstanceId"]: i for r in json.load(open(sys.argv[2]))["Reservations"] for i in r["Instances"]}
for n in nodes:
    iid = n["spec"].get("providerID", "").rsplit("/", 1)[-1]
    m = inst.get(iid, {}).get("MetadataOptions", {})
    ng = n["metadata"]["labels"].get("eks.amazonaws.com/nodegroup", n["metadata"]["labels"].get("karpenter.sh/nodepool", "-"))
    print("\t".join([n["metadata"]["name"], iid, ng, m.get("HttpTokens", "?"), str(m.get("HttpPutResponseHopLimit", "?"))]))
PY
printf '  %-14s %-22s %-10s %-4s %s\n' NODEGROUP INSTANCE IMDSv2 HOP VERDICT
while IFS=$'\t' read -r node iid ng tokens hop; do
  v="OK"; [[ "$hop" != 1 ]] && v="AT RISK: pods can reach IMDS"
  [[ "$tokens" != required ]] && v="AT RISK: IMDSv1 allowed${hop:+, hop $hop}"
  printf '  %-14s %-22s %-10s %-4s %s\n' "$ng" "$iid" "$tokens" "$hop" "$v"
done < "$TMP/hop.tsv"

echo
echo "== 2. Managed node groups: will NEW nodes launch fixed?"
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output text); do
  read -r lt ver < <(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
    --query '[nodegroup.launchTemplate.id,nodegroup.launchTemplate.version]' --output text)
  if [[ "$lt" == None ]]; then
    printf '  %-14s no launch template (EKS default: hop limit 2)\n' "$ng"; continue
  fi
  read -r tokens hop < <(aws ec2 describe-launch-template-versions --launch-template-id "$lt" --versions "$ver" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.MetadataOptions.[HttpTokens,HttpPutResponseHopLimit]' --output text)
  v="OK"; [[ "$hop" != 1 ]] && v="AT RISK"
  printf '  %-14s launch template %s v%s: HttpTokens=%s HopLimit=%s  %s\n' "$ng" "$lt" "$ver" "$tokens" "$hop" "$v"
done

echo
echo "== 3. Pods with no AWS identity of their own"
aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --query 'associations[].[namespace,serviceAccount]' --output text > "$TMP/pia.tsv"
kubectl get pods -A -o json > "$TMP/pods.json"
kubectl get sa -A -o json > "$TMP/sa.json"
python3 - "$TMP/pods.json" "$TMP/sa.json" "$TMP/pia.tsv" "$TMP/hop.tsv" <<'PY'
import json, sys
pods = json.load(open(sys.argv[1]))["items"]
irsa = {(s["metadata"]["namespace"], s["metadata"]["name"])
        for s in json.load(open(sys.argv[2]))["items"]
        if "eks.amazonaws.com/role-arn" in s["metadata"].get("annotations", {})}
pia = {tuple(l.split("\t")[:2]) for l in open(sys.argv[3]).read().splitlines() if l.strip()}
hop = {l.split("\t")[0]: l.split("\t")[4] for l in open(sys.argv[4]).read().splitlines() if l.strip()}
rows = []
for p in pods:
    if p["status"].get("phase") not in ("Running", "Pending"):
        continue
    ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
    sa = p["spec"].get("serviceAccountName", "default")
    h = hop.get(p["spec"].get("nodeName", ""), "?")
    if p["spec"].get("hostNetwork"):
        ident, v = "host-network", "reaches IMDS directly at any hop limit; keep to trusted system pods"
    elif (ns, sa) in pia:
        ident = "pod-identity"
        v = "own identity" + ("" if h == "1" else ", but IMDS still reachable (hop %s)" % h)
    elif (ns, sa) in irsa:
        ident = "irsa"
        v = "own identity" + ("" if h == "1" else ", but IMDS still reachable (hop %s)" % h)
    else:
        ident = "NONE"
        v = ("CAN TAKE NODE ROLE via IMDS (hop %s)" % h) if h != "1" else \
            "no identity: fine unless it calls AWS (then it's broken)"
    rows.append((ident != "NONE", ns + "/" + name, sa, ident, v))
print("  %-48s %-26s %-13s %s" % ("POD", "SERVICE ACCOUNT", "IDENTITY", "VERDICT"))
for _, pod, sa, ident, v in sorted(rows):
    print("  %-48s %-26s %-13s %s" % (pod[:48], sa[:26], ident, v))
PY

echo
echo "Fix: hop limit 1 on every node group/NodeClass + Pod Identity (or IRSA) for every pod that calls AWS."
echo "Detect: GuardDuty finding UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS"
