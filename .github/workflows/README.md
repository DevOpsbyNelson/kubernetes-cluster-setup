# GitHub Actions workflows

| Workflow | File | Runs | What it does |
|---|---|---|---|
| **Create Deploy Role** | [`create_role.yml`](create_role.yml) | By hand | Creates the ECR repositories and the IAM roles the other workflows use ([`aws_role/`](../../aws_role/)) |
| **Infrastructure** | [`infrastructure.yml`](infrastructure.yml) | By hand, from `main` | Creates, changes or destroys one environment's VPC and EKS cluster ([`infrastructure/`](../../infrastructure/)) |
| **Publish and Deploy** | [`publish_and_deploy.yml`](publish_and_deploy.yml) | On push, or by hand | Builds and pushes the images, commits their tags, and installs Argo CD, which deploys [`cluster/`](../../cluster/) to the branch's cluster |
| **Tests** | [`tests.yml`](tests.yml) | On every push and pull request | Terraform tests, the cleanup script tests and the manifest render. Needs no AWS credentials. |

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
| `disable_deletion_protection` | `false` | Turns off EKS deletion protection for a stage that has it on. No stage has it on by default. |

Cluster access is set on every run:
- **The infrastructure role** creates the cluster, so EKS makes it an admin.
- **The EKS deploy role and `EKS_ADMIN_PRINCIPAL_ARNS`** get cluster-admin through access entries.

To give someone access, add their ARN to the variable and run `apply` again.

Before a `destroy`, the workflow runs [`delete-k8s-resources.sh`](../../infrastructure/scripts/delete-k8s-resources.sh), which deletes what Kubernetes created in AWS: load balancers (from `LoadBalancer` Services and Ingresses) and the EBS volumes behind PersistentVolumeClaims. Terraform doesn't track those, and a leftover load balancer blocks deleting the VPC. The script works in two passes: through Kubernetes while the cluster runs, then by their tags through the AWS API, which also cleans up after a cluster that is already gone. If a stage has deletion protection on, first run `apply` with `disable_deletion_protection`, then `destroy`.

## Publish and Deploy

Runs on pushes to these branches that change `service/`, `observability/`, `cluster/argocd/` or the workflow file. Other changes in `cluster/` don't need it: Argo CD deploys them directly from the branch. You can also start it by hand on one of them.

| Branch | GitHub environment | Cluster |
|---|---|---|
| `dev` | `development` | `eks-cluster-development` |
| `staging` | `staging` | `eks-cluster-staging` |
| `main` | `production` | `eks-cluster-production` |

**Publish job**
- **Images:** builds `service/` and each folder in `observability/` (`alertmanager`, `alloy`, `grafana`, `loki`, `prometheus`, `tempo`), and pushes them to the ECR repositories of the branch's environment: `eks-cluster/<environment>/<image>`, for example `eks-cluster/production/grafana`.
- **Tags:** each tag is the Git tree hash of the image's folder, for example `git rev-parse HEAD:observability/grafana`. If the environment already has that tag, the image is skipped. If another environment has it, for example after promoting a commit from `dev` to `staging`, the image is **copied** from there instead of rebuilt, so both environments run exactly the same image. Only new content is built.

- **GitOps:** writes the tags to `cluster/overlays/<environment>/images/kustomization.yaml` and commits them to the branch as `[DEPLOY] <environment> images for <commit>`, only when a tag changed. Commits made with the job token don't start workflows, so this doesn't loop. Run `git pull` before pushing your own changes.

**Deploy job** (GitOps: Argo CD does the deploying, see [`cluster/README.md`](../../cluster/README.md#gitops-with-argo-cd))
1. Finds the branch's cluster. If it doesn't exist yet, the job warns and stops without failing.
2. Applies the Kubernetes secrets from the environment. They don't belong in Git, so Argo CD doesn't manage them.
3. Installs Argo CD from `cluster/argocd/install` the first time, or upgrades it when that version changes, and applies the environment's Application.
4. Asks Argo CD to refresh, then waits up to 20 minutes until it has synced the branch's latest commit and the application is healthy.

To promote the same images, fast-forward the next branch:

```bash
git switch staging
git merge --ff-only dev
git push
```

Because tags come from folder contents, a merge commit that brings the same folders also reuses the images: they are copied to the next environment's repositories, not rebuilt.

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
