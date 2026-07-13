# iam

Sets up keyless CI/CD authentication for GitHub Actions using OIDC federation instead of long-lived AWS access keys. Registers GitHub's OIDC provider with IAM (fetching its certificate thumbprint live so it survives GitHub's own cert rotations), creates an IAM role that only GitHub Actions runs from this specific repo can assume via `AssumeRoleWithWebIdentity`, and attaches a minimal inline policy granting just enough S3/DynamoDB access to run `terraform plan`/`apply` against the state backend.

**Inputs:** `github_org` (default `Levi-TenshiOps`), `github_repo` (default `railhead`), `state_bucket_arn`, `lock_table_arn` (both required, no default).

**Outputs:** `github_actions_role_arn`, `github_actions_role_name`.

**Note:** the trust policy is scoped to `repo:<org>/<repo>:ref:refs/heads/main` — only GitHub Actions runs on `main` can assume the role. This was tightened from an initial wide-open `repo:<org>/<repo>:*` (any branch/PR/tag) once the real CI workflow (`.github/workflows/ci.yml`) existed to test it against.
