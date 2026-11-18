# Kubernetes configuration

Kustomize manifests that run the service and the observability stack on the EKS clusters created by [`infrastructure/`](../infrastructure/). They are deployed with GitOps: [Argo CD](https://argo-cd.readthedocs.io/), running in each cluster, keeps the cluster in sync with this folder on the environment's branch. The [Publish and Deploy](../.github/workflows/publish_and_deploy.yml) workflow publishes the images, commits their tags here, and installs Argo CD. See [GitOps with Argo CD](#gitops-with-argo-cd).

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
├── overlays/
│   ├── development/             # deployed from the dev branch
│   ├── staging/                 # deployed from the staging branch
│   ├── production/              # deployed from main
│   │   └── images/              # image names and tags, written by the workflow
│   └── local/                   # your machine (Docker Desktop or minikube), deployed by local.sh
├── local.sh                     # build the images and deploy overlays/local
└── argocd/
    ├── install/                 # Argo CD v3.6.1, from the official manifests
    └── applications/            # one Application per environment: overlay + branch
                                 # (local.yaml: only for local.sh argocd)
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

Only the app is reachable from the internet, through the `service-public` Service in [service.yaml](base/service/service.yaml). AWS creates an internet-facing Network Load Balancer for it, about $16–18/month, and the deploy job summary shows its public URL. You can also look it up:

```bash
kubectl -n service get service service-public   # EXTERNAL-IP column: the load balancer's DNS name
```

That load balancer exposes only port 80 of the app. Metrics (9464) and the observability stack stay private: use `kubectl port-forward` for Grafana, as shown below. If you don't need a public URL, delete `service-public` and you stop paying for the load balancer.

## Differences between environments

| | development | staging | production |
|---|---|---|---|
| Normal traces kept (`ALLOY_SAMPLE_RATE`) | 100% | 100% | 80% |
| Tempo, Loki and Prometheus volumes | 10Gi | 10Gi | 10Gi |

Error traces and slow traces are always kept.

Volume sizes only apply when a StatefulSet is first created. To grow an existing volume, edit its PersistentVolumeClaim; the `gp3` storage class allows expansion.

## How images are set

The base manifests use placeholder image names such as `eks-cluster/grafana`. Each overlay includes a Kustomize component, `overlays/<environment>/images/kustomization.yaml`, that points every name at the environment's ECR repository, such as `eks-cluster/production/grafana`, with its tag: the Git tree hash of the image's folder.

The publish job rewrites that file after publishing and commits it to the branch as `[DEPLOY] <environment> images for <commit>`, only when a tag changed. Argo CD deploys what is committed, so that commit is the deploy. Don't edit the file by hand: the next publish overwrites it.

To see the tag for an image at the current commit:

```bash
git rev-parse HEAD:observability/grafana
```

## GitOps with Argo CD

```
push to main ──▶ publish job: images to eks-cluster/production/*
                     └─ commit "[DEPLOY] production images" (overlays/production/images)
             ──▶ deploy job:  Secrets + install Argo CD + Application (first time)
                                            │
Argo CD in eks-cluster-production ◀─────────┘ watches main, syncs cluster/overlays/production
```

- **What Argo CD deploys:** each cluster runs one Application, `eks-cluster` in the `argocd` namespace, defined in [`argocd/applications/<environment>.yaml`](argocd/applications/). It deploys `cluster/overlays/<environment>` from the environment's branch: `dev`, `staging` or `main`.
- **Changing what runs:** commit to `cluster/` on the branch. Argo CD applies it within a few minutes, and the deploy job asks it to refresh right away. Files removed from Git are deleted from the cluster (`prune`), and changes made by hand with `kubectl` are undone (`selfHeal`).
- **Rolling back:** revert the commit, for example the `[DEPLOY]` commit with the image tags, and push. Argo CD deploys the previous state.
- **Pull before you push:** the workflow commits image tags to the branch, so run `git pull` before pushing your own changes.
- **What stays out of Git:** the Secrets below. The deploy job creates them; Argo CD doesn't manage them.
- **Upgrading Argo CD:** change the version in [`argocd/install/kustomization.yaml`](argocd/install/kustomization.yaml). The next deploy applies it.

To open the Argo CD UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443   # https://localhost:8443, accept the self-signed certificate
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d   # user: admin
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

## Run locally

[`local.sh`](local.sh) runs the service and the whole observability stack on your machine, on Docker Desktop's Kubernetes or on minikube. It builds the seven images with Docker, creates placeholder Secrets, and applies [`overlays/local`](overlays/local/kustomization.yaml). Argo CD and AWS aren't involved: nothing is pulled from ECR and no load balancer or EBS volume is created.

### Before you start

| | Docker Desktop | minikube |
|---|---|---|
| Install | Docker Desktop, with Settings → Kubernetes → Enable Kubernetes | [minikube](https://minikube.sigs.k8s.io/docs/start/) and Docker (Docker Engine on Linux) |
| Start the cluster | Wait until Kubernetes shows as running | `minikube start --cpus 4 --memory 8g` |
| kubectl context | `docker-desktop` | `minikube` (or the profile name) |
| Images | Used straight from Docker | Copied in with `minikube image load` |
| Storage class | `hostpath` | `standard` |

The stack needs about 4 CPUs and 6 to 8 GB of memory. The script uses `kubectl` if it's installed, and `minikube kubectl --` otherwise, so an alias such as `alias kubectl="minikube kubectl --"` is enough. Scripts don't see shell aliases, which is why the script has this fallback.

It picks the `docker-desktop` context if it exists and `minikube` otherwise. To choose explicitly, for example a second minikube profile, set `LOCAL_CONTEXT`. Every command names that context, so the script can't touch an EKS cluster whatever your current context is.

### Deploy, check, delete

From the repository root:

```bash
cluster/local.sh up       # build the images, deploy, wait for every pod (the first build takes a few minutes)
cluster/local.sh argocd   # the same, but Argo CD deploys the manifests from GitHub: see below
cluster/local.sh status   # pods, and how to reach the app and Grafana
cluster/local.sh down     # delete both namespaces, volumes included, and Argo CD if installed

LOCAL_CONTEXT=minikube cluster/local.sh up   # force a context
```

Run `up` again after you change `service/` or `observability/`: it rebuilds the images and restarts the pods. They keep the tag `dev`, so the restart is what picks up the new image.

Optional variables for `up`:

| Variable | Default | Used for |
|---|---|---|
| `GRAFANA_ADMIN_PASSWORD` | `admin` | Grafana's `admin` user, on the first start only |
| `ARGOCD_ADMIN_PASSWORD` | `admin` | Argo CD's `admin` user, for `argocd` only. Set on every run, which signs out open sessions. |
| `LOCAL_ARGOCD_BRANCH` | Your current branch | The branch Argo CD deploys from, for `argocd` only |
| `SLACK_WEBHOOK_URL`, `SLACK_ALERTS_CHANNEL` | A placeholder | Alertmanager. Locally, alerts aren't delivered anywhere unless you set a real webhook. |

### Open the apps

| | Docker Desktop | minikube |
|---|---|---|
| The app | http://localhost:8080/health/ping (`service-public` is published on localhost) | `kubectl -n service port-forward svc/service 8080:80`, then http://localhost:8080/health/ping. Or run `minikube tunnel` in another terminal to give `service-public` an external IP. |
| Grafana | `kubectl -n observability port-forward svc/grafana 3000:3000`, then http://localhost:3000 (user `admin`) | Same |
| Prometheus | `kubectl -n observability port-forward svc/prometheus 9090:9090` | Same |

### With Argo CD (GitOps, like the EKS clusters)

`up` applies the manifests from your disk, which is fastest for trying changes. `cluster/local.sh argocd` works like the EKS clusters instead:
1. It builds and loads the images, and creates the Secrets, the same way `up` does.
2. It installs Argo CD, the same pinned version as [`argocd/install`](argocd/install/kustomization.yaml).
3. It registers [`argocd/applications/local.yaml`](argocd/applications/local.yaml), which deploys `cluster/overlays/local` with `prune` and `selfHeal`.
4. It waits until Argo CD reports `Synced` and `Healthy` for the branch's latest commit.

Things that work differently once Argo CD is installed:
- **Argo CD reads GitHub, not your disk.** It follows your current branch, which must be pushed. Set `LOCAL_ARGOCD_BRANCH` to choose another branch. Commit and push a manifest change before Argo CD can deploy it. If you change something with `kubectl`, Argo CD undoes it.
- **Images are still built on your machine.** Argo CD only deploys manifests. After you change `service/` or `observability/`, run `cluster/local.sh up`: it rebuilds and restarts the pods, and it skips `kubectl apply` because Argo CD manages the cluster.
- **Argo CD adds about 1 GB of memory** to what the stack needs.
- **On minikube, the app shows `HEALTH STATUS Progressing`** with the message `Caused by Service:service/service-public`. Argo CD only counts a LoadBalancer Service as healthy once it has an external IP, and minikube gives one only while `minikube tunnel` runs. Start `minikube tunnel` in another terminal and the app turns `Healthy`. `local.sh` accepts this one exception and still requires everything else to be healthy.
- **`down` removes Argo CD too.** It deletes the Application first, so Argo CD can't recreate what is being deleted.

Check it the same way as on EKS:

```bash
kubectl -n argocd get applications.argoproj.io eks-cluster    # SYNC STATUS Synced, HEALTH STATUS Healthy
kubectl -n argocd port-forward svc/argocd-server 8443:443      # https://localhost:8443
```

Sign in with user `admin` and the password from `ARGOCD_ADMIN_PASSWORD`, or `admin` if you didn't set it. The script replaces the random password Argo CD generates and deletes `argocd-initial-admin-secret`. On EKS, nothing changes: the password is still the random one in that Secret.

### How the local overlay differs

- **Images:** `local/<name>:dev`, built on your machine, with `imagePullPolicy: Never`.
- **Storage:** no `gp3` storage class. Volumes use the cluster's default class and are 2Gi.
- **`service-public`:** port 8080 instead of 80, without the AWS load balancer annotation.

### When something goes wrong

- **`ErrImageNeverPull`:** the image isn't in the cluster's runtime. Run `cluster/local.sh up` again. On minikube, `minikube image ls | grep local/` lists what was loaded.
- **Pods `Pending`:** usually not enough CPU or memory. Check with `kubectl describe pod`, and on minikube recreate the cluster with more resources: `minikube delete && minikube start --cpus 4 --memory 8g`.
- **`no 'minikube' kubectl context`:** minikube isn't started, or uses another profile. Run `minikube start`, or set `LOCAL_CONTEXT`.

## Render locally

`kubectl kustomize` shows what an environment gets, without a cluster:

```bash
kubectl kustomize cluster/overlays/production
```

## Limits

- **Kubernetes creates AWS resources that Terraform doesn't track:** the load balancer for `service-public` and the EBS volumes behind each PersistentVolumeClaim. The Infrastructure workflow's `destroy` deletes them first with [`delete-k8s-resources.sh`](../infrastructure/scripts/delete-k8s-resources.sh), even if the cluster is already gone. If you destroy a cluster another way, run that script first, with `ENVIRONMENT=<stage>`, or the load balancer blocks deleting the VPC and the volumes keep billing.

- Loki keeps logs until its volume is full: its stock config sets no retention. Tempo keeps traces for 25 days (`observability/tempo/tempo.yaml`), and Prometheus keeps metrics for 15 days.
- Deleting a manifest doesn't delete the object from the cluster: `kubectl apply` doesn't prune. Delete it by hand.
- Volumes live in one availability zone. If no node is left in that zone, the pod waits until the node group starts one there.
