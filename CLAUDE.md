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
- I hold Certified Kubernetes Application Developer (CKAD) — same
  treatment as AWS: give me a thorough review to stay sharp, not a
  first-time intro. That said, some Helm-specific commands genuinely
  don't stick for me — explain those clearly when they come up.
- Git: I've used it before on personal projects, never professionally.
  I have add/commit/push solid knowledge. Explain any new command or
  concept as it comes up, so I keep building real fluency, not just
  copying commands.
- Python: I'm comfortable with programming generally, and Python is
  the language I know best — it's simply been a while since I wrote
  code regularly. Treat this as knocking the rust off, not teaching:
  skip the concepts, and instead be precise about the syntax, idioms,
  and standard-library details as they come up, since those are what
  fade first. Point out anything that has changed in modern Python.

## Standing operational habits

- Cost discipline: destroy billable resources at the end of every
  session. `docs/teardown-sequence.md` is authoritative and verified
  end-to-end three times — follow it rather than working from memory,
  and treat any deviation as a finding worth reporting.
  `docs/rebuild-sequence.md` is the other direction; the rebuild is
  three targeted passes plus a manual CRD bootstrap, not one command.
- The one thing never to improvise: deleting an ArgoCD Application
  does NOT delete what it deployed. The namespaces must be deleted
  explicitly, or the EBS volumes orphan and bill indefinitely.
- Verify every apply/destroy independently via AWS CLI rather than
  trusting Terraform's own report — the ten-check orphan sweep is
  step 6 of the teardown doc.
- Flag screenshot moments only for things with no permanent record
  otherwise (live console views, one-time terminal output). GitHub
  Actions runs already have linkable history — link instead.
- Remind me about git add/commit/push at natural checkpoints. Keep
  infra-code commits and docs/screenshot commits separate.
- Screenshots go in `screenshots/` at the repo root, named
  `component-description.png` (`vpc-apply.png`,
  `remediator-quarantine-slack.png`).

## Known project decisions (don't re-litigate these)

**Infrastructure**
- DynamoDB state locking, not Terraform's newer `use_lockfile`.
- GitHub OIDC thumbprint showing as "changed" between plans is
  expected CDN-cert churn, not a real problem.
- Trust policy is scoped to
  `repo:Levi-TenshiOps/railhead:ref:refs/heads/main`.
- **The repo is PUBLIC.** ArgoCD's PAT is kept anyway — authenticated
  GitHub rate limits, and flipping back to private never breaks the
  deploy path. The hardcoded AWS account ID is fine for the same
  reason.
- Single dev environment, deliberately not multi-environment.
- Prometheus CRDs bootstrapped manually with `crds.enabled = false`
  (known-gotchas #14). ECR tagged-image retention is 100.

**Application**
- `/health` is DB-free by design, and both SLOs exclude it.
- The remediator's `/webhook` has no auth (ClusterIP, in-cluster
  caller only). Its guards are not lock-protected and don't need to
  be: Alertmanager's `group_by = ["namespace", "alertname"]` puts
  every per-pod alert in one group and delivers one notification per
  group at a time, so two actionable requests never arrive at once.
  Note Flask's `app.run()` defaults to `threaded=True` — the safety
  comes from Alertmanager's grouping, not from the server being
  single-threaded. Adding `pod` to `group_by` would break that.
- ArgoCD Applications carry no cascade finalizer — considered and
  rejected (known-gotchas #7).
- Image tags are bumped by hand and CI has no path filtering, so all
  three images rebuild on every push. Both are documented debt.
