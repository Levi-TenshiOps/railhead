# iam

Sets up keyless CI/CD authentication for GitHub Actions using OIDC federation instead of long-lived AWS access keys. Registers GitHub's OIDC provider with IAM (fetching its certificate thumbprint live so it survives GitHub's own cert rotations), creates an IAM role that only GitHub Actions runs from this specific repo can assume via `AssumeRoleWithWebIdentity`, and attaches a minimal inline policy granting just enough S3/DynamoDB access to run `terraform plan`/`apply` against the state backend.

Also creates the S3 bucket used for Loki's chunk/index storage (encrypted, public access blocked, `force_destroy = true`). It lives in this module rather than `eks` specifically so it persists independently of EKS teardown, the same way ECR does — the corresponding IRSA role that grants Loki access to this bucket lives in the `eks` module instead, since that role's trust policy depends on the EKS cluster's own OIDC provider.

**Inputs:** `github_org` (default `Levi-TenshiOps`), `github_repo` (default `railhead`), `state_bucket_arn`, `lock_table_arn` (both required, no default).

**Outputs:** `github_actions_role_arn`, `github_actions_role_name`, `loki_chunks_bucket_name`, `loki_chunks_bucket_arn`.

**Note:** the trust policy is scoped to `repo:<org>/<repo>:ref:refs/heads/main` — only GitHub Actions runs on `main` can assume the role. This was tightened from an initial wide-open `repo:<org>/<repo>:*` (any branch/PR/tag) once the real CI workflow (`.github/workflows/ci.yml`) existed to test it against.
