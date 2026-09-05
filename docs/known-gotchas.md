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
24. [`helm repo list` reports repos whose indexes no longer exist](#24)
25. [CloudWatch log groups outlive `terraform destroy`](#25)
26. [An IRSA annotation does not reach pods that already exist](#26)
27. [`Get-Date -UFormat %s` returns local-time epoch, not UTC](#27)
28. [CI fails on commits that changed nothing, because the CVE gate tracks Debian's schedule](#28)
29. [Chaos Mesh breaks under ArgoCD because Helm generates its webhook cert at render time](#29)
30. [`chaos-daemon` logs a `/dev/fuse` ERROR on every node, and mostly does not mean it](#30)
31. [Git Bash rewrites absolute paths passed to `kubectl exec`](#31)
32. [Automated remediation erases the evidence its own guard reads](#32)
33. [`/metrics` sits in the SLO denominator and can stop an alert firing](#33)
34. [`service_number_of_running_pods` counts pod phase, not readiness](#34)
35. [A PowerShell pipeline returning one object has no `.Count`](#35)
36. [A number read off a rendered UI is not a measurement](#36)

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

**Four more instances hit in a single session**, worth listing because each looked like a different bug and each is the same one:

| Command | Symptom |
|---|---|
| `terraform plan -target=module.eks` unquoted | `Too many command line arguments` **and** `Invalid target "module"` — the argument was split on the `.` boundary |
| `kubectl get pod -o jsonpath=...(@.name=="AWS_ROLE_ARN")...` | `unrecognized identifier AWS_ROLE_ARN`, then a full object dump instead of one field |
| `aws logs start-query --query-string '... = "system:serviceaccount:..."'` | `MalformedQueryException: unexpected symbol found :` — the quotes vanished, so Logs Insights parsed the ServiceAccount's colons as syntax |
| `kubectl exec -- python -c '...requests.post("http://...")...'` | `SyntaxError: invalid syntax` — Python received the URL unquoted |

Three general escapes, in order of preference. **Pass the payload as a file** — `--query-string "file://$env:TEMP\q.txt"`, or `kubectl patch --patch-file`, which `rebuild-sequence.md` step 5 already does for this reason. **Pipe it via stdin** — `$script | kubectl exec -i ... -- python -` sidesteps argument parsing completely and was what finally worked for the Python case. **Quote the whole argument at the PowerShell level** — `"-target=module.eks"` — which works for simple values with no inner quotes.

Note that assigning to a variable first does *not* help. `$py = 'requests.post("http://x")'` still loses its inner quotes when passed to a native command, because the re-quoting happens at invocation, not at assignment.

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

<a id="24"></a>
### 24. `helm repo list` reports repos whose indexes no longer exist

Step 2 of `rebuild-sequence.md` failed outright with `Unable to locate chart argo-cd: no cached repo found`. `helm repo list` showed all four repositories registered and looked entirely healthy. The cache directory was empty.

The split is the whole problem: the repo *list* lives in `%APPDATA%\helm\repositories.yaml` and persists indefinitely, while the downloaded *indexes* live in `%TEMP%\helm\repository` — which Windows disk cleanup purges. So `helm repo list` keeps reporting four repositories long after none of them are usable, and the Terraform `helm` provider, which reads the index rather than the list, fails on the first chart it tries to resolve. The error names `bitnami-index.yaml` regardless of which chart you asked for, because the provider enumerates every configured repo before giving up.

It is also **time-dependent**, which is why three verified cycles never caught it: rebuild soon after the previous session and the cache is still warm; rebuild after cleanup has run and step 2 fails. Nothing about the procedure changed between the runs that worked and the run that didn't.

Fixed: `rebuild-sequence.md` now runs `helm repo update` before step 2, not only inside step 4.

**This is the third instance of one pattern**, and it is worth naming as a pattern rather than three separate bugs. The Alloy empty-`ClusterRole` default, the stale kubeconfig pointing at a destroyed endpoint (#21), and this all share a signature: **the system reports healthy and silently does nothing.** In each case the status command answers from a different source than the one doing the work — `helm repo list` reads the list, not the indexes; kubeconfig holds a context name, not a reachable endpoint; a ClusterRole exists but grants nothing. The generalisable check is to verify against *what the component actually consumes*, never against the thing that merely describes it.

<a id="25"></a>
### 25. CloudWatch log groups outlive `terraform destroy`

`enabled_cluster_log_types` on `aws_eks_cluster` makes EKS create `/aws/eks/<cluster>/cluster` itself during cluster creation. That group is not a Terraform resource, defaults to **never expire**, and `terraform destroy` does not touch it. Found holding **1.51 GB** of audit and API-server logs dating to 2026-07-11, the day the cluster was first built — accumulated across every session since, surviving three teardowns that were each verified as clean. The nine-check sweep had no log-group check, so nothing ever looked.

Container Insights has the same shape for a different reason: it publishes metrics as embedded metric format *through CloudWatch Logs*, so `/aws/containerinsights/<cluster>/performance` exists even with container log shipping disabled, and it too defaults to never-expire if the agent creates it.

Fixed by declaring both groups in `module.eks` with `retention_in_days = 1`, and — this part is load-bearing — making the consumer depend on the group:

- `aws_eks_cluster` **must** `depends_on` its log group. Terraform destroys in reverse dependency order; without this the group is deleted while the cluster still exists and EKS immediately recreates it, now unmanaged, to outlive the cluster as a fresh orphan.
- `aws_eks_addon.cloudwatch_observability` **must** `depends_on` the Container Insights group for exactly the same reason — the agent is still running when the group is removed.

Verified on a real rebuild: Terraform created the group first, EKS found it and used it rather than creating its own, and the apply reported `0 changed` on the cluster — confirming the cluster was *created* with logging already enabled rather than created and then updated.

The 1-day retention is a backstop, not the fix. If ordering ever breaks anyway, a survivor self-deletes within a day instead of billing forever — but it should still be reported as a finding, because its existence means the ordering broke.

The broader lesson is about verification rather than CloudWatch: **a procedure only verifies what it checks for.** Three consecutive teardowns were confirmed clean against nine checks while a tenth category of resource accumulated 1.51 GB in plain sight.

<a id="26"></a>
### 26. An IRSA annotation does not reach pods that already exist

Setting `service_account_role_arn` on an `aws_eks_addon` after the add-on is installed annotates the ServiceAccount correctly, and Terraform reports success. The running pods do not get IRSA. The `cloudwatch-agent` pods stayed `1/1 Running` with no `AWS_ROLE_ARN`, no `aws-iam-token` volume, and zero metrics published.

The reason is that IRSA is injected by a **mutating admission webhook**, which runs at pod admission. Annotating the ServiceAccount changes what *future* pods receive; it cannot retrofit an existing pod, because the projected token volume and the `AWS_*` environment variables are part of the pod spec that was already admitted. `kubectl rollout restart` is required.

What makes this dangerous rather than merely annoying is the failure mode. Without IRSA the AWS SDK falls back to the node instance role, which in this project deliberately carries no CloudWatch permissions — so the agent authenticates as `assumed-role/railhead-dev-eks-node-role`, is denied, and drops every datapoint while reporting healthy:

```
AccessDeniedException: User: arn:aws:sts::<acct>:assumed-role/railhead-dev-eks-node-role/i-...
is not authorized to perform: logs:PutLogEvents ... because no identity-based policy allows
the logs:PutLogEvents action
```

968 metric datapoints rejected per flush, pods `Running`, add-on `ACTIVE`, Terraform green.

A from-scratch rebuild is unaffected, because the add-on and the role are created in the same apply and the pods are admitted afterwards. Only a *later* change to IRSA — adding it, or repointing it at a different role — needs the restart. Worth checking `AWS_ROLE_ARN` is present in the pod spec rather than trusting the ServiceAccount annotation, which is the fourth instance of the #24 pattern: the annotation describes intent, the pod spec is what the SDK actually consumes.

<a id="27"></a>
### 27. `Get-Date -UFormat %s` returns local-time epoch, not UTC

`aws logs start-query` takes Unix timestamps. Building them with `[int][double]::Parse((Get-Date -UFormat %s))` produced a window six hours off — the local UTC offset — and the API rejected it with `Query's end date and time is either before the log groups creation time or exceeds the log groups log retention settings`, which reads like a retention misconfiguration rather than a clock problem.

PowerShell 5.1's `-UFormat %s` formats the *local* time as though it were UTC. Use `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()` instead, which is unambiguous and needs no parsing.

<a id="28"></a>
### 28. CI fails on commits that changed nothing, because the CVE gate tracks Debian's schedule

A commit touching only comments and `.gitignore` failed CI on all three images. Nothing in the repo regressed: Trivy found `CVE-2026-53615`, an integer overflow in `libblkid/src/partitions/dos.c`, in the `util-linux` packages inherited from `python:3.12-slim`. Installed `2.41-5`, fixed upstream in `2.41.5-0+deb13u1`. The previous run four days earlier was green against the same base image tag and the same Dockerfiles.

The scanner is configured `ignore-unfixed: true`, which is what makes this a *scheduling* problem rather than a code one. Trivy stays silent about a vulnerability until Debian ships a fix, then fails the build the moment one exists — so the gate trips on the upstream release calendar, and the triggering commit is whichever one happens to run next. Pinning the base image tag does not help; the tag is a moving target that Docker Hub rebuilds on its own cadence, and until it does, every build pulls the unpatched packages.

Two things make the failure read worse than it is. GitHub shows `0 / 3`, but the matrix's default `fail-fast: true` **cancelled** the other two jobs the moment one failed — they never ran, rather than failing. And the results table lists nine HIGH findings, which is one CVE counted nine times: `bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, and `util-linux` are all binary packages built from the same source. Read the Vulnerability column, not the row count.

The fix is to patch at build time rather than wait for the base image, in the final stage of each Dockerfile before `USER app`:

```dockerfile
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
```

Placed before the `COPY` of application source so an app change does not invalidate the layer. The builder stage needs no equivalent — only `/opt/venv` is copied out of it, which holds Python packages and no OS libraries.

The general shape is worth recognising beyond this one CVE: a build whose success depends on upstream timing rather than on repository state will fail on an arbitrary unrelated commit, and the commit will look like the cause. The same run also began warning that `actions/checkout@v4`, `actions/setup-python@v5`, and `aws-actions/configure-aws-credentials@v4` target a deprecated Node.js 20 and are being forced onto Node 24 — a different mechanism, same drift, and a warning today rather than a failure.

<a id="29"></a>
### 29. Chaos Mesh breaks under ArgoCD because Helm generates its webhook cert at render time

**Symptom.** Chaos Mesh deployed as an ArgoCD Application on EKS fails chaos CR creation with `x509: certificate signed by unknown authority`. Upstream [issue #4764](https://github.com/chaos-mesh/chaos-mesh/issues/4764), open. Reported against workflow creation, but one webhook server serves every chaos CR type.

**Cause.** With `webhook.certManager.enabled: false` (the chart default, and what we use), the chart generates the webhook's cert itself. Its `values.yaml` says of `caBundlePEM`, `crtPEM` and `keyPEM`: *"if empty and disable certManager, Helm will auto-generate these fields."*

That generation happens **when Helm renders the chart**, not at runtime in the controller — and `genSignedCert` produces a different certificate every time it runs. So:

- **Terraform** renders once, stores the result in state, and never re-renders. The cert is stable.
- **ArgoCD** re-renders on every sync, producing a fresh certificate each time. The webhook server keeps serving the key it started with, selfHeal overwrites the `caBundle` with the newly generated one, the two stop matching, and TLS verification fails.

**This is why chaos-mesh is a Terraform `helm_release` and not a sixth ArgoCD Application** (`terraform/modules/chaos-mesh/main.tf`).

**One detail that will mislead you when debugging this.** The chart pins the *leaf* certificate as its own trust anchor: the `caBundle` in the `chaos-mesh-mutation` MutatingWebhookConfiguration is byte-identical to the serving cert in the `chaos-mesh-webhook-certs` Secret (`sha256 A5:31:4B:8A:79:13:97:E7...` here; `CN=chaos-mesh-controller-manager.chaos-mesh.svc`, issued by `CN=chaos-mesh-ca`, valid 2026-08-31 to 2031-08-30). Go's x509 verifier accepts a certificate that is itself in the root pool, so this is fine. But `openssl verify -CAfile` **rejects** it, because openssl insists on a real issuer chain. Do not use openssl's verdict to diagnose this — it reports a failure that is not there.

**Live constraint going forward.** Any future `helm upgrade` of this release regenerates the certs. A chart version bump is a webhook-affecting change: verify it by creating a chaos CR afterwards. Pods going Ready proves nothing here.

<a id="30"></a>
### 30. `chaos-daemon` logs a `/dev/fuse` ERROR on every node, and mostly does not mean it

Every `chaos-daemon` pod logs this at startup:

```
ERROR chaos-daemon.daemon-server  grant access to /dev/fuse
      {"error": "fail to find device cgroup"}
```

**It is not a misconfiguration and no setting fixes it.** The nodes are Amazon Linux 2023 running `cgroup2fs` (confirm with `stat -fc %T /sys/fs/cgroup`). cgroup v2 has no `devices` controller — device access is enforced through eBPF instead — so the lookup `fusedev.GrantAccess` performs cannot succeed on any cgroup v2 node.

**It is non-fatal.** The daemon continues past it, remounts `/sys` read-write, and starts both endpoints, logging `{"runtime": "containerd"}`. PodChaos verified working with this error present.

**Scoped risk, not a confirmed failure.** `/dev/fuse` backs Chaos Mesh's FUSE-based filesystem injection, so **IOChaos may be degraded or unusable** here. This has not been tested. PodChaos, NetworkChaos, StressChaos, TimeChaos, DNSChaos and HTTPChaos are unaffected.

**Action required before Week 7 scenario design.** The planned storage-latency scenario is modelled on vSAN incidents, and IOChaos is the obvious tool for it. Verify IOChaos works before committing to that scenario, not during it. If it does not, the alternatives are StressChaos on disk I/O, or NetworkChaos latency against Postgres.

Worth naming for its shape: this is the **inverse** of the recurring "configured, reports healthy, does nothing" pattern (#21, #24). This one reports broken and mostly works. Both defeat the same reflex — reading the status line instead of testing the behaviour.

<a id="31"></a>
### 31. Git Bash rewrites absolute paths passed to `kubectl exec`

`kubectl -n chaos-mesh exec <pod> -- stat -fc %T /sys/fs/cgroup` failed in Git Bash with:

```
stat: cannot read file system information for 'C:/Program Files/Git/sys/fs/cgroup'
```

MSYS path conversion rewrites anything that looks like an absolute POSIX path into a Windows path before the native command sees it. The path was meant for the *container*, but the rewrite happens on the way out of the shell, so the container received a Windows path that cannot exist there.

The fix is to disable the conversion for that command:

```
MSYS_NO_PATHCONV=1 kubectl -n chaos-mesh exec <pod> -- stat -fc %T /sys/fs/cgroup
```

Same family as #20 — a shell mangling arguments to a native command — but a different shell and a different mechanism, so both have to be known separately: PowerShell re-quotes, Git Bash re-paths.

<a id="32"></a>
### 32. Automated remediation erases the evidence its own guard reads

**The general pattern: any automated action that removes a component from observation destroys the signal a multi-component guard depends on.** Quarantining, cordoning, draining, scaling to zero, pulling a backend out of a load balancer — each silences the very evidence that would have said "stop, this is systemic." A guard that reads live alert state must account for the fact that acting on one member changes what it can see about the rest.

**What happened here.** `railhead-remediator` refuses to quarantine when several pods alert at once, because a shared dependency failing is not one bad pod. A Week 7 experiment took Postgres away from both `railhead-api` replicas and the guard **never engaged**: both pods quarantined, zero refusals (measurements in `week7-chaos-scorecard.md`).

**Why.** Quarantining pod A rewrites its `app` label, dropping it from the Service. The ServiceMonitor scrapes *through* the Service, so Prometheus stops scraping A, its series goes stale, and **A's alert resolves**. When B fires, B genuinely is the only firing pod.

Two conditions combined, and the guard needed only one:

- **`for: 2m` timers desynchronise.** A simultaneous fault does not produce simultaneous alerts — the two error ratios crossed the threshold ~65s apart. Prometheus never sends a `pending` alert, so the first webhook legitimately carried one pod and `multi_pod` was correctly `False`.
- **The `status == "firing"` filter.** The second webhook *did* contain both pods (`send_resolved = true`), but the guard counts only firing alerts, so the resolved pod contributed nothing.

Alertmanager grouping worked exactly as configured. Two paper reviews predicted this failure and both blamed grouping; both were wrong.

The `ready_replicas` backstop was then defeated benignly: the ReplicaSet's replacement reached Ready, `readyReplicas` returned to 2, and `ready - 1 >= MIN_REMAINING_READY` passed. It was **not a total outage** — but note the precise wording: that guard was *evaluated and permitted the action*. It never refused anything.

**A guard that permits has not "refused".** That distinction was lost three separate times while writing this up — in the README summary, in the alert's own `description` annotation, and in a code comment beside the rule — each drifting into language that credited a control with *acting* when it had merely *passed*. It reads better, which is exactly why it happens, and it is the kind of claim someone relies on at 3am. This entry stated it correctly from the start, which is the only reason the drift in the summaries was visible at all. When writing up a safety control, check whether it fired or was simply never the binding constraint.

**What to do.** Count pods from the alert *group* rather than firing-only; or gate on Deployment-level unavailable replicas; or add a cooldown between quarantines. Not applied — the measured behaviour is the artifact.

**Method note.** The cause is an interaction between the remediator, the Service selector, the ServiceMonitor and Prometheus staleness — visible in no single file. A code review found the risk; only running it found the cause.

<a id="33"></a>
### 33. `/metrics` sits in the SLO denominator and can stop an alert firing

**Fixed 2026-09-05 — see the end of this entry.** As originally built,
`RailheadAPIPodErrorRate` and both SLO burn-rate families excluded
`handler!="/health"` and nothing else. `/metrics` is instrumented by the same middleware, and Prometheus scrapes it at roughly the rate the worker generates real traffic — so scrape traffic was measured at **~45% of the alert's denominator**.

During a single-pod partition, with *every* `/items` request returning 5xx, the per-pod error ratio ceiling was about `0.05 / (0.05 + 0.048) = 0.51` against a `0.5` threshold. The observed ratio oscillated between **0.438 and 0.550** — re-queried from Prometheus afterwards rather than read off the alerts page, which is why the low end is 0.438 and not the 0.471 the page happened to be showing. The first `PENDING` period was abandoned mid-count when it dipped, resetting the `for: 2m` timer. Note the observed max of 0.550 exceeded the 0.51 ceiling calculated above: that calculation used one snapshot of the traffic mix, and the `/metrics` share actually moved between **32.8% and 60.9%** across the fault. Detection took **13m52s** against a predicted 4-6 minutes, and needed two attempts.

The delay is not the problem. **A 2% margin means the alert can fail to fire at all** on a shorter fault, or if the scrape interval were tightened, or if real traffic dropped. The pod would be serving nothing but errors and nothing would say so.

This is #24's pattern one layer down. `/health` was recognised as non-representative traffic and excluded; `/metrics` is equally non-representative and was not. The generalisable check: **an SLO denominator should contain only traffic a user could generate.** Probe traffic and scrape traffic both dilute it, and dilution always moves the ratio in the direction that hides problems.

**The fix, applied and re-measured.** `handler!~"/health|/metrics"` in all five rules — note the operator, `!~` not `!=`, because the exclusion is now an alternation, and Prometheus anchors `!~` fully so it matches those two values exactly. Re-running the same scenario unchanged took detection from **13m52s to 5m46s**, with no abandoned `PENDING` and the ratio pinned at **1.0** instead of oscillating with a 2% margin.

Removing `/metrics` does more than speed it up: it makes the ratio **independent of throughput**. With only `/items` in the denominator, a pod failing every request reads 1.0 no matter how far its throughput has collapsed. Measured before injection, `/metrics` was a *fixed* 0.03333/s per pod — one scrape per 30s, load-independent — against `/items` at 0.04444/s. A constant term in a denominator whose other term collapses under fault dilutes worst exactly when detection matters most.

**Verify the change at the right layer.** A malformed regex makes Prometheus reject the entire rule group, leaving *no* per-pod alert — worse than a slow one. `terraform apply` succeeding only proves the ArgoCD Application was written; the rule still has to sync and load. Gate on reading it back: `/api/v1/rules` showing all five rules present with group health `ok`.

<a id="34"></a>
### 34. `service_number_of_running_pods` counts pod phase, not readiness

`railhead-dev-remediator-down` alarms when Container Insights reports fewer than 1 running pod for the `railhead-remediator` Service. It exists because nothing else watches the remediator, and Prometheus cannot reliably alert on a failure inside its own cluster.

**What happened.** A Week 7 check held the remediator down for ten minutes with Chaos Mesh `pod-failure`. Throughout, the pod was `0/1` Ready with **zero ready endpoints**, repeatedly `CrashLoopBackOff`, accumulating 8 restarts. The alarm stayed `OK`, and `service_number_of_running_pods` reported exactly `1.0` for **every single minute**.

**Why.** The metric is derived from pod **phase**, not readiness or EndpointSlice membership. `pod-failure` swaps the container image for a pause image, and a pause container runs happily, so the pod stays in `Running` phase and keeps counting as one. The alarm only fires when the pod is **deleted** or the metric **stops publishing** — exactly why it fired during teardown, and why that observation proved less than it appeared to.

The blind spot is broader than the injected fault: a crashloop, a deadlock, or a hung HTTP server all present identically as `Running`-but-not-`Ready`. Those are the realistic ways this component fails, and none are covered.

**What to do.** An external synthetic probe against `/healthz` is the honest fix. A readiness-derived Prometheus metric would be accurate but reintroduces the in-cluster dependency the alarm exists to avoid — the alarm is coarse *because* it is independent, and that tradeoff is worth keeping deliberately rather than fixing carelessly. Recommended, not implemented.

<a id="35"></a>
### 35. A PowerShell pipeline returning one object has no `.Count`

`chaos/run-scenario-1.ps1` refused to run on its first real use, reporting `Need 2 ready railhead-api pods, found 0` while `kubectl get pods` showed both pods `1/1 Running`.

The filter was `($_.status.containerStatuses | Where-Object { $_.ready }).Count -gt 0`. In PowerShell 5.1 a pipeline that emits **exactly one** object returns that object, not a collection, and a bare object has no `.Count` property — the expression evaluates to `$null`, and `$null -gt 0` is `$false`. Every single-container pod was therefore classified as not ready. Wrapping the inner pipeline in `@(...)` forces a collection and `.Count` becomes 1.

The script already wrapped its *outer* pipeline in `@()` for this exact reason. Only the inner one was missed, which is the failure mode worth remembering: the idiom is known, and it still gets dropped one level down.

Two lessons. **`@()` around any pipeline whose `.Count` you intend to read**, without exception, because the bug only appears when the result happens to have one element — so it passes every test with two or more and fails on the realistic case. And the fixed version counts *not-ready* containers and requires zero, which is both immune to the same trap and semantically stricter: it requires every container in the pod to be ready rather than at least one.

<a id="36"></a>
### 36. A number read off a rendered UI is not a measurement

Two figures published in the Week 7 write-ups were wrong, and both failed the same way.

The per-pod error ratio was recorded as oscillating **0.471–0.550**. Re-querying the same expression over the same window afterwards returns a minimum of **0.438**: `0.500, 0.550, 0.526, 0.471, 0.471, 0.471, 0.500, 0.471, 0.438, ...`. 0.471 was the value the Prometheus alerts page happened to be displaying, and it recurs often enough to look like a floor. It is not one.

`readyReplicas` was recorded as the sequence **1,1,1,1,2,2,1,2,2,2**, transcribed from a `kubectl get deploy -w` that was being watched rather than captured. Querying `kube_deployment_status_replicas_ready` shows something different in shape: a **single** contiguous dip — 2 until 20:28:08, 1 for seven consecutive 30s scrapes, 2 from 20:31:38 — not the two dips the sequence implies. The headline conclusion survived (it never reached 0), but the evidence offered for it did not exist.

**Prometheus held both series the whole time.** Nothing prevented querying them; the numbers were simply taken from whatever was already on screen, at a moment chosen by when someone happened to look. A rendered page is a sample of a series at an arbitrary instant, and watching a stream is not the same as recording it.

**The rule: if a number goes into a document, query the source.** Screenshots are evidence that something occurred; they are not the measurement. Retention makes this nearly free — Prometheus here keeps 5 days and CloudWatch 15 months, so a claim written up within that window can always be checked before it is published rather than after. Both corrections above came from queries run after the fact, which is the expensive way to find out.
