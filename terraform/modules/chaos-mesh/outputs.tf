output "namespace" {
  description = "Namespace Chaos Mesh is installed into"
  value       = kubernetes_namespace_v1.chaos_mesh.metadata[0].name
}

output "chart_version" {
  description = "Version of the chaos-mesh Helm chart that is installed"
  value       = helm_release.chaos_mesh.version
}
