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

# The two values a workflow needs to name. Neither is a credential: an ARN is
# useless without an OIDC token whose sub the trust policy accepts.
output "claude_code_role_arn" {
  description = "Role each repository's Claude workflow assumes to read the token."
  value       = aws_iam_role.claude_code.arn
}

output "terraform_role_arn" {
  description = "Role CI assumes to apply this configuration (written into .github/workflows/terraform.yml)."
  value       = aws_iam_role.terraform.arn
}

# What a repository writes into its workflow to sign as an app: the alias ARN as
# kms-key-id (an ARN carries its region, so nothing else has to say where the
# key is) and the role it assumes.
output "github_app_kms_key_aliases" {
  description = "Alias ARN of each GitHub App's KMS key, keyed by app name (the kms-key-id input)."
  value       = { for name, alias in aws_kms_alias.github_app : name => alias.arn }
}

output "github_app_role_arns" {
  description = "Role the repositories of each app assume to sign that app's JWT (the role-to-assume input)."
  value       = { for name, role in aws_iam_role.github_app : name => role.arn }
}

output "image_updater_role_arn" {
  description = "Role that reads the Image Updater app's private key (written into .github/workflows/image-updater-credential.yml)."
  value       = aws_iam_role.image_updater.arn
}
