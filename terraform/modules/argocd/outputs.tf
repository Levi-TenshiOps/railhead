output "argocd_namespace" {
  description = "Namespace ArgoCD itself runs in"
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "railhead_namespace" {
  description = "Namespace the railhead app is deployed into by ArgoCD"
  value       = kubernetes_namespace_v1.railhead.metadata[0].name
}
