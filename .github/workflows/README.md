# GitHub Actions workflows

| Workflow | File | Runs | What it does |
|---|---|---|---|
| **Create Deploy Role** | [`create_role.yml`](create_role.yml) | By hand | Creates, updates or deletes the ECR repository and the IAM role that pushes to it |
| **Publish Service Image** | [`publish_image.yml`](publish_image.yml) | On push, or by hand | Builds [`service/`](../../service/) and pushes the image to private ECR |

Both sign in to AWS through OIDC, so no AWS keys are stored in GitHub. Run Create Deploy Role first, because Publish Service Image depends on what it creates.

```
Create Deploy Role ──▶ aws_role/ ──▶ ECR repository + push role
                                            │
                                            ▼
push to dev, staging or main ──▶ Publish Service Image ──▶ eks-cluster/service:<commit SHA>
```

## Required settings

| Name | Type | Where | Used by |
|---|---|---|---|
| `AWS_BOOTSTRAP_ROLE_ARN` | Variable | `aws-bootstrap` environment | Create Deploy Role |
| `AWS_DEPLOY_ROLE_ARN` | Secret | Repository | Publish Service Image |

The bootstrap role has to be created by hand once. See the [one-time setup](../../aws_role/README.md#one-time-setup-in-a-new-aws-account). `AWS_DEPLOY_ROLE_ARN` comes from the job summary of Create Deploy Role.

## Create Deploy Role

Start it from **Actions → Create Deploy Role → Run workflow**, or from the command line:

```bash
gh workflow run create_role.yml -f action=plan
```

| Action | Effect |
|---|---|
| `plan` | Shows what `apply` would change. It also creates the Terraform state bucket if it's missing. |
| `apply` | Creates or updates the ECR repository, role and policy |
| `destroy` | Deletes them with no preview. It stops with an error while the repository still holds images. |

Leave `immutable_subject` on, because this repository uses GitHub's numeric-ID OIDC subject. With it off, the role trusts the wrong identity and Publish Service Image can't sign in. All inputs are described in [`aws_role/README.md`](../../aws_role/README.md#how-it-is-run-githubworkflowscreate_roleyml).

## Publish Service Image

It runs on pushes to these branches that change `service/` or the workflow file. You can also start it by hand on one of them.

| Branch | GitHub environment |
|---|---|
| `dev` | `development` |
| `staging` | `staging` |
| `main` | `production` |

GitHub creates a missing environment on its first run, without protection rules. Add required reviewers to `production` if you want an approval before publishing.

All stages share one ECR repository, and images are tagged with the commit SHA. A commit is built once: if its image already exists, the job skips the build and reuses it.

To promote the same image, fast-forward the next branch:

```bash
git switch staging
git merge --ff-only dev
git push
```

A merge commit or a squash creates a new SHA, so it produces a new build.

The job only publishes the image. Nothing deploys it to EKS yet.

## Troubleshooting

| Problem | Likely cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The role's trust policy doesn't match the job. Check the repository and owner IDs with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`, and confirm the job runs in an allowed environment. |
| A workflow isn't listed in the Actions tab | Workflows started by hand must be on the default branch |
| Access denied during `apply` | The bootstrap role is missing IAM, S3 or ECR permissions |
| `destroy` fails on the repository | It still holds images. Delete them and run it again. |

## Changing these workflows

Third-party actions are pinned to a full commit SHA, with the version in a comment beside it. When you upgrade one, change both.
