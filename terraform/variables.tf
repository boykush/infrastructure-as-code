# Knobs for the single DOKS cluster this repository owns. The defaults are the
# live configuration; nothing overrides them (no tfvars, no CI variables), so a
# change here is the change. Anything not listed is fixed policy in main.tf.

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
