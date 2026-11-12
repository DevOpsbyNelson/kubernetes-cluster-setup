# Kubernetes configuration

Kustomize manifests that run the service and the observability stack on the EKS clusters created by [`infrastructure/`](../infrastructure/). The [Publish and Deploy](../.github/workflows/publish_and_deploy.yml) workflow applies them.

```
service namespace                 observability namespace
┌──────────────┐  traces, logs    ┌───────┐      ┌───────┐
│   service    │ ───────────────▶ │ alloy │ ───▶ │ tempo │ ──┐ span metrics
│ :3000 :9464  │     (OTLP)       └───────┘      └───────┘   │
└──────────────┘                      │          ┌───────┐   ▼
       ▲                              └────────▶ │ loki  │ ┌────────────┐     ┌──────────────┐
       │ scrape :9464                            └───────┘ │ prometheus │ ──▶ │ alertmanager │ ──▶ Slack
       └────────────────────────────────────────────────── └────────────┘     └──────────────┘
                                         grafana reads prometheus, tempo and loki
```

## Layout

```
cluster/
├── base/
│   ├── kustomization.yaml
│   ├── namespaces.yaml          # service and observability
│   ├── storageclass.yaml        # gp3, the default storage class
│   ├── service/service.yaml     # the API
│   └── observability/           # alloy, tempo, loki, prometheus, alertmanager, grafana
└── overlays/
    ├── development/             # deployed from the dev branch
    ├── staging/                 # deployed from the staging branch
    └── production/              # deployed from main
```

## What runs

| Workload | Kind | Port | Storage | Image from |
|---|---|---|---|---|
| `service` | Deployment | 3000, metrics 9464 | None | `service/` |
| `alloy` | Deployment | 4317, 4318 (OTLP), 12345 | None | `observability/alloy/` |
| `tempo` | StatefulSet | 3200 | 10Gi | `observability/tempo/` |
| `loki` | StatefulSet | 3100 | 10Gi | `observability/loki/` |
| `prometheus` | StatefulSet | 9090 | 10Gi | `observability/prometheus/` |
| `alertmanager` | StatefulSet | 9093 | 1Gi | `observability/alertmanager/` |
| `grafana` | StatefulSet | 3000 | 2Gi | `observability/grafana/` |

Each workload runs a single replica:
- **`service`:** Prometheus scrapes it through its Service address, which reaches one pod per scrape. With more replicas, their metrics would mix.
- **`alloy`:** tail sampling needs every span of a trace on the same instance.
- **The others:** they store data on a single volume.

Nothing is exposed outside the cluster. Use `kubectl port-forward`, as shown below.

## Differences between environments

| | development | staging | production |
|---|---|---|---|
| Normal traces kept (`ALLOY_SAMPLE_RATE`) | 100% | 100% | 80% |
| Tempo, Loki and Prometheus volumes | 10Gi | 10Gi | 10Gi |

Error traces and slow traces are always kept.

Volume sizes only apply when a StatefulSet is first created. To grow an existing volume, edit its PersistentVolumeClaim; the `gp3` storage class allows expansion.

## How images are set

The manifests use placeholder image names such as `eks-cluster/grafana`. At deploy time, the workflow writes `cluster/.deploy/kustomization.yaml`, which is gitignored. It points each name at ECR with the tag for that commit: the Git tree hash of the image's folder, the same tag the publish job pushed.

To see the tag for an image at the current commit:

```bash
git rev-parse HEAD:observability/grafana
```

## Secrets

The deploy job creates two Kubernetes Secrets in `observability` from the GitHub environment's secrets on every run. If a Secret changes, it restarts the workload that uses it.

| GitHub secret | Required | Kubernetes Secret | Used by |
|---|---|---|---|
| `SLACK_WEBHOOK_URL` | Yes | `alertmanager-slack` | Alertmanager. It won't start without it. |
| `SLACK_ALERTS_CHANNEL` | Yes | `alertmanager-slack` | Alertmanager |
| `GRAFANA_ADMIN_PASSWORD` | Yes | `grafana` | Grafana's `admin` user. It only takes effect the first time Grafana starts. |
| `GRAFANA_GITHUB_CLIENT_ID` | No | `grafana` | GitHub sign-in. Without the ID and secret it's turned off. |
| `GRAFANA_GITHUB_CLIENT_SECRET` | No | `grafana` | GitHub sign-in |

For GitHub sign-in, create a GitHub OAuth app with the callback URL `http://localhost:3000/login/github`. Only members of the `DevOpsbyNelson` organization can sign in.

## Connect

You need the AWS CLI, `kubectl`, and an IAM principal listed in the `EKS_ADMIN_PRINCIPAL_ARNS` repository secret. The [Infrastructure](../.github/workflows/infrastructure.yml) workflow turns that list into cluster access.

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-cluster-development

kubectl -n observability port-forward svc/grafana 3000:3000   # http://localhost:3000
kubectl -n service port-forward svc/service 8080:80           # http://localhost:8080
kubectl -n observability port-forward svc/prometheus 9090:9090
```

## Render locally

`kubectl kustomize` shows what an environment gets, without a cluster:

```bash
kubectl kustomize cluster/overlays/production
```

## Limits

- Loki keeps logs until its volume is full: its stock config sets no retention. Tempo keeps traces for 25 days (`observability/tempo/tempo.yaml`), and Prometheus keeps metrics for 15 days.
- Deleting a manifest doesn't delete the object from the cluster: `kubectl apply` doesn't prune. Delete it by hand.
- Volumes live in one availability zone. If no node is left in that zone, the pod waits until the node group starts one there.
