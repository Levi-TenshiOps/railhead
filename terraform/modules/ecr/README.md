# ecr

Creates one ECR repository per name in `repository_names` for storing container images, with `IMMUTABLE` tags (a pushed tag can never be silently overwritten), vulnerability scan-on-push, and AES256 encryption. Each repository also gets a lifecycle policy that expires untagged images after 7 days and keeps only the 30 most recent tagged images, so storage cost doesn't quietly grow forever from builds nobody will ever deploy again.

**Inputs:** `repository_names` (`list(string)`, default `["railhead-app"]` as a module-level placeholder; the dev environment overrides this to the three real services, `["railhead-api", "railhead-worker", "railhead-remediator"]`).

**Outputs:** `repository_urls` (map of repo name → pull/push URL), `repository_arns` (map of repo name → ARN).

**Cost note:** ECR has no hourly charge, only storage at $0.10/GB-month. These three repositories currently hold about 2.5 GB combined (~$0.25/month) across 19/16/11 images. That is small but not free, and it climbs toward roughly $0.50/month as all three fill their 30-image retention cap — every push rebuilds all three services regardless of what changed, so the count grows on docs-only commits too. This is the largest single line item that survives a `terraform destroy` of the cluster.
