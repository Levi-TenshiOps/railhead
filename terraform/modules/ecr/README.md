# ecr

Creates one ECR repository per name in `repository_names` for storing container images, with `IMMUTABLE` tags (a pushed tag can never be silently overwritten), vulnerability scan-on-push, and AES256 encryption. Each repository also gets a lifecycle policy that expires untagged images after 7 days and keeps only the 10 most recent tagged images, so storage cost doesn't quietly grow forever from builds nobody will ever deploy again.

**Inputs:** `repository_names` (`list(string)`, default `["railhead-app"]` — a single placeholder repo since actual app services haven't been decided yet; add more names to the list as they are).

**Outputs:** `repository_urls` (map of repo name → pull/push URL), `repository_arns` (map of repo name → ARN).

**Cost note:** ECR has no hourly charge, only storage — an empty or lightly-used repo costs effectively $0/month.
