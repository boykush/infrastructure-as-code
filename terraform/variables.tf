# Knobs for the single DOKS cluster this repository owns and for the Cloudflare
# tunnel in front of it. The defaults are the live configuration; nothing
# overrides them (no tfvars, no CI variables), so a change here is the change.
# Anything not listed is fixed policy in main.tf / cloudflare.tf.

variable "region" {
  type        = string
  description = "DigitalOcean region slug. DO has no Tokyo region; sgp1 is the closest one to Japan."
  default     = "sgp1"
}

variable "cluster_name" {
  type        = string
  description = "DOKS cluster name. doctl derives the kubeconfig context from it: do-<region>-<name>."
  default     = "boykush-cluster"
}

variable "kubernetes_version_prefix" {
  type        = string
  description = "Minor release to pin, trailing dot included. The patch is resolved from DO's supported list at plan time."
  default     = "1.36."

  validation {
    condition     = endswith(var.kubernetes_version_prefix, ".")
    error_message = "kubernetes_version_prefix must end with a dot (e.g. \"1.36.\"), otherwise 1.3 would also match 1.30."
  }
}

variable "node_size" {
  type        = string
  description = "Droplet size slug for the default node pool. s-2vcpu-4gb is the smallest that fits Argo CD plus the DOKS system pods."
  default     = "s-2vcpu-4gb"
}

variable "node_count" {
  type        = number
  description = "Nodes in the default node pool. Each is billed at the Droplet rate (s-2vcpu-4gb = $24/month); the control plane is free."
  default     = 1

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "domain" {
  type        = string
  description = "Zone the tunnel publishes under. Also how zone_id and account_id are resolved, so it has to match the zone name in Cloudflare exactly."
  default     = "boykush.com"
}

variable "tunnel_routes" {
  type = list(object({
    subdomain = string
    service   = string
  }))
  description = "Public hostnames the tunnel serves, one per entry. service is the in-cluster URL cloudflared dials; it crosses namespaces, so it has to be the FQDN form http://<svc>.<namespace>.svc.cluster.local:<port>."

  default = [
    {
      subdomain = "wiki-mcp"
      service   = "http://wiki.remote-mcp-server.svc.cluster.local:1113"
    },
  ]

  validation {
    condition     = length(var.tunnel_routes) == length(distinct([for route in var.tunnel_routes : route.subdomain]))
    error_message = "Each subdomain can appear once: a second entry would collide on the DNS record."
  }
}
