# Known gotchas

Real problems hit while building this, kept here rather than quietly fixed and forgotten.

**Entries are append-only — never renumber.** `rebuild-sequence.md` and
`teardown-sequence.md` cross-reference these by number, and those references
would rot silently if anything were inserted mid-file. New findings go at the
end and keep their number permanently, even once a later entry supersedes them.

## Index

1. [VPC CNI pod-per-node ceiling](#1)
2. [Any `observability` value change triggers a Grafana rollout](#2)
3. [Node group instance-type changes force full node replacement](#3)
4. [ECR lifecycle eviction silently broke a live deployment twice](#4)
5. [A UTF-8 BOM silently fails Grafana's dashboard provisioner](#5)
6. [A live Grafana admin password reset doesn't survive by itself](#6)
7. [Deleting an ArgoCD Application CR does not delete what it deployed](#7)
8. [Writing state without the DynamoDB digest locks you out entirely](#8)
9. [Windows sprays DNS queries across every interface, including dead ones](#9)
10. [A resource can silently drop out of state during an unrelated destroy](#10)
11. [Hyper-V and WSL reset interface metrics on restart](#11)
12. [A full rebuild takes three targeted Terraform passes, not one](#12)
13. [`terraform import` on the CLI fails on any unresolvable provider config](#13)
14. [The Prometheus Operator CRDs are bootstrapped manually](#14)
15. [Under DNS failure, read vs write decides whether state is damaged](#15)
16. [PowerShell 5.1's `Out-File -Encoding utf8` always writes a BOM](#16)
17. [Two different faults produce an identical `no such host`](#17)
18. [`terraform -chdir` resolves file arguments relative to that directory](#18)
19. [A namespace stuck `Terminating` waits on pods that will never report](#19)
20. [PowerShell re-quotes single-quoted arguments to native executables](#20)
21. [A rebuild leaves kubeconfig pointing at the destroyed cluster](#21)
22. [The network triage heuristic has a blind spot](#22)
23. [Replacing a placeholder with a concrete path made a step silently wrong](#23)

---

<a id="1"></a>
### 1. VPC CNI pod-per-node ceiling

EKS's default networking limits pods per node by available ENI IP addresses, not CPU or memory — `t3.medium` caps out at 17 pods, `t3.large` at 35. Nothing warns you before you hit it; a pod just sits `Pending` with `Too many pods` in its events. Prefix delegation would raise the ceiling further, but memory becomes the binding constraint before IP addresses do on these instance sizes.

<a id="2"></a>
### 2. Any `observability` value change triggers a Grafana rollout

Via a config-checksum annotation baked into the chart — even changes with nothing to do with Grafana (adding a PrometheusRule, in one real case). On a cluster already at its pod-per-node ceiling, the rollout's surge pod can't schedule, because Grafana's PV is AZ-pinned by node affinity and there's no room in that AZ. Grafana keeps serving fine on the old pod the whole time; the Application just shows `Progressing` instead of `Healthy` indefinitely. Fix is deleting the OLD pod (frees both the node slot and the volume attachment) — never the `Pending` one, since the ReplicaSet just recreates that immediately. This is the second time this project has hit the same underlying lesson: to unstick a resource contention deadlock, remove the thing holding the resource first and let the reconciler recreate, don't fight the thing that can't schedule.

<a id="3"></a>
### 3. Node group instance-type changes force full node replacement

Not a rolling update — Terraform tears down every existing node before creating the replacements, so there's a real window with zero worker nodes. Before doing this, verify every PVC's availability zone is actually covered by the node group's subnets; a PVC pinned to an AZ the node group can't launch into means that pod is permanently `Pending` after replacement, not just briefly.

<a id="4"></a>
### 4. ECR lifecycle eviction silently broke a live deployment twice

The tagged-retention cap doesn't care whether a tag is currently deployed — it evicts the oldest tag once the count is exceeded, even if that tag is what a running Deployment still references. It's invisible while the pod using that tag keeps running (the image is already pulled and cached locally), and only surfaces the moment that pod needs a fresh pull — a node replacement, a reschedule, anything that lands the pod on a node without the image cached. Fixed by raising the cap from 10 to 30: every push rebuilds all three matrix services regardless of what actually changed, so 10 was easy to exceed with unrelated commits (docs, a README tweak, one service's own change) before anyone manually bumped each service's deployed tag. Week 7's chaos experiments reschedule pods constantly, which is exactly the condition that would have kept re-triggering it.

**Later raised again from 30 to 100**, after a queue-position analysis showed the right metric was being watched all along but the wrong number was being read off it. What predicts eviction is not a repository's total image count but the deployed tag's *position* in the retention queue — how many images are newer than it. `railhead-api` had the most images (27) and the most headroom (19 pushes); `railhead-worker` had fewer images (24) but only 13 pushes of headroom, because its deployed tag is older and every unrelated commit pushes past it. The repo with the scariest-looking total was the safest one. A cap of 100 turns that margin from weeks into months.

<a id="5"></a>
### 5. A UTF-8 BOM silently fails Grafana's dashboard provisioner

A JSON file with a UTF-8 BOM fails the file-based provisioner with an opaque `invalid character` parse error — and because Grafana's SQLite database persists any dashboard it has ever successfully loaded, a BOM introduced when a file was first *saved* (before its first successful load) can go unnoticed indefinitely, since the working copy already lives in the database. It only surfaces on whatever event forces a truly clean re-provisioning from that file — a PVC reset, or a pod rescheduled by a node group replacement.

<a id="6"></a>
### 6. A live Grafana admin password reset doesn't survive by itself

`grafana cli admin reset-admin-password` writes straight to the SQLite file while the running server already has it open — the server process needs a restart to actually pick up the change. And since the sidecar container that triggers dashboard/datasource reloads authenticates using the Secret's `admin-password` value (not whatever the CLI just set), a manual password reset and a manual Secret edit have to happen together, or the sidecar's reload calls start failing with 401 even though the human login works fine.

<a id="7"></a>
### 7. Deleting an ArgoCD Application CR does not delete what it deployed

Not unless the Application carries the `resources-finalizer.argocd.argoproj.io` finalizer — and these don't. `kubectl delete application` removes the CR and returns success while every pod, Service, and PVC it created keeps running, now orphaned and untracked by anything. During a teardown that is expensive rather than merely untidy: the EBS CSI controller runs *inside* the cluster and is what actually honours a PV's `Delete` reclaim policy, so destroying the cluster with PVCs still bound means nothing ever issues `DeleteVolume` and the volumes bill indefinitely. Nine GiB nearly survived one teardown this way. The fix is to delete the target namespaces explicitly (`railhead` and `monitoring`) rather than trusting the CR deletion to cascade. Adding the cascade finalizer was considered and rejected on two grounds: it makes teardown depend on the ArgoCD controller still being alive at the exact moment ArgoCD is itself being torn down, and it turns an accidental `kubectl delete application` into a full application deletion rather than a recoverable mistake.

<a id="8"></a>
### 8. Writing state without the DynamoDB digest locks you out entirely

A Terraform run that writes state to S3 but dies before updating the digest locks you out of the state completely. The S3 backend stores an MD5 of the state object in the lock table alongside the lock itself; on every read it compares the two and refuses to proceed on a mismatch, failing with `state data in S3 does not have the expected content`. The state file is usually perfectly valid — verify it before assuming otherwise, by downloading the object and checking that it parses and that its `serial` and resource list look sane. The fix is deleting the stale `<key>-md5` item from the lock table; Terraform recreates it on the next successful write. Note this blocks *every* operation on that state, not just the one that failed, so a teardown interrupted this way also blocks the next session's `apply`.

<a id="9"></a>
### 9. Windows sprays DNS queries across every interface, including dead ones

A disconnected Wi-Fi adapter that still holds a default route and a configured DNS server, plus Hyper-V and WSL virtual adapters sitting at a *lower* interface metric than the real NIC, makes resolution intermittently fail with `no such host` — while `nslookup` and single AWS CLI calls succeed, because they happen to land on the working interface. The symptom reads as an AWS outage and is not one: it took nineteen `terraform destroy` attempts across four runs to get through one teardown, failing against `sts.`, `iam.`, and the S3 backend endpoint at different points each time. Check `Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceMetric` — if a `vEthernet` adapter outranks your Ethernet, that is the problem. Re-metricking the virtual adapters and disabling the dead Wi-Fi adapter fixes *this* fault, and the improvement is measurable.

**But it is not the whole story — see #17.** Sporadic failures persisted after this fix was applied, and #17 identifies a second, upstream fault that produces an identical `no such host` and that no local change can help. Do not stop reading here.

<a id="10"></a>
### 10. A resource can silently drop out of state during an unrelated destroy

`module.iam.aws_s3_bucket.loki_chunks` vanished from state during a `-target=module.eks -target=module.vpc` destroy — almost certainly because a refresh API call failed under the DNS trouble above and the provider read the failure as resource-not-found rather than as an error. Nothing was actually deleted: the bucket and all its objects were intact (1,935 at the time — the count grows every session, so treat that figure as a snapshot, not an expected value), and its two child resources (`aws_s3_bucket_public_access_block`, `aws_s3_bucket_server_side_encryption_configuration`) stayed in state still referencing a parent that was no longer there. The fix is `terraform import`, which is state-only and changes nothing in AWS — but note the import itself performs a refresh, so it fails the same false-not-found way if the network is still bad. Fix the network first, then import. The general lesson: after any destroy that hit network problems, diff `terraform state list` against what actually exists in AWS before running the next apply. State can be read straight from S3 with `aws s3 cp` and parsed, which sidesteps Terraform entirely when Terraform is the thing that cannot reach AWS.

<a id="11"></a>
### 11. Hyper-V and WSL reset interface metrics on restart

They recreate their virtual switches on service restart and after Windows updates, which resets the interface metric. Any re-metricking done to fix the DNS fan-out in #9 is therefore not permanent. If `no such host` starts appearing again after it was previously fixed, re-check `Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceMetric` before suspecting AWS — a `vEthernet` adapter having quietly reclaimed a lower metric than the physical NIC is far more likely than a regional S3 or STS problem.

<a id="12"></a>
### 12. A full rebuild takes three targeted Terraform passes, not one

A bare `terraform apply` from a destroyed state cannot complete, and no amount of retrying changes that. `kubernetes_manifest` validates its GroupVersionKind against the live cluster at *plan* time, so the five ArgoCD `Application` resources fail to plan until ArgoCD's own CRDs exist — and those CRDs are installed by a Helm release inside the same apply, which Terraform has no way to sequence within one run. It surfaces as `API did not recognize GroupVersionKind from manifest (CRD may not be installed)` on all five Applications at once, which reads like a broken chart rather than an ordering problem. The passes are: foundation + cluster, then `-target=module.argocd.helm_release.argocd` alone, then the full apply. See `rebuild-sequence.md`.

<a id="13"></a>
### 13. `terraform import` on the CLI fails on any unresolvable provider config

It fails whenever ANY provider's configuration depends on resources that don't currently exist, even a provider completely unrelated to the resource being imported. Here the `kubernetes` and `helm` providers are configured from `module.eks` outputs; with the cluster destroyed those values are unknown, so those provider vertices fail and the import aborts before writing state. The errors are actively misleading — including `Cannot import non-existent remote object` for a bucket that exists and whose `HeadBucket` call succeeds in the same debug log. Hours went into chasing DNS, region, credentials, permissions, and provider versions before a `TF_LOG=DEBUG` run showed the S3 read succeeding and the run dying on `vertex "provider[\"registry.terraform.io/hashicorp/helm\"]" error: Invalid provider configuration`. `plan` and `apply` are unaffected because they defer unknown provider config. The fix is an `import` block (Terraform 1.5+), which is evaluated inside the plan/apply flow rather than up front. Same underlying constraint as #12: Terraform's provider graph has to be fully resolvable before certain operations will run at all.

<a id="14"></a>
### 14. The Prometheus Operator CRDs are bootstrapped manually

Outside both Terraform and ArgoCD — and a cluster destroy removes them. The observability Application sets `crds.enabled = false` because these CRDs exceed Kubernetes' 256 KiB total-annotation-size limit for client-side apply (`crd-prometheuses.yaml` alone is ~830 KB), and setting `ServerSideApply=true` on the Application did not resolve it in practice. Nothing in the rebuild path recreates them, so after a teardown the observability Application fails every sync with `Make sure the "PrometheusRule" CRD is installed on the destination cluster` — which looks like a broken chart rather than a missing bootstrap step. This was found by running an actual teardown/rebuild cycle, not by reading the code; the only trace of it beforehand was a Terraform comment describing the bootstrap as something that had happened once, historically, rather than as a step anyone would need to repeat.

**Timing decides whether recovery is automatic.** ArgoCD gives up after five failed sync attempts, and those attempts begin the moment the Application is created. Bootstrap the CRDs promptly and the Application self-heals with no intervention — confirmed on a clean run. Let it exhaust its retries first and it sits at `OutOfSync / Missing` indefinitely *even once the CRDs exist*, and a refresh alone will not restart it; it needs an explicit sync operation patched onto it. Both outcomes have been observed on the same procedure, and the only difference was the delay between passes. See `rebuild-sequence.md`.

<a id="15"></a>
### 15. Under DNS failure, read vs write decides whether state is damaged

A failed **read** during refresh can be interpreted by the provider as resource-not-found, silently removing the resource from state — that is how `module.iam.aws_s3_bucket.loki_chunks` disappeared during a destroy that never targeted it (#10). A failed **write** (`DetachRolePolicy`, `PutObject`) surfaces as a hard error and leaves state untouched. Observed across two runs of the same teardown: three write failures caused no drift at all, while an earlier run with read failures dropped a resource silently. The practical rule is that a run which errored loudly is *safer* than one that appeared to succeed — after any Terraform run that hit network errors, diff `terraform state list` against what actually exists in AWS before the next apply. There is a third variant worth recognising: a write that fails at the very end, persisting nothing, which leaves AWS correct and state stale and drops an `errored.tfstate` for `terraform state push`. (Mechanism inferred from observed behaviour, not verified against provider source.)

<a id="16"></a>
### 16. PowerShell 5.1's `Out-File -Encoding utf8` always writes a BOM

This repo has now been bitten by it twice — first in a Grafana dashboard JSON (#5), then in a git commit message where the BOM rendered as a stray character at the front of the subject line in `git log` and on GitHub. Detection is the genuinely hard part: `git log --pretty=%s` reported the subject as clean, because PowerShell normalised the BOM out of the pipeline before it could be inspected, and only `git cat-file commit HEAD` exposed the actual `EF BB BF` bytes in the stored object. Use `[System.Text.UTF8Encoding]::new($false)` (or `-Encoding ascii` where the content allows) whenever writing a file another tool will parse, and verify at the byte level rather than by echoing the string back.

<a id="17"></a>
### 17. Two different faults produce an identical `no such host`

And they need opposite responses. (1) *Local*: Hyper-V/WSL virtual adapters outranking the real NIC on interface metric while having no DNS servers configured — see #9. Re-metricing fixes it, and the improvement is real and measurable (one endpoint went from 0/4 to 20/20 on sustained testing). (2) *Upstream*: a WAN or ISP dropout, which fails exactly the same way and which no local change will help. Distinguish them in one command: **`ping 8.8.8.8`**. If raw ICMP to a public IP fails with DNS out of the path entirely, it is the uplink — confirm with `ping <gateway>`, which will still succeed. A dropout was observed lasting 1–2 minutes and recovering on its own, during which the *previous* resolver failed identically, proving the resolver change innocent. A flapping link is the better explanation for the sporadic, unreproducible failures that persisted across random endpoints after the metric fix, and for why pre-warming helped — it narrows the exposure window rather than fixing anything. Assume any Terraform run over ~5 minutes risks an interruption; both the rebuild and teardown procedures are resumable by design, so the correct response is to re-run the failed pass, not to start changing network settings.

**The two-ping heuristic has a third case — see #22.** "Both pings succeed" is written above as meaning a genuine DNS fault, but that assumes the failing hostname *ought* to resolve. When it legitimately no longer exists — a rebuilt cluster's retired endpoint being the case that caught us — DNS is working correctly and there is nothing to fix. Check that the name is still valid before investigating resolution.

<a id="18"></a>
### 18. `terraform -chdir` resolves file arguments relative to that directory

Not to your shell's working directory. So `terraform -chdir=terraform/environments/dev state push terraform/environments/dev/errored.tfstate` fails with `The system cannot find the path specified`, because Terraform looks for `terraform/environments/dev/terraform/environments/dev/errored.tfstate`. The working form passes the bare filename: `... state push errored.tfstate`. Easy to lose time on, because the error names a path that visibly does exist and says nothing about the doubling. The same relocation applies to files Terraform *writes*: an `errored.tfstate` dropped by a failed run lands in the `-chdir` directory, not where you launched the command. Applies to any subcommand taking a file argument — `state push`, `apply <planfile>`, `-var-file`, `-out`.

<a id="19"></a>
### 19. A namespace stuck `Terminating` waits on pods that will never report

Expected once the NAT Gateway is gone. The nodes are `NotReady`, so kubelet cannot confirm that pods have stopped, and namespace finalization blocks forever on pods that will never report. A `NamespaceDeletionContentFailure` condition naming `Resource=pods` confirms it. Force-deleting the pods (`kubectl delete pods --all -n <ns> --force --grace-period=0`) removes them from etcd directly and finalization completes in about thirty seconds.

Prefer that over clearing the namespace's own finalizer via a raw `PUT` to `/api/v1/namespaces/<ns>/finalize`: force-deleting the pods removes the actual blocker and lets the namespace finalize through its normal path, whereas clearing the finalizer just tells Kubernetes to stop checking, leaving whatever it was waiting on genuinely unaccounted for. This is the whole reason `teardown-sequence.md` deletes the `argocd` namespace *before* Terraform runs rather than letting Terraform destroy it — doing it while the cluster is still healthy means the situation never arises.

Worth knowing why `kubectl` keeps working against the cluster throughout: your workstation reaches the public API endpoint directly over the internet, while the nodes depend on the NAT Gateway that is already gone. The control plane is fine; only the nodes are cut off.

<a id="20"></a>
### 20. PowerShell re-quotes single-quoted arguments to native executables

A single-quoted PowerShell string is literal *within PowerShell*, but when it is passed to a native `.exe` PowerShell 5.1 re-wraps it in double quotes and does **not** escape any double quotes inside it. So a jsonpath like `'{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'` arrives at `kubectl` as `"{range ...}{": "}...{end}"` — the receiving argument parser splits on those inner quotes and the command fails or silently returns nothing. This is not a `kubectl` bug and it affects any native tool: `jq` filters, `aws --query` expressions containing quotes, `git log --format` strings.

The reliable fix in PowerShell is to stop passing quote-bearing format strings to the tool at all and parse structured output instead: `(kubectl get ns <n> -o json | ConvertFrom-Json).status.conditions`. Where a format string is unavoidable, use the stop-parsing token `--%` or build the argument with `'` doubled. Related to #16 — both are cases where PowerShell transforms a string between what you typed and what the other program receives, and both are invisible until you inspect the bytes the other side actually got.

<a id="21"></a>
### 21. A rebuild leaves kubeconfig pointing at the destroyed cluster

Every EKS cluster gets a fresh API endpoint, so a teardown-then-rebuild leaves your local kubeconfig holding the *old* cluster's hostname. Every `kubectl` command then fails with `no such host` against something like `EA0543BCFEAE884175C86D0D3060985D.gr7.us-east-1.eks.amazonaws.com`. This is not a network fault, and it is not DNS: that hostname genuinely stopped existing when the old cluster was destroyed, so the resolver is answering correctly. Confirm by comparing `kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}"` against `aws eks describe-cluster --name railhead-dev --region us-east-1 --query cluster.endpoint` — if they differ, that is the whole problem. The fix is one command: `aws eks update-kubeconfig --name railhead-dev --region us-east-1`.

Worth recording *how* this was found, because it explains why it stayed hidden so long: a verification cycle that followed `rebuild-sequence.md` literally, not a code or doc review. On the two prior rebuilds the command was supplied reflexively, from habit, by whoever was driving — so both runs passed and neither exposed that no document anywhere mentioned it. Exactly the same class of defect as the manual Prometheus CRD bootstrap (#14): a mandatory step that lives only in an operator's muscle memory, and that a procedure claiming to be "verified against a real run" will keep failing to catch until someone runs it *without* the habit. The general lesson is that a procedure is only proven by executing it in a genuinely cold environment; a run by the person who wrote it proves considerably less.

<a id="22"></a>
### 22. The network triage heuristic has a blind spot

The standing triage for a `no such host` is `ping 8.8.8.8` plus a ping of the default gateway: 8.8.8.8 failing while the gateway answers means the uplink dropped (#17); both failing means the local network is down; **both succeeding** is meant to indicate a genuine DNS fault. That last branch is wrong on its own, because it silently assumes the hostname *should* resolve. When it shouldn't — a rebuilt cluster's retired endpoint (#21), a deleted load balancer, a renamed bucket — both pings succeed, DNS is working perfectly, and the rule points you at a fault that does not exist.

Add a third question before concluding DNS: **does this hostname still belong to something that exists?** For an EKS endpoint, compare kubeconfig's `server` value against `aws eks describe-cluster --query cluster.endpoint`; if they differ it is stale local configuration, not a network problem. The broader habit is to check that the *name* is still valid before investigating the *resolution* of it — resolution failures against names that were correctly deleted are the expected outcome, not a symptom.

<a id="23"></a>
### 23. Replacing a placeholder with a concrete path made a step silently wrong

`rebuild-sequence.md` originally wrote the Prometheus CRD bootstrap against a `<workdir>` placeholder. That was genuinely ambiguous, so it was replaced with a real path — and the concrete version was *worse*, because a reader supplies a fresh directory each time while a hard-coded one accumulates. `helm pull --untar` refuses to extract into a directory that already exists, so on every rebuild after the first it exited 1 — and the `kubectl apply` on the next line ran regardless, against the **previous** extract, reporting exit 0 and the correct count of ten CRDs. Nothing in the output indicated anything had gone wrong.

It was caught only because the leftover extract happened to match the pinned chart version. Had the pin been bumped between runs, the applied CRDs would have silently diverged from the chart ArgoCD deploys — the exact version-skew failure that `crds.enabled = false` and the manual bootstrap (#14) exist to manage, reintroduced by the documentation meant to prevent it.

Fixed: step 4 of `rebuild-sequence.md` now deletes the extract directory before pulling, and prints `Chart.yaml`'s version so a stale one is visible rather than assumed. Both were verified by running the sequence twice in a row from a dirty working directory.

Two lessons worth generalising. **Any command written into a procedure has to be idempotent**, because a procedure is by definition run more than once, and the second run is the one nobody tests. **Any step whose commands can fail independently needs a verification between them** — here, printing `Chart.yaml`'s version before applying, so a stale extract is visible rather than inferred. More uncomfortably: this was introduced while *fixing* a documentation gap, and shipped after a verification cycle that passed. Tightening a document is a change like any other and can regress it; "the run went green" only proves the path that ran, not the path a cold reader will take.
