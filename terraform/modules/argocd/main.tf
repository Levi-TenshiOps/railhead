terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace_v1" "railhead" {
  metadata {
    name = "railhead"
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  # ArgoCD's generic default health check (used for any CRD without a
  # specific customization) looks for a `type: Ready` status condition.
  # The Prometheus Operator's Prometheus CRD reports `Available`/
  # `Reconciled` conditions instead, so without this customization ArgoCD
  # perpetually shows a fully healthy Prometheus as "Progressing" — a
  # known, documented gap between ArgoCD's built-in health checks and
  # Prometheus-Operator CRDs, not something wrong with the stack itself.
  values = [<<-YAML
    configs:
      cm:
        resource.customizations.health.monitoring.coreos.com_Prometheus: |
          hs = {}
          if obj.status ~= nil then
            if obj.status.conditions ~= nil then
              numTrue = 0
              for i, condition in ipairs(obj.status.conditions) do
                if condition.type == "Available" and condition.status == "True" then
                  numTrue = numTrue + 1
                end
                if condition.type == "Reconciled" and condition.status == "True" then
                  numTrue = numTrue + 1
                end
              end
              if numTrue == 2 then
                hs.status = "Healthy"
                hs.message = "Prometheus is available and reconciled"
                return hs
              end
            end
          end
          hs.status = "Progressing"
          hs.message = "Waiting for Prometheus to become available and reconciled"
          return hs
    YAML
  ]
}

# ArgoCD auto-discovers repo credentials from any Secret in its namespace
# carrying this exact label — no separate `argocd repo add` step needed.
# The railhead repo is private, so without this ArgoCD can't clone it at
# all (a long-lived controller polling git isn't the same auth model as
# the GitHub Actions OIDC federation built earlier — that's scoped to
# GitHub Actions runs specifically, not usable here).
resource "kubernetes_secret_v1" "repo_credentials" {
  metadata {
    name      = "railhead-repo-credentials"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.github_repo_url
    username = "git"
    password = var.github_token
  }
}

# This Application is the actual GitOps definition: instead of a human
# running `helm install`, this tells ArgoCD to watch a path in a git repo
# and continuously reconcile the cluster to match it. Depends on the Helm
# release because the Application CRD only exists once ArgoCD itself is
# installed — see the chat explanation on why this forces two applies the
# first time around.
resource "kubernetes_manifest" "railhead_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "railhead"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = "default"

      source = {
        repoURL        = var.github_repo_url
        path           = "kubernetes/helm-charts/railhead-app"
        targetRevision = "main"
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.railhead.metadata[0].name
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  }

  depends_on = [helm_release.argocd, kubernetes_secret_v1.repo_credentials]
}

# Deployed as its own ArgoCD Application rather than via Terraform's helm
# provider, specifically because kube-prometheus-stack bundles its own CRDs
# (ServiceMonitor, PrometheusRule, etc.). Installing those CRDs and any
# instance of them in the same terraform apply hits the exact same
# plan-time schema-validation problem the railhead Application did against
# ArgoCD's own CRD — letting ArgoCD's sync engine own the whole install
# sidesteps it entirely, since ArgoCD reconciles CRDs-then-resources
# itself rather than needing Terraform to sequence it.
#
# Source is a Helm-chart-repo source (chart + targetRevision as the chart
# version), not a git-repo source (path + branch) like the railhead
# Application — ArgoCD supports both, and this is the chart-repo flavor.
resource "kubernetes_manifest" "observability_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "observability"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://prometheus-community.github.io/helm-charts"
        chart          = "kube-prometheus-stack"
        targetRevision = var.kube_prometheus_stack_chart_version

        helm = {
          valuesObject = {
            # CRD install is deliberately left to ArgoCD/Helm normally, but
            # this chart's CRDs (Prometheus, Alertmanager, etc.) are large
            # enough to hit Kubernetes' 256KiB total-annotation-size limit
            # on client-side apply, and ArgoCD's ServerSideApply=true
            # syncOption (the documented fix) did not resolve it in
            # practice here even after a forced hard refresh. Verified
            # `kubectl apply --server-side` on these exact CRD manifests
            # DOES succeed at the Kubernetes API level, so the CRDs were
            # bootstrapped once, manually, outside GitOps — crds.enabled
            # tells the chart not to fight over them afterward. Everything
            # else in this Application stays fully ArgoCD-managed.
            crds = {
              enabled = false
            }

            # Alertmanager is Week 6 territory (alerting), not needed yet.
            alertmanager = {
              enabled = false
            }

            # These control-plane components aren't scrapable on EKS (AWS
            # manages them, no access to their metrics endpoints) — leaving
            # them enabled would just create permanently-"down" targets in
            # Prometheus with nothing actionable about them.
            kubeControllerManager = { enabled = false }
            kubeScheduler         = { enabled = false }
            kubeEtcd              = { enabled = false }
            kubeProxy             = { enabled = false }

            prometheus = {
              prometheusSpec = {
                retention = "5d"

                resources = {
                  requests = { cpu = "100m", memory = "256Mi" }
                  limits   = { cpu = "500m", memory = "512Mi" }
                }
              }

              # Tells Prometheus to scrape the api's /metrics endpoint, via
              # Helm values instead of a separate Terraform-managed
              # ServiceMonitor CRD instance — same CRD-ordering reasoning
              # as this whole Application being ArgoCD-managed. Sibling of
              # prometheusSpec, not nested inside it — misplacing this one
              # level too deep is a silent no-op, not an error.
              additionalServiceMonitors = [
                {
                  name = "railhead-api"
                  selector = {
                    matchLabels = {
                      app = "railhead-api"
                    }
                  }
                  namespaceSelector = {
                    matchNames = ["railhead"]
                  }
                  endpoints = [
                    {
                      port     = "http"
                      path     = "/metrics"
                      interval = "30s"
                    }
                  ]
                }
              ]
            }

            prometheusOperator = {
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { cpu = "100m", memory = "128Mi" }
              }
            }

            # Second real use of the EBS CSI driver besides Postgres.
            # Persistence alone isn't the real safety net for dashboards,
            # though — a PVC can still get wiped by an incident (as
            # happened once already). The kubernetes_config_map_v1
            # resources below (see end of file) are the actual durable
            # fix: dashboards defined as git-committed content, loaded via
            # the chart's dashboard sidecar regardless of what happens to
            # the PVC. Not using this chart's own `dashboards` values key
            # for this — its own template labels the ConfigMap
            # `dashboard-provider: default`, not `grafana_dashboard: "1"`,
            # which is the label kube-prometheus-stack's sidecar actually
            # watches for, so it silently never gets picked up.
            grafana = {
              persistence = {
                enabled          = true
                size             = "2Gi"
                storageClassName = "gp3"
              }

              resources = {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { cpu = "200m", memory = "256Mi" }
              }
            }

            "kube-state-metrics" = {
              resources = {
                requests = { cpu = "20m", memory = "64Mi" }
                limits   = { cpu = "100m", memory = "128Mi" }
              }
            }

            "prometheus-node-exporter" = {
              resources = {
                requests = { cpu = "20m", memory = "32Mi" }
                limits   = { cpu = "50m", memory = "64Mi" }
              }
            }
          }
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
      }

      # ServerSideApply is required here specifically because of this
      # chart's CRDs (Prometheus, Alertmanager, etc.) — they're large
      # enough that default client-side apply fails outright trying to
      # stuff the whole manifest into the last-applied-configuration
      # annotation, which hits Kubernetes' 256KiB total-annotation-size
      # limit. Server-side apply tracks field ownership differently and
      # doesn't need that annotation at all.
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["ServerSideApply=true"]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# Dashboards-as-code: these two ConfigMaps are the actual durable fix for
# the dashboard-loss incident. Labeled to match exactly what
# kube-prometheus-stack's Grafana sidecar already watches for (confirmed
# against the working built-in dashboards) — the chart's own
# `grafana.dashboards` values key labels its generated ConfigMap
# differently and is silently never picked up, which is why these are
# managed directly here instead.
resource "kubernetes_config_map_v1" "railhead_api_metrics_dashboard" {
  metadata {
    name      = "railhead-api-metrics-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "railhead-api-metrics.json" = file("${path.module}/../../../kubernetes/observability/dashboards/api-metrics.json")
  }
}

resource "kubernetes_config_map_v1" "railhead_cluster_health_dashboard" {
  metadata {
    name      = "railhead-cluster-health-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "railhead-cluster-health.json" = file("${path.module}/../../../kubernetes/observability/dashboards/cluster-health.json")
  }
}

# Loki in SingleBinary mode: all components (distributor, ingester,
# querier, compactor, etc.) run in one process/pod instead of scaled-out
# separately — the right tradeoff for this cluster's actual log volume.
# Switching deploymentMode away from the chart's own default
# (SimpleScalable) requires explicitly zeroing read/write/backend
# replicas below; the chart does not do this automatically and a
# combined-mode apply otherwise fails validation.
resource "kubernetes_manifest" "loki_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "loki"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "loki"
        targetRevision = var.loki_chart_version

        helm = {
          valuesObject = {
            deploymentMode = "SingleBinary"

            singleBinary = {
              replicas = 1

              persistence = {
                enabled      = true
                size         = "5Gi"
                storageClass = "gp3"
              }

              resources = {
                requests = { cpu = "100m", memory = "256Mi" }
                limits   = { cpu = "500m", memory = "512Mi" }
              }
            }

            # SimpleScalable-mode components — must be zeroed when running
            # SingleBinary, since their defaults (3 replicas each) assume
            # the other deployment mode.
            read    = { replicas = 0 }
            write   = { replicas = 0 }
            backend = { replicas = 0 }

            gateway = {
              resources = {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { cpu = "50m", memory = "64Mi" }
              }
            }

            # No multi-tenancy needed for a single-app portfolio cluster.
            # Optional caching/canary sidecars disabled to keep this lean
            # on a 2x t3.medium cluster already running quite a lot.
            # test.enabled must come down with lokiCanary: the chart's own
            # validate.yaml refuses canary-less Helm test hooks, and ArgoCD
            # doesn't invoke `helm test` in this GitOps setup anyway.
            chunksCache  = { enabled = false }
            resultsCache = { enabled = false }
            lokiCanary   = { enabled = false }
            test         = { enabled = false }

            serviceAccount = {
              annotations = {
                "eks.amazonaws.com/role-arn" = var.loki_irsa_role_arn
              }
            }

            loki = {
              auth_enabled = false

              limits_config = {
                retention_period = "168h"
              }

              # Chart default (3) assumes a multi-replica ring; with a single
              # singleBinary pod, the ingester refuses writes/reads once it
              # can't find enough live replicas to satisfy the factor.
              commonConfig = {
                replication_factor = 1
              }

              storage = {
                type = "s3"

                bucketNames = {
                  chunks = var.loki_bucket_name
                  ruler  = var.loki_bucket_name
                  admin  = var.loki_bucket_name
                }

                s3 = {
                  region = "us-east-1"
                }
              }

              # Required — no default. TSDB is the current recommended
              # index type (boltdb-shipper is the older, now-legacy path).
              schemaConfig = {
                configs = [
                  {
                    from         = "2024-01-01"
                    store        = "tsdb"
                    object_store = "s3"
                    schema       = "v13"
                    index = {
                      prefix = "loki_index_"
                      period = "24h"
                    }
                  }
                ]
              }
            }
          }
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["ServerSideApply=true"]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# Deployed as its own Application, not bundled with Loki — the Loki chart
# has no Alloy dependency at all (checked its Chart.yaml directly: its
# only dependencies are minio, grafana-agent-operator, and
# rollout-operator). Alloy is Grafana's current, supported log shipper;
# Promtail (the older choice) reached end-of-life in March 2026.
resource "kubernetes_manifest" "alloy_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "alloy"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "alloy"
        targetRevision = var.alloy_chart_version

        helm = {
          valuesObject = {
            controller = {
              type = "daemonset"
            }

            # This chart ships an empty ClusterRole by default — without
            # these rules, Alloy's pods would run but silently collect
            # nothing. `pods/log` (get) is what actually lets
            # loki.source.kubernetes read log content via the kubelet
            # API; the rest is what discovery.kubernetes needs to find
            # targets in the first place.
            rbac = {
              create = true
              clusterRules = [
                {
                  apiGroups = [""]
                  resources = ["pods", "nodes", "nodes/proxy", "services", "endpoints"]
                  verbs     = ["get", "list", "watch"]
                },
                {
                  apiGroups = [""]
                  resources = ["pods/log"]
                  verbs     = ["get"]
                }
              ]
            }

            alloy = {
              configMap = {
                create  = true
                content = <<-EOT
                  discovery.kubernetes "pods" {
                    role = "pod"
                  }

                  discovery.relabel "pods" {
                    targets = discovery.kubernetes.pods.targets

                    rule {
                      source_labels = ["__meta_kubernetes_namespace"]
                      target_label  = "namespace"
                    }

                    rule {
                      source_labels = ["__meta_kubernetes_pod_name"]
                      target_label  = "pod"
                    }

                    rule {
                      source_labels = ["__meta_kubernetes_pod_container_name"]
                      target_label  = "container"
                    }
                  }

                  loki.source.kubernetes "pods" {
                    targets    = discovery.relabel.pods.output
                    forward_to = [loki.write.default.receiver]
                  }

                  loki.write "default" {
                    endpoint {
                      url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
                    }
                  }
                EOT
              }
            }

            resources = {
              requests = { cpu = "50m", memory = "128Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }
          }
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["ServerSideApply=true"]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# Reuses the exact same sidecar-ConfigMap mechanism as the dashboard fix
# earlier — same chart, same sidecar container, just watching a
# different label (`grafana_datasource` instead of `grafana_dashboard`)
# for a different content type (a datasource provisioning YAML instead
# of a dashboard JSON).
resource "kubernetes_config_map_v1" "loki_datasource" {
  metadata {
    name      = "loki-datasource"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          access    = "proxy"
          url       = "http://loki-gateway.monitoring.svc.cluster.local"
          isDefault = false
          jsonData = {
            maxLines = 1000
          }
        }
      ]
    })
  }
}
