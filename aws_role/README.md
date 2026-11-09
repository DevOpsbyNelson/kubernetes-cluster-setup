# GitHub Actions ECR push role (OIDC)

This Terraform creates the ECR repository for the image built from `service/`, and the IAM role that GitHub Actions assumes through OIDC to push that image. The role gets short-lived credentials, and no AWS keys are stored anywhere.

- **Trust:** only this repository's jobs that run in the listed GitHub environments can assume it:
  - with GitHub's immutable subject: `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<name>`;
  - otherwise: `repo:<owner>/<repo>:environment:<name>`.
- **Permissions:** least privilege for pushing an image:
  - `ecr:GetAuthorizationToken` to log in. AWS only accepts `Resource: "*"` for this action.
  - The layer upload, image read and `ecr:PutImage` actions on the service repository only. The read actions let the build check what is already there and reuse layers.
  - No other AWS permissions.
- **ECR repository:** one repository (`eks-cluster/service` by default) shared by all stages, with scan on push and immutable tags.
- **OIDC provider:** set `create_oidc_provider = true` to create it, or `false` to reuse the account's existing one. AWS allows only one per account.

Nothing in this folder is specific to one AWS account: the account comes from the credentials it runs with.

## Pushing the image

`.github/workflows/publish_image.yml` builds `service/` and pushes it as `<ecr_repository_url>:<commit SHA>`. It runs on every push to `main` that changes `service/`, or by hand from **Actions → Publish Service Image**. If the image for a commit already exists, it skips the build, because tags can't be overwritten.

Any other workflow that pushes to this repository must:

- set `environment:` to `development`, `staging` or `production`, otherwise AWS rejects the OIDC token;
- grant `permissions: id-token: write`;
- assume `AWS_DEPLOY_ROLE_ARN` in the region of the repository;
- use a new tag for every push, such as the commit SHA. Tags are immutable, so pushing `latest` a second time fails.

Once the job has assumed the role, it builds and pushes with `service/` as the Docker context. `ECR_REPOSITORY_URL` holds the `ecr_repository_url` output:

```bash
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin "${ECR_REPOSITORY_URL%%/*}"
docker build -t "$ECR_REPOSITORY_URL:$GITHUB_SHA" service
docker push "$ECR_REPOSITORY_URL:$GITHUB_SHA"
```

## How it is run: `.github/workflows/create_role.yml`

The workflow is manual: **Actions → Create Deploy Role → Run workflow**. GitHub only offers it once the file is on the default branch.

```
aws-bootstrap environment (AWS_BOOTSTRAP_ROLE_ARN)
   │  OIDC
   ▼
create_role.yml ──▶ creates the state bucket if missing ──▶ terraform apply (this folder)
   │
   ▼
Job summary: AWS_DEPLOY_ROLE_ARN (repository secret) + ECR repository URL
```

| Input | Default | Meaning |
|---|---|---|
| `action` | `plan` | `plan`, `apply` or `destroy` |
| `github_repository` | this repo | Repository allowed to push images (`owner/repo`) |
| `role_name` | `github-actions-ecr-push` | Name of the role |
| `ecr_repository_name` | `eks-cluster/service` | ECR repository to create |
| `project_name` | `eks-cluster` | Used for the state bucket name and the `Project` tag |
| `state_bucket` | `<project_name>-tfstate-<account id>` | Bucket for this folder's Terraform state |
| `immutable_subject` | `true` | Use GitHub's immutable subject (`owner@id/repo@id`); the IDs are read from GitHub at run time |
| `create_oidc_provider` | `false` | Create the GitHub OIDC provider (only if the account has none) |
| `aws_region` | `us-east-1` | Region of the state bucket and the ECR repository |

The workflow always creates **one role for all three stages**. Its trust policy accepts the `development`, `staging` and `production` environments. Store its ARN once, as the **repository** secret `AWS_DEPLOY_ROLE_ARN`.

This folder's state is stored at `aws-role/terraform.tfstate`.

### What each action does

| Action | Effect in AWS |
|---|---|
| `plan` | Nothing is created. It only shows what `apply` would do. The state bucket is the exception: it is created if missing, because Terraform needs it to plan. |
| `apply` | Creates or updates the ECR repository, the role and its policy. |
| `destroy` | Deletes the ECR repository, the role and its policy, **without a preview**. |

`destroy` stops with an error while the repository still holds images, so images are not deleted by accident. The role may already be gone at that point. Delete the images first, then run it again.

`destroy` leaves these alone:
- the OIDC provider, when `create_oidc_provider = false`;
- the bootstrap role;
- the state bucket.

After a `destroy`, image pushes fail until the role and repository are created again. Use the same inputs as the `apply`, especially `state_bucket`.

## Terraform variables

`create_role.yml` sets these from its inputs. To run the folder by hand, pass them with `-var` or a `.tfvars` file.

| Variable | Default | Meaning |
|---|---|---|
| `github_repository` | (required) | `owner/repo` allowed to assume the role |
| `github_repository_owner_id` / `github_repository_id` | `null` | Numeric IDs for GitHub's immutable subject. Set both or neither. |
| `github_environments` | `["development","staging","production"]` | Environments allowed to assume the role |
| `ecr_repository_name` | `eks-cluster/service` | ECR repository to create; the only one the role can push to |
| `project_name` | `eks-cluster` | Used for the role policy name and the `Project` tag |
| `role_name` | `github-actions-ecr-push` | Name of the role |
| `create_oidc_provider` | `true` | Create the GitHub OIDC provider, or reuse the existing one when `false` |
| `max_session_duration` | `3600` | Maximum session length in seconds (3600–43200) |
| `aws_region` | `us-east-1` | Region of the ECR repository; IAM itself is global |

Outputs:
- `role_arn`: the value for the `AWS_DEPLOY_ROLE_ARN` secret.
- `role_name`
- `ecr_repository_url`: where to push the image.
- `oidc_provider_arn`
- `allowed_subjects`

### Running it locally (optional)

This needs credentials for the target account that can manage IAM and ECR, e.g. an SSO profile:

```bash
export AWS_PROFILE=<profile>
terraform init \
  -backend-config="bucket=<state bucket>" \
  -backend-config="key=aws-role/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform plan \
  -var 'github_repository=<owner>/<repo>' \
  -var 'github_repository_owner_id=<owner_id>' -var 'github_repository_id=<repo_id>' \
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
   - If the repository uses GitHub's **immutable subject**, the subject also contains the numeric IDs: `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:aws-bootstrap`. Check with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`; its `sub_claim_prefix` is the exact `repo:...` part. `create_role.yml` handles this for the push role through its `immutable_subject` input, which is on by default.
3. **GitHub:** create the environment **`aws-bootstrap`**:
   - Required reviewers.
   - Deployment branches: `main`.
   - Secret `AWS_BOOTSTRAP_ROLE_ARN` = ARN of the role from step 2.
4. **GitHub:** create the environments `development`, `staging` and `production`, which the pushing job runs in.
5. **GitHub:** run **Create Deploy Role** with `action = plan`, check the plan, then run it again with `action = apply`.
6. **GitHub:** copy the values from the job summary:
   - repository secret `AWS_DEPLOY_ROLE_ARN`;
   - the ECR repository URL, for the workflow that pushes the image.

To move to another AWS account, repeat these steps there: only the secrets change, not the code.

## Updating an account set up with the static-website role

This folder used to create a role for deploying a static website. If an account still has that role:

1. Attach `AmazonEC2ContainerRegistryFullAccess` to `github-actions-bootstrap`. Without it, `plan` can succeed and `apply` then fails with access denied.
2. Run **Create Deploy Role** with `state_bucket` set to the existing bucket, usually `static-website-tfstate-<account id>`. The default bucket name now starts with `eks-cluster`, so leaving it empty starts a new state and leaves the old role in AWS.
3. Check the plan: it should replace `github-actions-static-website-deploy` with `github-actions-ecr-push`, remove the S3 and CloudFront permissions, and create the ECR repository.
4. Update the `AWS_DEPLOY_ROLE_ARN` secret with the new ARN. The `REMOTE_STORAGE_*` environment secrets are no longer used by this role.

## Tests

```bash
terraform init -backend=false
terraform test   # mocked AWS provider: no credentials needed, nothing is created
```

The tests cover:
- the trust policy: subjects, audience, immutable IDs, and reusing an existing provider;
- the ECR repository settings: immutable tags and scan on push;
- the permission scoping: push actions on the service repository only, and only `ecr:GetAuthorizationToken` on `*`;
- input validation.
