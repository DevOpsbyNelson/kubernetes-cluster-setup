# ECR repositories and GitHub Actions roles (OIDC)

This Terraform creates what the GitHub Actions workflows need in AWS:

- **ECR repositories:** one private repository per image. One holds `service/`, and one holds each folder in `observability/`.
- **Three IAM roles:** GitHub Actions assumes them through OIDC. They get short-lived credentials, so no AWS keys are stored anywhere.

| Role | Default name | Used by | Can |
|---|---|---|---|
| ECR push | `github-actions-ecr-push` | Publish and Deploy, publish job | Push to this project's ECR repositories |
| Infrastructure | `github-actions-eks-infrastructure` | Infrastructure | Run Terraform in `infrastructure/`: VPC, EKS, KMS, logs and the cluster's IAM roles |
| EKS deploy | `github-actions-eks-deploy` | Publish and Deploy, deploy job | Find the clusters. Its Kubernetes permissions come from an EKS access entry. |

- **Trust:** all three roles trust only this repository's jobs that run in the listed GitHub environments:
  - with GitHub's immutable subject: `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<name>`;
  - otherwise: `repo:<owner>/<repo>:environment:<name>`.
- **ECR repositories:** `<ecr_namespace>/<name>` for `service`, `alertmanager`, `alloy`, `grafana`, `loki`, `prometheus` and `tempo`. They're shared by all stages, scan images on push, and use immutable tags.
- **OIDC provider:** set `create_oidc_provider = true` to create it, or `false` to reuse the account's existing one. AWS allows only one per account.

Nothing in this folder is specific to one AWS account: the account comes from the credentials it runs with.

## Permissions

**ECR push role**
- `ecr:GetAuthorizationToken` to log in. AWS only accepts `Resource: "*"` for this action.
- Layer upload, image read and `ecr:PutImage` on this project's repositories only.

**Infrastructure role**
- Terraform state: only the `env:/*` workspace states in the state bucket. This folder's own state stays out of reach.
- `ec2:*`, `eks:*`, and the KMS actions that manage a key, all limited to `aws_region`. It can't use keys to encrypt or decrypt.
- `logs:*` on the `/aws/eks/<project_name>-*` log groups.
- IAM changes only on roles named `<project_name>-*`. Only the five AWS managed policies the cluster uses can be attached, and roles can only be passed to EKS. It can also create the service-linked roles that EKS, node groups and Spot need.

Treat the infrastructure role as highly privileged. It can still write inline policies on `<project_name>-*` roles. Protect the environments that can assume it, especially `production`, with required reviewers.

**EKS deploy role**
- Only `eks:DescribeCluster` on `<project_name>-*` clusters.
- The Infrastructure workflow gives it cluster-admin inside each cluster through an EKS access entry.

## How it is run: `.github/workflows/create_role.yml`

The workflow is manual: **Actions → Create Deploy Role → Run workflow**. GitHub only offers it once the file is on the default branch.

```
aws-bootstrap environment (AWS_BOOTSTRAP_ROLE_ARN variable)
   │  OIDC
   ▼
create_role.yml ──▶ creates the state bucket if missing ──▶ terraform apply (this folder)
   │
   ▼
Job summary: the three role ARNs to store in GitHub
```

| Input | Default | Meaning |
|---|---|---|
| `action` | `plan` | `plan`, `apply` or `destroy` |
| `github_repository` | this repo | Repository allowed to assume the roles (`owner/repo`) |
| `role_name` | `github-actions-ecr-push` | Name of the ECR push role |
| `ecr_namespace` | `eks-cluster` | Prefix of the ECR repository names |
| `project_name` | `eks-cluster` | Must match `infrastructure/`'s `project_name`. Also used for the state bucket name. |
| `state_bucket` | `<project_name>-tfstate-<account id>` | Bucket for Terraform state, shared by this folder and `infrastructure/` |
| `immutable_subject` | `true` | Use GitHub's immutable subject (`owner@id/repo@id`); the IDs are read from GitHub at run time |
| `create_oidc_provider` | `false` | Create the GitHub OIDC provider (only if the account has none) |
| `aws_region` | `us-east-1` | Region of the state bucket, the ECR repositories and the clusters |

Leave `immutable_subject` on: this repository uses GitHub's numeric-ID subject, so with it off no job can assume the roles.

The roles trust the `development`, `staging` and `production` environments, so the same roles serve all three stages.

State keys inside the bucket:
- `aws-role/terraform.tfstate` for this folder.
- `env:/<stage>/eks-cluster/terraform.tfstate` for `infrastructure/`, one per workspace.

### What each action does

| Action | Effect in AWS |
|---|---|
| `plan` | Nothing is created. It only shows what `apply` would do. The state bucket is the exception: it is created if missing, because Terraform needs it to plan. |
| `apply` | Creates or updates the ECR repositories, the roles and their policies. |
| `destroy` | Deletes the ECR repositories, the roles and their policies, **without a preview**. |

`destroy` stops with an error while a repository still holds images, so images are not deleted by accident. Some roles may already be gone at that point. Delete the images first, then run it again.

`destroy` leaves these alone:
- the OIDC provider, when `create_oidc_provider = false`;
- the bootstrap role;
- the state bucket;
- the clusters, which belong to `infrastructure/`. Destroy them first: without the roles, nothing can change them from GitHub.

## Terraform variables

`create_role.yml` sets these from its inputs. To run the folder by hand, pass them with `-var` or a `.tfvars` file.

| Variable | Default | Meaning |
|---|---|---|
| `github_repository` | (required) | `owner/repo` allowed to assume the roles |
| `github_repository_owner_id` / `github_repository_id` | `null` | Numeric IDs for GitHub's immutable subject. Set both or neither. |
| `github_environments` | `["development","staging","production"]` | Environments allowed to assume the roles |
| `state_bucket_name` | (required) | Bucket with `infrastructure/`'s state; the infrastructure role may only use its `env:/` states |
| `ecr_namespace` | `eks-cluster` | Prefix of the ECR repository names |
| `ecr_repositories` | `service` and the six observability images | Repositories to create; must include `service` |
| `project_name` | `eks-cluster` | `infrastructure/`'s `project_name`; scopes the infrastructure and EKS deploy roles |
| `role_name` | `github-actions-ecr-push` | Name of the ECR push role |
| `infrastructure_role_name` | `github-actions-eks-infrastructure` | Name of the infrastructure role |
| `eks_deploy_role_name` | `github-actions-eks-deploy` | Name of the EKS deploy role |
| `create_oidc_provider` | `true` | Create the GitHub OIDC provider, or reuse the existing one when `false` |
| `max_session_duration` | `3600` | Maximum session length in seconds (3600–43200) |
| `aws_region` | `us-east-1` | Region of the ECR repositories and the clusters; IAM itself is global |

Outputs:
- `role_arn`: the value for the `AWS_DEPLOY_ROLE_ARN` repository secret.
- `infrastructure_role_arn`: the value for the `AWS_INFRA_ROLE_ARN` repository secret.
- `eks_deploy_role_arn`: the value for the `AWS_EKS_DEPLOY_ROLE_ARN` repository secret.
- `ecr_registry` and `ecr_repository_urls`: where images are pushed.
- `role_name`, `oidc_provider_arn`, `allowed_subjects`.

### Running it locally (optional)

This needs credentials for the target account that can manage IAM, S3 and ECR, e.g. an SSO profile:

```bash
export AWS_PROFILE=<profile>
terraform init \
  -backend-config="bucket=<state bucket>" \
  -backend-config="key=aws-role/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform plan \
  -var 'github_repository=<owner>/<repo>' \
  -var 'github_repository_owner_id=<owner_id>' -var 'github_repository_id=<repo_id>' \
  -var 'state_bucket_name=<state bucket>' \
  -var 'create_oidc_provider=false'
```

Get the IDs with `gh api repos/<owner>/<repo> --jq '.owner.id, .id'`.

## One-time setup in a new AWS account

1. **AWS console:** if the account has no GitHub provider yet, add it under **IAM → Identity providers → Add provider**:
   - Type: **OpenID Connect**
   - URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. **AWS console:** create the role **`github-actions-bootstrap`** under **IAM → Roles → Create role → Web identity**:
   - Provider: that one.
   - Audience: `sts.amazonaws.com`.
   - Leave the branch empty.
   - Permissions: `IAMFullAccess`, `AmazonS3FullAccess` and `AmazonEC2ContainerRegistryFullAccess`.
   - Then edit its trust policy so `token.actions.githubusercontent.com:sub` is `repo:<owner>/<repo>:environment:aws-bootstrap`.
   - If the repository uses GitHub's **immutable subject**, the subject also contains the numeric IDs: `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:aws-bootstrap`. Check with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`; its `sub_claim_prefix` is the exact `repo:...` part.
3. **GitHub:** create the environment **`aws-bootstrap`**:
   - Required reviewers.
   - Deployment branches: `main`.
   - Variable `AWS_BOOTSTRAP_ROLE_ARN` = ARN of the role from step 2.
4. **GitHub:** create the environments `development`, `staging` and `production`, which the other workflows run in.
5. **GitHub:** run **Create Deploy Role** with `action = plan`, check the plan, then run it again with `action = apply`.
6. **GitHub:** copy the values from the job summary into repository settings:
   - secret `AWS_DEPLOY_ROLE_ARN`;
   - secrets `AWS_INFRA_ROLE_ARN` and `AWS_EKS_DEPLOY_ROLE_ARN`.

The rest of the setup, such as creating the clusters and adding the environment secrets, is in the [workflows README](../.github/workflows/README.md).

To move to another AWS account, repeat these steps there: only the secrets and variables change, not the code.

## Updating from the single-repository version

Earlier versions created only `eks-cluster/service` and the push role. Running `apply` with this version:
- keeps `eks-cluster/service` and its images. A `moved` block tells Terraform it's the same repository, so check that the plan doesn't replace it;
- creates the six observability repositories and the two new roles;
- needs `role_name` set to the push role's current name if you changed it, such as `github-actions-ecr-push-prod`. Otherwise the role is replaced and its ARN changes.

## Tests

```bash
terraform init -backend=false
terraform test   # mocked AWS provider: no credentials needed, nothing is created
```

The tests cover:
- the trust policy: subjects, audience, immutable IDs, reusing an existing provider, and the same trust for all three roles;
- the ECR repositories: one per image, immutable tags and scan on push;
- the push role: specific ECR actions on this project's repositories only;
- the infrastructure role: state limited to `env:/*`, IAM limited to `<project_name>-*` roles and the cluster's managed policies, no broad IAM, S3 or KMS data actions, and region limits;
- the EKS deploy role: only `eks:DescribeCluster` on this project's clusters;
- input validation.
