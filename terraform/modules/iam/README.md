# iam

Sets up keyless CI/CD authentication for GitHub Actions using OIDC federation instead of long-lived AWS access keys. Registers GitHub's OIDC provider with IAM (fetching its certificate thumbprint live so it survives GitHub's own cert rotations), creates an IAM role that only GitHub Actions runs from this specific repo can assume via `AssumeRoleWithWebIdentity`, and attaches a minimal inline policy granting just enough S3/DynamoDB access to run `terraform plan`/`apply` against the state backend.

**Inputs:** `github_org` (default `Levi-TenshiOps`), `github_repo` (default `railhead`), `state_bucket_arn`, `lock_table_arn` (both required, no default).

**Outputs:** `github_actions_role_arn`, `github_actions_role_name`.

**Note:** the trust policy currently allows any branch/PR/tag from the repo (`repo:<org>/<repo>:*`) to assume the role — intentionally left open until a CI workflow exists to test against, then meant to be tightened to `main` only.
