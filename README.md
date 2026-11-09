# Kubernetes cluster setup

Terraform for a Kubernetes cluster on AWS EKS, a sample Node.js service, and a GitHub Actions pipeline that publishes the service image to a private Amazon ECR repository.

```
service/ ──▶ publish_image.yml ──▶ private ECR repository

infrastructure/ ──▶ terraform-run.sh ──▶ VPC + EKS cluster (one per stage)
```

Publishing the image and creating the cluster are separate steps. Nothing deploys the image to the cluster yet.

## Repository layout

| Path | What it holds | Docs |
|---|---|---|
| [`infrastructure/`](infrastructure/) | Terraform for the VPC and EKS cluster, with `development`, `staging` and `production` stages | [README](infrastructure/README.md) |
| [`aws_role/`](aws_role/) | Terraform for the ECR repository and the IAM role GitHub Actions uses to push to it | [README](aws_role/README.md) |
| [`service/`](service/) | Express app in TypeScript with OpenTelemetry traces, logs and metrics | [Below](#service) |
| [`.github/workflows/`](.github/workflows/) | GitHub Actions pipelines | [Below](#github-actions) |

## Getting started

1. **Create the ECR repository and role.** Follow the one-time setup in [`aws_role/README.md`](aws_role/README.md#one-time-setup-in-a-new-aws-account), then run **Create Deploy Role**.
2. **Publish the image.** Push a change under `service/` to `main`, or run **Publish Service Image** by hand.
3. **Create a cluster.** Follow [`infrastructure/README.md`](infrastructure/README.md). For example, from `infrastructure/`:

   ```bash
   cp .env.example .env   # then edit the values
   ENVIRONMENT=development ./scripts/bootstrap-state-bucket.sh
   ENVIRONMENT=development ./scripts/terraform-run.sh plan
   ENVIRONMENT=development ./scripts/terraform-run.sh apply
   ```

You need Terraform 1.10 or later, the AWS CLI v2, `kubectl`, and AWS credentials for the target account.

## GitHub Actions

| Workflow | Runs | What it does |
|---|---|---|
| **Create Deploy Role** ([`create_role.yml`](.github/workflows/create_role.yml)) | By hand | Runs `plan`, `apply` or `destroy` on `aws_role/` |
| **Publish Service Image** ([`publish_image.yml`](.github/workflows/publish_image.yml)) | On pushes to `main` that change `service/`, or by hand | Builds `service/` and pushes it to ECR, tagged with the commit SHA |

Both workflows sign in to AWS through OIDC, so no AWS keys are stored in GitHub. They need these settings:

| Name | Type | Where | Used by |
|---|---|---|---|
| `AWS_BOOTSTRAP_ROLE_ARN` | Variable | `aws-bootstrap` environment | Create Deploy Role |
| `AWS_DEPLOY_ROLE_ARN` | Secret | Repository | Publish Service Image |

Publish Service Image runs in the `production` environment. Image tags in ECR can't be overwritten, so if a commit is already published, the job skips the build.

## Service

The app needs Node.js 26 and pnpm 12. From `service/`:

```bash
pnpm install
pnpm dev         # run with reload on file changes
pnpm typecheck   # check types
pnpm build       # bundle into dist/
```

Without an OpenTelemetry collector running, the app still works but logs connection errors when it tries to send telemetry.

To run it in Docker:

```bash
docker build -t service service
docker run --rm -p 127.0.0.1:3000:3000 -p 127.0.0.1:9464:9464 service
```

| Endpoint | Port | Returns |
|---|---|---|
| `GET /` | 3000 | `Hello World!` |
| `GET /health/ping` | 3000 | `{"status":"ok"}`, for liveness checks |
| `GET /metrics` | 9464 | Prometheus metrics. Keep this port private. |

| Environment variable | Default | Purpose |
|---|---|---|
| `PORT` | `3000` | Port the app listens on |
| `SERVICE_NAME` | `service` | Service name in logs and telemetry |
| `NODE_ENV` | `production` in the image | Sets the environment name in logs |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Collector that receives traces and logs |
| `DEMO_ROUTES` | Off | Set to `true` to enable the `/demo` routes |

## Tests

The Terraform tests use a mocked AWS provider, so they need no credentials and create nothing. Run them from `aws_role/` or `infrastructure/`:

```bash
terraform init -backend=false
terraform test
```

The service has no automated tests yet.
