# GitHub Actions workflows

| Workflow | File | Runs | What it does |
|---|---|---|---|
| **Create Deploy Role** | [`create_role.yml`](create_role.yml) | By hand | Creates the ECR repositories and the IAM roles the other workflows use ([`aws_role/`](../../aws_role/)) |
| **Infrastructure** | [`infrastructure.yml`](infrastructure.yml) | By hand, from `main` | Creates, changes or destroys one environment's VPC and EKS cluster ([`infrastructure/`](../../infrastructure/)) |
| **Publish and Deploy** | [`publish_and_deploy.yml`](publish_and_deploy.yml) | On push, or by hand | Builds and pushes the images, then deploys [`cluster/`](../../cluster/) to the branch's cluster |

All of them sign in to AWS through OIDC, so no AWS keys are stored in GitHub.

```
Create Deploy Role ──▶ ECR repositories + push, infrastructure and EKS deploy roles
        │
        ▼
Infrastructure (per environment) ──▶ VPC + EKS cluster eks-cluster-<environment>
        │
        ▼
push to dev / staging / main ──▶ Publish and Deploy ──▶ images in ECR ──▶ cluster/ on that cluster
```

## Setup, in order

1. **Roles and repositories:** run **Create Deploy Role** with `action = apply`, after the [one-time AWS setup](../../aws_role/README.md#one-time-setup-in-a-new-aws-account).
2. **Repository settings:** copy the three ARNs from its job summary, and add your IAM ARN so you can use `kubectl`.
3. **Environment secrets:** create the `development`, `staging` and `production` environments and add their secrets.
4. **Branches:** create the `dev` and `staging` branches from `main`.
5. **Clusters:** run **Infrastructure** with `action = apply` for each environment, one at a time. Each takes about 20 minutes.
6. **Deploy:** push to the branch, or run **Publish and Deploy** on it.

### Repository settings

**Settings → Secrets and variables → Actions**, at repository level:

| Name | Type | Value | Used by |
|---|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` | Secret | `role_arn` from Create Deploy Role | Publish and Deploy (publish) |
| `AWS_INFRA_ROLE_ARN` | Secret | `infrastructure_role_arn` | Infrastructure |
| `AWS_EKS_DEPLOY_ROLE_ARN` | Secret | `eks_deploy_role_arn` | Infrastructure, Publish and Deploy (deploy) |
| `EKS_ADMIN_PRINCIPAL_ARNS` | Secret | Comma-separated IAM user or role ARNs that get cluster-admin. Optional. | Infrastructure |

In the `aws-bootstrap` environment, set the variable `AWS_BOOTSTRAP_ROLE_ARN` to the bootstrap role's ARN. Create Deploy Role uses it.

### Environment secrets

Add these to each of `development`, `staging` and `production`:

| Secret | Required | Example | Used by |
|---|---|---|---|
| `REMOTE_STORAGE_AWS_S3_BUCKET` | Yes | `eks-cluster-tfstate-<account id>` | Infrastructure |
| `REMOTE_STORAGE_AWS_REGION` | Yes | `us-east-1` | Infrastructure |
| `REMOTE_STORAGE_AWS_S3_KEY` | Yes | `eks-cluster/terraform.tfstate` | Infrastructure |
| `SLACK_WEBHOOK_URL` | Yes | Slack incoming webhook | Alertmanager |
| `SLACK_ALERTS_CHANNEL` | Yes | `#alerts` | Alertmanager |
| `GRAFANA_ADMIN_PASSWORD` | Yes | | Grafana `admin` user, set when Grafana first starts |
| `GRAFANA_GITHUB_CLIENT_ID` | No | | Grafana GitHub sign-in |
| `GRAFANA_GITHUB_CLIENT_SECRET` | No | | Grafana GitHub sign-in |

The state bucket must be the one Create Deploy Role used: the infrastructure role can only read and write state there. The same values work in all three environments, because Terraform stores each environment at its own path in the bucket.

Add required reviewers to `production`: anything that reaches `main` publishes and deploys straight away, and the infrastructure role is highly privileged.

## Create Deploy Role

Start it from **Actions → Create Deploy Role → Run workflow**, or from the command line:

```bash
gh workflow run create_role.yml -f action=plan
```

| Action | Effect |
|---|---|
| `plan` | Shows what `apply` would change. It also creates the Terraform state bucket if it's missing. |
| `apply` | Creates or updates the ECR repositories, roles and policies |
| `destroy` | Deletes them with no preview. It stops with an error while a repository still holds images. |

Leave `immutable_subject` on: this repository uses GitHub's numeric-ID OIDC subject. With it off, the roles trust the wrong identity and no job can sign in. All inputs are described in [`aws_role/README.md`](../../aws_role/README.md#how-it-is-run-githubworkflowscreate_roleyml).

## Infrastructure

Runs Terraform in `infrastructure/` for one environment, from `main` only:

```bash
gh workflow run infrastructure.yml -f environment=development -f action=plan
gh workflow run infrastructure.yml -f environment=development -f action=apply
```

| Input | Default | Meaning |
|---|---|---|
| `environment` | `development` | Which cluster: `development`, `staging` or `production` |
| `action` | `plan` | `plan`, `apply` or `destroy`. `apply` plans first and applies that plan. `destroy` has no preview. |
| `disable_deletion_protection` | `false` | Turns off EKS deletion protection, which production has on |

Cluster access is set on every run:
- **The infrastructure role** creates the cluster, so EKS makes it an admin.
- **The EKS deploy role and `EKS_ADMIN_PRINCIPAL_ARNS`** get cluster-admin through access entries.

To give someone access, add their ARN to the variable and run `apply` again.

To destroy production, first run `apply` with `disable_deletion_protection` on, then run `destroy`.

## Publish and Deploy

Runs on pushes to these branches that change `service/`, `observability/`, `cluster/` or the workflow file. You can also start it by hand on one of them.

| Branch | GitHub environment | Cluster |
|---|---|---|
| `dev` | `development` | `eks-cluster-development` |
| `staging` | `staging` | `eks-cluster-staging` |
| `main` | `production` | `eks-cluster-production` |

**Publish job**
- **Images:** builds `service/` and each folder in `observability/` (`alertmanager`, `alloy`, `grafana`, `loki`, `prometheus`, `tempo`), and pushes them to `eks-cluster/<name>` in ECR.
- **Tags:** each tag is the Git tree hash of the image's folder, for example `git rev-parse HEAD:observability/grafana`. An image is only built when that tag doesn't exist yet, so unchanged folders are skipped.

**Deploy job**
1. Finds the branch's cluster. If it doesn't exist yet, the job warns and stops without failing.
2. Applies the Kubernetes secrets from the environment.
3. Applies the environment's overlay from `cluster/`, with the image tags for this commit.
4. Waits for every workload to be ready.

To promote the same images, fast-forward the next branch:

```bash
git switch staging
git merge --ff-only dev
git push
```

Because tags come from folder contents, a merge commit that brings the same folders also reuses the images.

## Troubleshooting

| Problem | Likely cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The role's trust policy doesn't match the job. Check the IDs with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`, and that the job runs in an allowed environment. |
| A workflow isn't listed in the Actions tab | Workflows started by hand must be on the default branch |
| Infrastructure says a setting is missing | Add the repository variables, or the `REMOTE_STORAGE_*` secrets to that environment |
| `AccessDenied` on the state bucket | The `REMOTE_STORAGE_AWS_S3_BUCKET` secret isn't the bucket Create Deploy Role used |
| Access denied during an Infrastructure `apply` | The infrastructure role lacks a permission Terraform needs. Add it in `aws_role/main.tf` and run Create Deploy Role again. |
| Deploy warns that the cluster doesn't exist | Run Infrastructure with `action = apply` for that environment |
| Deploy fails with `Unauthorized` from Kubernetes | The EKS deploy role has no access entry. Check `AWS_EKS_DEPLOY_ROLE_ARN`, then run Infrastructure `apply` again. |
| A workload never becomes ready | See the **Show pods** step. Alertmanager needs the Slack secrets, and Grafana needs its admin password. |

## Changing these workflows

Third-party actions are pinned to a full commit SHA, with the version in a comment beside it. When you upgrade one, change both.
