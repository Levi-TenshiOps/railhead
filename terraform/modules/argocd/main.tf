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

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
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
