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

- I hold both AWS Certified CloudOps Engineer - Associate and AWS
  Certified Solutions Architect - Professional. I have a strong AWS
  theory background — I'm not a beginner here. Explain concepts as a
  thorough review to keep them sharp and practical, not as first-time
  introductions.
- I hold HashiCorp Certified: Terraform Associate (003) — I'm not new
  to Terraform. Review concepts to keep them fresh rather than
  explaining from scratch, but still walk me through new
  commands/patterns as they come up.
- Git: I've used it before on personal projects, never professionally.
  I have add/commit/push solid now. Explain any new command or
  concept as it comes up, so I keep building real fluency, not just
  copying commands.
- Python: I want to learn as much as possible. I haven't used it in a
  while, so treat this as an active refresher, not a background skill
  to gloss over — give real depth here, not light-touch explanations,
  unless I say otherwise.

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
