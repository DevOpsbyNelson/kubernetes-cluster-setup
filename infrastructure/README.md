# EKS cluster infrastructure

Terraform code that runs a Kubernetes cluster on AWS EKS:

```
                 ┌───────────────────── VPC ─────────────────────┐
Internet ──▶ IGW ──▶ public subnets (NAT gateways, internet LBs)  │
                 │        │                                       │
                 │        ▼                                       │
                 │   private subnets (nodes, pods, internal LBs)  │
                 └────────┬──────────────────────────────────────┘
                          ▼
              EKS control plane (private + public API endpoint)
```

- **Network**: a VPC with public and private subnets in 2 to 4 availability zones. Nodes only live in private subnets. Subnets are tagged so load balancers can find them.
- **Cluster**:
  - Access through IAM access entries only (no `aws-auth` ConfigMap).
  - Kubernetes secrets encrypted with a rotating KMS key.
  - Control plane logs in CloudWatch, with a per-stage retention.
- **Nodes**: one managed node group on Amazon Linux 2023, with encrypted gp3 disks and IMDSv2 required.
- **Add-ons**: VPC CNI, kube-proxy, CoreDNS, Pod Identity agent and the EBS CSI driver, at the version EKS recommends for the cluster's Kubernetes version.
- **Stages**: `development`, `staging` and `production`, one Terraform workspace each.
- **State**: kept in S3 (remote backend), one state file per workspace.

## Layout

```
infrastructure/
├── versions.tf               # Terraform/provider versions, S3 backend, default tags
├── variables.tf              # region, project name, API access, per-stage settings
├── stage.tf                  # workspace → stage mapping and guard
├── main.tf                   # calls modules/vpc and modules/eks
├── outputs.tf                # cluster name, endpoint, kubectl command, network IDs
├── tests/                    # root tests (stage wiring)
├── scripts/
│   ├── common.sh                  # shared helpers (+ loads .env)
│   ├── bootstrap-state-bucket.sh  # creates the S3 bucket for Terraform state
│   ├── terraform-init.sh          # terraform init with the S3 backend + selects workspace
│   └── terraform-run.sh           # init, then any terraform command for ENVIRONMENT
└── modules/
    ├── vpc/                  # VPC, subnets, NAT gateways, routes
    └── eks/                  # cluster, IAM, KMS, logs, node group, add-ons
```

## Prerequisites

- Terraform >= 1.10 (S3-native state locking).
- AWS CLI v2 and `kubectl`.
- AWS credentials allowed to manage VPC, EKS, IAM, KMS and CloudWatch Logs in the target account.

## Configuration

All backend settings come from environment variables. For local use, copy the example file and edit it:

```bash
cp .env.example .env   # gitignored; variables already set in your shell take precedence
```

The scripts select variables with the `ENVIRONMENT` value:

| `ENVIRONMENT` | Variable prefix |
|---|---|
| `development` | `DEV_` |
| `staging` | `STAGING_` |
| `production` | `PROD_` |

| Variable | Required | Purpose |
|---|---|---|
| `<PREFIX>_REMOTE_STORAGE_AWS_S3_BUCKET` | yes | S3 bucket that stores Terraform state |
| `<PREFIX>_REMOTE_STORAGE_AWS_REGION` | yes | Region of that bucket |
| `<PREFIX>_REMOTE_STORAGE_AWS_S3_KEY` | yes | State object key, e.g. `eks-cluster/terraform.tfstate` |
| `<PREFIX>_REMOTE_STORAGE_AWS_S3_ENDPOINT` or `REMOTE_STORAGE_AWS_S3_ENDPOINT` | no | Custom S3 endpoint |
| `<PREFIX>_REMOTE_STORAGE_AWS_ACCESS_KEY_ID` or `REMOTE_STORAGE_AWS_ACCESS_KEY_ID` | no | Credentials for the state bucket only |
| `<PREFIX>_REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY` or `REMOTE_STORAGE_AWS_SECRET_ACCESS_KEY` | no | Credentials for the state bucket only |
| `TF_INIT_RECONFIGURE` | no | `true` runs `terraform init -reconfigure` (needed when switching to another state bucket) |

Terraform variables that apply to every stage go in `terraform.tfvars`; see `terraform.tfvars.example`. Before using production, set at least:

| Variable | Default | Purpose |
|---|---|---|
| `public_access_cidrs` | `["0.0.0.0/0"]` | Who can reach the public Kubernetes API endpoint. Requests still need valid IAM credentials, but restrict this to your own ranges. |
| `cluster_admin_principal_arns` | `[]` | Extra IAM users/roles with cluster-admin. Don't list the principal that creates the cluster: it is already an admin, and EKS rejects a second entry. |

## First-time setup (once per state bucket)

```bash
ENVIRONMENT=development ./scripts/bootstrap-state-bucket.sh
```

This creates the state bucket with versioning, encryption and public access blocked. Re-running it is safe.

## Deploy

```bash
# 1. Review and apply
ENVIRONMENT=development ./scripts/terraform-run.sh plan
ENVIRONMENT=development ./scripts/terraform-run.sh apply

# 2. Connect
aws eks update-kubeconfig --region us-east-1 --name eks-cluster-development
kubectl get nodes
```

`ENVIRONMENT=development ./scripts/terraform-run.sh output configure_kubectl` prints the exact command for step 2.

**Switching environments:** if the stages use **different** state buckets, add `TF_INIT_RECONFIGURE=true` when you change `ENVIRONMENT`. The `.terraform/` folder only remembers one backend at a time:

```bash
TF_INIT_RECONFIGURE=true ENVIRONMENT=production ./scripts/terraform-run.sh plan
```

### From GitHub Actions

The [Infrastructure](../.github/workflows/infrastructure.yml) workflow runs these same scripts from `main`. Choose the environment and the action:

```bash
gh workflow run infrastructure.yml -f environment=development -f action=apply
```

It uses the `github-actions-eks-infrastructure` role from [`aws_role/`](../aws_role/), so no AWS keys are needed. The state settings come from the environment's `REMOTE_STORAGE_*` secrets. It also passes `cluster_admin_principal_arns`, so the deploy role and the ARNs in `EKS_ADMIN_PRINCIPAL_ARNS` can use the cluster. See the [workflows README](../.github/workflows/README.md#infrastructure).

If you create a cluster locally instead, your own IAM principal becomes its admin, and the deploy job can only use it once you pass the deploy role in `cluster_admin_principal_arns`.

### Per-stage settings

Set in `var.stages` (`variables.tf`). Override them in a `terraform.tfvars` file if needed; the override replaces the whole map, so include every stage.

| | development | staging | production |
|---|---|---|---|
| Availability zones | 2 | 2 | 2 |
| NAT gateways | 1 | 1 | 1 |
| VPC range | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| Instance types | `t3.medium`, `t3a.medium` | `t3.large` | `t3.medium`, `t3a.medium` |
| Capacity | Spot | On-Demand | Spot |
| Nodes (min / desired / max) | 1 / 2 / 3 | 2 / 2 / 4 | 1 / 1 / 2 |
| Node disk | 20 GiB | 30 GiB | 20 GiB |
| Control plane log retention | 7 days | 14 days | 7 days |
| EKS support policy | Standard | Standard | Standard |
| Deletion protection | off | off | off |

This repository is for practice, so production is sized for cost rather than availability: one Spot node in two zones, with a single NAT gateway. It costs roughly $120 a month, most of it the EKS control plane ($73) and the NAT gateway (about $33). For a real production workload, use several On-Demand nodes across three zones with a NAT gateway in each, and turn deletion protection on.

Resources are named `<project_name>-<stage>`. The `default` workspace isn't a stage: plan and apply stop there with an error.

### Things to know

- **Desired size**: `node_desired_size` only applies when the node group is created. Later changes are ignored so an autoscaler can manage it. Change `node_min_size`/`node_max_size`, or scale the group yourself.
- **Instance types**: changing them replaces the node group. The new nodes come up before the old ones go away.
- **Kubernetes upgrades**: raise `kubernetes_version` one minor version at a time, development first. Nodes and add-ons follow in the same apply.
- **Support policy**: `STANDARD` clusters are upgraded automatically by AWS when standard support ends. `EXTENDED` clusters stay on the version for longer, at a higher hourly price.
- **Pod access to AWS**: use EKS Pod Identity, as the EBS CSI driver does. The nodes' IMDS hop limit is 2, so pods can also reach the node role's credentials; lower it in `modules/eks/nodes.tf` if your workloads don't need instance metadata.
- **Storage**: the EBS CSI driver is installed, but this code creates no `StorageClass` for it. [`cluster/`](../cluster/) adds a default gp3 one.
- **Costs**: the control plane, NAT gateways and nodes are billed per hour, even when idle. Destroy stages you don't use.

## Tests

The tests use `terraform test` with a **mocked AWS provider**. They need no credentials and create nothing.

```bash
# Module unit tests
(cd modules/vpc && terraform init && terraform test)
(cd modules/eks && terraform init && terraform test)

# Root tests: stage wiring, per-stage settings, default-workspace guard
terraform init -backend=false
terraform test
```

`terraform test` always runs in the `default` workspace. The root tests pick a stage with `var.stage` instead. Leave `var.stage` unset for real deployments: it's only allowed to match the current workspace.

## Destroy

```bash
ENVIRONMENT=development ./scripts/terraform-run.sh destroy
```

`production` has deletion protection, so turn it off first. `disable_deletion_protection` does this for that run only, without changing `var.stages`:

```bash
export ENVIRONMENT=production TF_VAR_disable_deletion_protection=true
./scripts/terraform-run.sh apply -target=module.eks.aws_eks_cluster.this   # store the change in AWS
./scripts/terraform-run.sh destroy
```

After a destroy, the KMS key waits out its 30-day deletion window before AWS removes it. Re-creating the stage creates a new key.

## Reusing the modules

`modules/vpc` and `modules/eks` have no stage logic and no provider block. They work in any configuration:

```hcl
module "vpc" {
  source = "./modules/vpc"

  name         = "platform"
  cluster_name = "platform"
  vpc_cidr     = "10.50.0.0/16"
}

module "eks" {
  source = "./modules/eks"

  name               = "platform"
  kubernetes_version = "1.37"
  subnet_ids         = module.vpc.private_subnet_ids
}
```

## Troubleshooting

- **`Workspace "default" is not a configured stage`**: run through `scripts/terraform-run.sh` with `ENVIRONMENT` set, or run `terraform workspace select <stage>`.
- **`Backend configuration changed`**: re-run with `TF_INIT_RECONFIGURE=true`.
- **`ERROR: DEV_REMOTE_STORAGE_AWS_S3_BUCKET is required`**: set the variable, or create `.env` from `.env.example`.
- **`az_count is 3 but this region only has 2 usable availability zones`**: lower `az_count` for that stage. Zones where EKS can't place a control plane are not counted.
- **`kubectl` says you must be logged in**: your AWS identity isn't the cluster's creator. Add it to `cluster_admin_principal_arns`.
- **Secrets on disk**: backend credentials passed by `terraform-init.sh` are saved in `.terraform/terraform.tfstate`. That folder is gitignored, so don't commit or share it. Where you can, prefer an AWS profile or role over static keys.
