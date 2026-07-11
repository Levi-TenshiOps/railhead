# Railhead — Production-Grade SRE Platform on AWS

Railhead is an end-to-end reliability engineering platform: infrastructure as code → deployment → observability → self-healing → human escalation, built and operated on AWS. It exists to demonstrate the full lifecycle a production SRE actually owns, not just a single layer of it. The differentiator is the chaos engineering component — failure scenarios modeled directly on real production incidents I've diagnosed running Dell VxRail/vSAN clusters (storage layer degradation, node isolation, resync storms), rather than generic random-pod-killing — paired with a self-healing scorecard that measures what percentage of injected failures resolve automatically versus require human escalation.

## Why "Railhead"

A railhead is the point where a rail line physically ends and cargo transfers onward to its next mode of transport. That's the metaphor: this platform is where code "arrives" from git and gets distributed onward into running infrastructure. It's also a deliberate nod to VxRail, the hyperconverged infrastructure platform I've supported in production for several years — the name sits at the intersection of both.

## Architecture — what's built so far

Everything below exists and has been applied/verified against a live AWS account. Nothing in this section is aspirational.

- **Terraform state backend** (`terraform/bootstrap`): an S3 bucket (versioned, AES256-encrypted, all public access blocked) and a DynamoDB table for state locking, so Terraform state itself is durable and safe for concurrent runs.
- **VPC** (`terraform/modules/vpc`): 2 public + 2 private subnets across 2 AWS Availability Zones, an Internet Gateway, and a single NAT Gateway shared by both private subnets (a deliberate cost/resilience tradeoff for a dev environment — production would run one NAT Gateway per AZ). Subnets are pre-tagged for future EKS/load-balancer auto-discovery.
- **GitHub Actions OIDC federation** (`terraform/modules/iam`): keyless CI/CD authentication — GitHub Actions assumes a scoped IAM role via short-lived OIDC tokens instead of long-lived access keys sitting in GitHub Secrets.
- **ECR** (`terraform/modules/ecr`): container image repositories with immutable tags (a pushed tag can never be silently overwritten) and vulnerability scan-on-push enabled, plus a lifecycle policy to keep image storage from growing unbounded.

### Planned, not yet built

The following are designed but do not exist in this repo yet:

- **EKS** — the Kubernetes cluster itself
- **GitOps deployment** (ArgoCD)
- **Observability stack** (metrics/logs/tracing)
- **Chaos engineering scenarios**
- **Self-healing automation and scorecard**

## Cost approach

This project is built and torn down incrementally rather than left running continuously. Billable resources (currently: one NAT Gateway) are destroyed at the end of each working session via `terraform destroy`, and only recreated when the next session picks back up — the Terraform state backend and IAM/ECR resources (which cost nothing to leave running) persist between sessions so nothing has to be rebuilt from scratch each time. The AWS account has a $50/month budget alert plus a zero-spend safety net configured. In steady active development, this setup runs for pennies; once the platform is feature-complete and torn down, it costs $0/month.

## Screenshots

Reproducibility evidence — `terraform apply`/`destroy` output and AWS Console views — organized by component. Each group shows that piece's full lifecycle: provisioned, verified, and (where applicable) torn down cleanly.

**VPC**

VPC module terraform apply output:
![VPC module terraform apply output](screenshots/vpc-apply.png)

VPC resource map (subnets, route tables, NAT Gateway) in the AWS Console:
![VPC resource map in the AWS Console](screenshots/vpc-console.png)

VPC module terraform destroy output:
![VPC module terraform destroy output](screenshots/vpc-destroy.png)

**IAM / OIDC**

IAM/OIDC module terraform apply output:
![IAM/OIDC module terraform apply output](screenshots/iam-apply.png)

GitHub Actions IAM role's Trust relationships tab, showing the OIDC condition:
![IAM role trust relationship showing the OIDC condition](screenshots/iam-trust-policy.png)

**ECR**

ECR module terraform apply output:
![ECR module terraform apply output](screenshots/ecr-apply.png)

ECR repository settings (immutable tags, scan-on-push):
![ECR repository settings](screenshots/ecr-repository.png)
