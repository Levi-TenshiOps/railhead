variable "cluster_name" {
  description = "Name of the EKS cluster Chaos Mesh is installed onto. Consumed as a namespace label rather than by the chart, which needs no cluster name -- see the note in main.tf on why this input exists."
  type        = string
}

variable "chaos_mesh_chart_version" {
  description = "Version of the chaos-mesh Helm chart to install"
  type        = string
  default     = "2.8.4"
}
