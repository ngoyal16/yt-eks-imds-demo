# EKS IMDS hop limit lab

On many EKS managed node groups the IMDSv2 **hop limit is 2**. That lets any pod on the node
reach the instance metadata service (IMDS) and see, or use, the **node's IAM role**. This lab
shows the exposure, proves that hop limit 1 closes it, and shows the right pattern: EKS Pod Identity
gives each workload its own least-privilege role.

> ⚠️ **Use a dedicated sandbox AWS account.** The lab creates a real EKS cluster (about
> $0.27/hour in ap-south-1). The scripts refuse to run in any account except the one in `config.env`.

## What's here

| File | Purpose |
|---|---|
| [`audit.sh`](audit.sh) | **Read-only audit for any EKS cluster:** nodes and launch templates with hop limit > 1, and pods with no identity of their own. Run it against your own cluster. |
| `cluster.yaml` | eksctl config: 1 cluster, 2 node groups (`default-config` = hop 2, `hardened` = hop 1), Pod Identity agent |
| `demo.sh` | The 7 demo steps (`./demo.sh 1`…`7`, `all`, `prep`, `reset`) |
| `pod-identity-s3.yaml`, `pod-identity-ebs.yaml` | Pod Identity associations used in steps 5 and 6 |
| `teardown.sh` | Deletes everything, then checks for leftovers |
| `lib.sh` | Shared settings, account guard, credential masking |

## Audit your own cluster (no lab needed)

```bash
export AWS_PROFILE=<profile-for-that-account> AWS_REGION=<region>
aws eks update-kubeconfig --name <cluster>
./audit.sh <cluster>
```

Read the script before you run it. It only calls `describe`/`list`/`get`, and needs the aws CLI,
kubectl and python3.

## Run the lab

```bash
cp config.env.example config.env       # set AWS_PROFILE, AWS_REGION, EXPECTED_ACCOUNT
# edit cluster.yaml: publicAccessCIDRs -> your public IP (curl -s https://checkip.amazonaws.com)
eksctl create cluster -f cluster.yaml  # ~15–20 min
./demo.sh all                          # or one step: ./demo.sh 2
./teardown.sh                          # delete everything + leftover check
```

## The 7 steps

1. Hop limit on each node group (2 vs 1)
2. **Check:** a pod with no AWS identity on the hop-2 node reaches IMDS and sees the node role name.
   It stops there; it never requests the credentials.
3. What the node role can do (attached policies)
4. **Verify the fix:** the same pod on the hop-1 node gets no response
5. **Correct pattern:** a Pod Identity association gives one pod a role that can read one bucket
6. **Gotcha:** the EBS CSI controller breaks at hop 1 until it gets its own Pod Identity
7. `audit.sh` against the lab cluster

## Fix checklist

1. Set hop limit **1** on every node group launch template and Karpenter `EC2NodeClass`.
2. Give every pod that calls AWS its own identity with **EKS Pod Identity** or IRSA.
3. Run `audit.sh` first, so add-ons, scanners and agents that used the node role don't break.
4. Watch GuardDuty for `UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS`.

## License

MIT, see [LICENSE](LICENSE).
