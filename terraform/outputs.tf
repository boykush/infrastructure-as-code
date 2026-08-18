output "cluster_id" {
  description = "DOKS cluster UUID."
  value       = digitalocean_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "DOKS cluster name (kubeconfig context is do-<region>-<name>)."
  value       = digitalocean_kubernetes_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = digitalocean_kubernetes_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version DO resolved for the pinned minor track."
  value       = digitalocean_kubernetes_cluster.this.version
}

# kube_config is deliberately not exported: the token it embeds expires after
# 7 days, so a copied file silently stops working. Fetch a fresh one with
# `mise run k8s:kubeconfig` (doctl mints a long-lived context).
