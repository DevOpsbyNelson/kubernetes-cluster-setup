# Kubernetes cluster setup

Terraform for AWS EKS clusters in three environments, a sample Node.js service with a Grafana observability stack, and GitHub Actions pipelines that publish their images to private Amazon ECR and deploy them to the clusters.

```
service/ + observability/ ──▶ Publish and Deploy ──▶ private ECR ──▶ EKS cluster of the branch
                                                                      (cluster/ manifests)
infrastructure/ ──▶ Infrastructure workflow ──▶ VPC + EKS cluster per environment
```

| Branch | Environment | Cluster |
|---|---|---|
| `dev` | `development` | `eks-cluster-development` |
| `staging` | `staging` | `eks-cluster-staging` |
| `main` | `production` | `eks-cluster-production` |

## Repository layout

| Path | What it holds | Docs |
|---|---|---|
| [`infrastructure/`](infrastructure/) | Terraform for the VPC and EKS cluster of each environment | [README](infrastructure/README.md) |
| [`aws_role/`](aws_role/) | Terraform for the ECR repositories and the IAM roles GitHub Actions uses | [README](aws_role/README.md) |
| [`service/`](service/) | Express app in TypeScript with OpenTelemetry traces, logs and metrics | [README](service/README.md) |
| [`observability/`](observability/) | Images for Alloy, Tempo, Loki, Prometheus, Alertmanager and Grafana, with their configs | [cluster README](cluster/README.md) |
| [`cluster/`](cluster/) | Kustomize manifests that run the service and observability on EKS, and the Argo CD setup that deploys them (GitOps) | [README](cluster/README.md) |
| [`.github/workflows/`](.github/workflows/) | GitHub Actions pipelines | [README](.github/workflows/README.md) |

## Getting started

1. **Create the ECR repositories and roles.** Follow the one-time setup in [`aws_role/README.md`](aws_role/README.md#one-time-setup-in-a-new-aws-account), then run **Create Deploy Role**.
2. **Create the clusters.** Run **Infrastructure** with `action = apply` for each environment. See the [workflows README](.github/workflows/README.md#infrastructure) for the settings it needs.
3. **Publish and deploy.** Push to `dev`, `staging` or `main`, or run **Publish and Deploy** on one of those branches. It publishes the images, commits their tags, and installs Argo CD, which then deploys `cluster/` from the branch (GitOps).
4. **Open Grafana.** Port-forward to the cluster, as described in [`cluster/README.md`](cluster/README.md#connect).

Each cluster bills by the hour whether or not anything is deployed: roughly $145/month per environment, including the public load balancer, mostly the EKS control plane and the NAT gateway. To stop paying for an environment, run Infrastructure with `action = destroy` for it.

## GitHub Actions

| Workflow | Runs | What it does |
|---|---|---|
| **Create Deploy Role** ([`create_role.yml`](.github/workflows/create_role.yml)) | By hand | Runs `aws_role/`: ECR repositories and IAM roles |
| **Infrastructure** ([`infrastructure.yml`](.github/workflows/infrastructure.yml)) | By hand, from `main` | Runs `infrastructure/` for one environment |
| **Publish and Deploy** ([`publish_and_deploy.yml`](.github/workflows/publish_and_deploy.yml)) | On pushes to `dev`, `staging` or `main` that change `service/`, `observability/` or `cluster/argocd/`, or by hand | Builds or copies the seven images into ECR, commits their tags to `cluster/`, and installs Argo CD, which deploys `cluster/` from the branch |
| **Tests** ([`tests.yml`](.github/workflows/tests.yml)) | On every push and pull request | Terraform tests, cleanup script tests and manifest render, without AWS credentials |

All workflows sign in to AWS through OIDC, so no AWS keys are stored in GitHub. Images are tagged with the Git tree hash of their folder: an image is built only when its folder changes, into the ECR repositories of the branch's environment (`eks-cluster/<environment>/<image>`). Promoting a commit to the next branch copies its images instead of rebuilding them. The [workflows README](.github/workflows/README.md) lists every secret and variable.

## Service

See [`service/README.md`](service/README.md). From `service/`:

```bash
pnpm install
pnpm dev     # http://localhost:3000
```

## Tests

The **Tests** workflow runs all of these on every push. The Terraform tests use a mocked AWS provider, so they need no credentials and create nothing. Run them from `aws_role/` or `infrastructure/`:

```bash
terraform init -backend=false
terraform test
```

To check the Kubernetes manifests for an environment without a cluster:

```bash
kubectl kustomize cluster/overlays/development
```

The service has no automated tests yet.
