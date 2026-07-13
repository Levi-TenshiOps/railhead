# Railhead — Working Instructions for Claude Code

This file is read automatically every session. Follow these
consistently, not just when reminded.

## Top priority: understanding over speed

I'm building this project to be able to discuss it confidently in
SRE/cloud job interviews. I need to genuinely understand every step,
not just have working code. I'm completely fine with this taking
longer than originally planned if that's what real understanding
requires. Never sacrifice a clear explanation for the sake of
finishing faster.

Concretely:
- Explain what each command does and why, as you go — not only
  when I ask.
- Before any terraform apply/destroy or other consequential action,
  pause and get my explicit go-ahead.
- After anything non-trivial, offer a short note on why it matters
  or how it could come up in an interview.

## How to calibrate explanations

- I hold AWS Certified CloudOps Engineer - Associate, but practical
  recall is rusty. Explain AWS concepts as refreshers tied to the
  exam, not first-time introductions.
- Git and Terraform are genuinely new to me — explain from scratch.
- My background is infra/ops, not app development — keep
  Python/app-code explanations light unless I ask for more.

## Standing operational habits

- Cost discipline: destroy billable resources at the end of each
  session. Use targeted destroys (-target=module.eks
  -target=module.vpc) — dev was deliberately NOT split into
  foundation/workload layers; this is the agreed approach.
- If Postgres/PVCs are deployed, always `helm uninstall railhead`
  BEFORE `terraform destroy`, so the EBS volume releases cleanly.
- Always show terraform plan output and wait for explicit
  go-ahead before apply/destroy.
- Verify every apply/destroy independently via AWS CLI, not just
  by trusting Terraform's own report.
- Flag screenshot moments only for things with no permanent record
  otherwise (live console views, one-time terminal output). Things
  like GitHub Actions runs already have permanent, linkable
  history — link instead of screenshotting.
- Remind me about git add/commit/push at natural checkpoints.
  Keep infra-code commits and docs/screenshot commits separate.
- Screenshots go in screenshots/ at the repo root, named
  module-action.png.

## Known project decisions (don't re-litigate these)

- Kept DynamoDB-based state locking instead of migrating to
  Terraform's newer use_lockfile — deliberate choice.
- GitHub OIDC thumbprint showing as "changed" between plans is
  expected CDN-cert churn, not a real problem.
- GitHub Actions trust policy is scoped to
  repo:Levi-TenshiOps/railhead:ref:refs/heads/main.
