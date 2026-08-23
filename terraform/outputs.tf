# id and endpoint are marked sensitive so neither terraform nor tfcmt — which
# echoes plan/apply output into pull request comments — prints them in this
# public repository. Read them locally with `terraform output -raw <name>`.
output "cluster_id" {
  description = "DOKS cluster UUID."
  value       = digitalocean_kubernetes_cluster.this.id
  sensitive   = true
}

output "cluster_name" {
  description = "DOKS cluster name (kubeconfig context is do-<region>-<name>)."
  value       = digitalocean_kubernetes_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = digitalocean_kubernetes_cluster.this.endpoint
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version DO resolved for the pinned minor track."
  value       = digitalocean_kubernetes_cluster.this.version
}

# kube_config is deliberately not exported: the token it embeds expires after
# 7 days, so a copied file silently stops working. Fetch a fresh one with
# `mise run k8s:kubeconfig` (doctl mints a long-lived context).

# The connector's whole configuration, and a credential: this is what the
# Secret cloudflared reads holds. Sensitive because tfcmt echoes plan output
# into pull request comments on this public repository. Read it locally with
# `terraform output -raw tunnel_token` when creating that Secret.
output "tunnel_token" {
  description = "Token the cloudflared connector authenticates the tunnel with."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  sensitive   = true
}
