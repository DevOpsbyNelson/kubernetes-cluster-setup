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

## Run everything locally

To run the service with the full observability stack on your machine, on Docker Desktop's Kubernetes or minikube, without AWS:

```bash
cluster/local.sh up       # then: cluster/local.sh status, cluster/local.sh down
cluster/local.sh argocd   # or let Argo CD deploy it from GitHub, as on EKS
```

See [Run locally](cluster/README.md#run-locally) for prerequisites and how to open the apps.

## Open the Argo CD UI

Argo CD runs inside each cluster: the EKS clusters, and your local cluster after `cluster/local.sh argocd`. Its UI isn't exposed to the internet, so you reach it through a port-forward from your machine.

1. **Point `kubectl` at the cluster.**

   ```bash
   # EKS: use eks-cluster-development, eks-cluster-staging or eks-cluster-production
   aws eks update-kubeconfig --region us-east-1 --name eks-cluster-production

   # Local
   kubectl config use-context minikube          # or docker-desktop
   ```

2. **Forward the UI to your machine.** Leave this running in its own terminal:

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8443:443
   ```

3. **Get the `admin` password.**
   - **Local:** it's `ARGOCD_ADMIN_PASSWORD` from when you ran `cluster/local.sh argocd`, or `admin` if you didn't set it. To change it, run `ARGOCD_ADMIN_PASSWORD='...' cluster/local.sh argocd` again.
   - **EKS:** Argo CD generates a random one at install:

     ```bash
     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
     ```

4. **Sign in.** Open https://localhost:8443 and accept the browser's warning: the certificate is self-signed. Sign in with user `admin` and the password from step 3.

In the UI, the `eks-cluster` application shows:
- **Sync status:** `Synced` means the cluster matches the branch in Git.
- **Health status:** `Healthy` means every workload is ready.
- **The resource tree:** each Deployment, StatefulSet, Service and pod, with its logs and events.

**Refresh** checks Git right away instead of waiting a few minutes. Don't edit resources from the UI or with `kubectl`: Argo CD undoes changes that aren't in Git (`selfHeal`). Change `cluster/` in Git instead.

On EKS, change the `admin` password after the first sign-in: **User Info → Update Password**. Then delete the initial secret, which only holds the first password: `kubectl -n argocd delete secret argocd-initial-admin-secret`.

On minikube, the application shows `Progressing` until `minikube tunnel` is running. See [With Argo CD](cluster/README.md#with-argo-cd-gitops-like-the-eks-clusters).

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
