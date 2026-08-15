# AWS-native monitoring — what's deployed, and how to query it

## What's deployed

The `amazon-cloudwatch-observability` EKS add-on (pinned `v6.5.0-eksbuild.1`),
authenticated by IRSA scoped to `amazon-cloudwatch:cloudwatch-agent`. It runs
alongside Prometheus/Grafana/Loki rather than replacing them.

Six of the add-on's seven optional workloads are switched off: container log
shipping (Loki owns logs), `kubeStateMetrics` and `nodeExporter` (both already
running via kube-prometheus-stack), plus Application Signals, DCGM and Neuron.
Only `containerInsights` stays on — that's the cluster/node/pod metric pipeline.

Two log groups, both Terraform-managed with 1-day retention:

| Log group | Contents |
|---|---|
| `/aws/eks/railhead-dev/cluster` | Control-plane `api` and `audit` logs |
| `/aws/containerinsights/railhead-dev/performance` | Container Insights metrics (embedded metric format) |

Three alarms, none with a notification action — Alertmanager owns routing:
`remediator-down`, `node-filesystem-high` (80%), `apiserver-storage-growth`
(100 MB).

## Why the audit log matters

AWS operates the control plane. The API server exposes a scrapeable `/metrics`
endpoint and this cluster does scrape it, but `kube-scheduler`,
`kube-controller-manager`, and etcd do not — which is why those three scrape
jobs are disabled in `terraform/modules/argocd/main.tf` rather than left
permanently down.

The audit log is a different matter: it is not a metrics endpoint at all, so
Prometheus cannot collect it in any configuration. That makes it the clearest
thing CloudWatch adds here rather than duplicates.

It also makes RBAC checkable. A `Role` manifest states what a workload *may*
do; the audit log records what it actually did.

## Running the queries

**CloudWatch → Logs → Logs Insights**, select `/aws/eks/railhead-dev/cluster`,
set a time range covering the period of interest, paste, Run query.

The log group is destroyed with the cluster at teardown, so the output captured
below is a record of one session. The queries themselves work on any rebuild
once the cluster has generated some traffic.

---

## 1. Least privilege, checked from outside the cluster

```
fields @timestamp, verb, objectRef.resource, objectRef.namespace, responseStatus.code
| filter user.username = "system:serviceaccount:railhead:railhead-remediator"
| sort @timestamp desc
| limit 20
```

Captured 2026-08-15 over a 3-hour window — `Showing 2 of 2 matched`:

```
2026-08-15T01:21:06.403Z  |  list  |  pods  |  railhead  |  200
2026-08-15T00:13:25.689Z  |  list  |  pods  |  railhead  |  200
```

The remediator's `Role` grants `get/list/patch/delete` on pods, `get` on
`pods/log`, and `get` on deployments. Across the whole session it used one
verb, in one namespace. Nothing was patched or deleted, because no actionable
alert fired.

Only two entries because the remediator is a webhook handler, not a controller
— it has no watch loop and no informer. Its first API call happens inside
`sweep_and_count()`, which runs only when a POST reaches `/webhook`. Idle, it
makes no API calls at all, which is visible here as an absence next to
reconcilers like ArgoCD's controller in query 2.

Screenshot: `screenshots/cloudwatch-logs-insights-least-privilege.png`

---

## 2. Who actually calls the API server

```
fields @timestamp, user.username
| filter ispresent(user.username)
| stats count(*) as calls by user.username
| sort calls desc
| limit 15
```

Captured over a 3-hour window — `Showing 15 of 108,272 matched`, 112,961
records (178.3 MB) scanned:

```
system:serviceaccount:kube-system:ebs-csi-controller-sa      12814
system:anonymous                                             10836
system:kube-controller-manager                                9419
system:apiserver                                              8099
system:kube-scheduler                                         7869
eks:k8s-metrics                                               6881
eks:cloud-controller-manager                                  6388
system:serviceaccount:argocd:argocd-application-controller    5211
eks:network-policy-controller                                 4223
eks:coredns-autoscaler                                        4079
system:node:ip-10-0-11-50.ec2.internal                        3191
system:serviceaccount:amazon-cloudwatch:cloudwatch-agent      3011
system:node:ip-10-0-10-74.ec2.internal                        2916
eks:vpc-resource-controller                                   2807
system:serviceaccount:monitoring:alloy                        2712
```

`kube-scheduler` and `kube-controller-manager` sit near the top with thousands
of calls each, and neither is scraped by Prometheus on this cluster — their
scrape jobs are disabled because AWS exposes no endpoint for them. The API
server above them *is* scraped, so the gap CloudWatch fills here is those two
plus etcd, not the control plane wholesale.

Counts are specific to this window and grow with uptime; the ordering below the
top few also shifts between runs. Treat them as a shape, not a benchmark.

Also useful as a baseline before chaos work: on an idle cluster the EBS CSI
controller is the busiest caller, and the remediator doesn't appear at all.

Screenshot: `screenshots/cloudwatch-logs-insights-top-callers.png`

---

## 3. RBAC denials

```
fields @timestamp, user.username, verb, objectRef.resource
| filter responseStatus.code = 403
| stats count(*) as denials by user.username, objectRef.resource
| sort denials desc
| limit 15
```

```
eks:az-poller  |  leases  |  150
```

An AWS-managed component, not a project workload — ordinary background noise on
EKS. The clean result is the point: nothing in this cluster is being denied
anything it needs.

---

## 4. Destructive operations

```
fields @timestamp, user.username, objectRef.resource, objectRef.namespace, objectRef.name
| filter verb = "delete"
| sort @timestamp desc
| limit 20
```

Zero results this session — nothing was deleted after the cluster converged.

This is the one to run first after any unexpected change: it answers what was
deleted, by whom, and when. The remediator's own quarantine TTL deletions would
appear here.
