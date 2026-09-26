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
  description = "Nodes the default node pool is created with. Each is billed at the Droplet rate (s-2vcpu-4gb = $24/month); the control plane is free. After creation the count belongs to the schedule workflow, not to this value."
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
    {
      subdomain = "adr-mcp"
      service   = "http://adr.remote-mcp-server.svc.cluster.local:8080"
    },
    {
      subdomain = "backstage"
      service   = "http://backstage.backstage.svc.cluster.local:7007"
    },
  ]

  validation {
    condition     = length(var.tunnel_routes) == length(distinct([for route in var.tunnel_routes : route.subdomain]))
    error_message = "Each subdomain can appear once: a second entry would collide on the DNS record."
  }
}

variable "access_owner_email" {
  type        = string
  sensitive   = true
  description = "The one address Cloudflare Access lets into Backstage. Kept out of this public repository: CI passes it from the ACCESS_OWNER_EMAIL secret as TF_VAR_access_owner_email."

  # An unset Actions secret expands to an empty string rather than failing, which
  # would plan cleanly into a policy that admits no one.
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+$", var.access_owner_email))
    error_message = "access_owner_email must be an email address; check the ACCESS_OWNER_EMAIL secret."
  }
}

variable "aws_region" {
  type        = string
  description = "Region the Claude Code token and the IAM identities live in. IAM is global; the region only decides where Parameter Store keeps the value."
  default     = "ap-northeast-1"
}

variable "github_owner" {
  type        = string
  description = "Account the trusted repositories belong to. It is the owner half of the sub claim (repo:<owner>/<repo>:*), so it has to match GitHub exactly."
  default     = "boykush"
}

variable "github_owner_id" {
  type        = number
  description = "Numeric id of the owner, as GitHub writes it into the immutable sub claim. Unlike the name it never changes, so pinning it is what keeps a recycled name from matching."
  default     = 23194090
}

variable "claude_code_parameter_name" {
  type        = string
  description = "Parameter Store path holding the Claude Code OAuth token. The value is written with the CLI, never by Terraform."
  default     = "/claude-code/oauth-token"

  validation {
    condition     = startswith(var.claude_code_parameter_name, "/")
    error_message = "claude_code_parameter_name must start with a slash: the ARN is built by appending it to :parameter."
  }
}

variable "claude_code_repositories" {
  type        = list(string)
  description = "Repositories whose workflows may read the Claude Code token. Adding one here is the whole of onboarding it; nothing is set on the repository itself."

  default = [
    "adr",
    "ai-plugins",
    "boykush",
    "dotfiles",
    "finlake",
    "infrastructure-as-code",
    "livt",
    "renovate-runner",
    "scraps",
    "wiki",
    "workflows",
    "zenn",
  ]

  validation {
    condition     = length(var.claude_code_repositories) == length(distinct(var.claude_code_repositories))
    error_message = "Each repository can appear once: a duplicate only lengthens the trust policy."
  }
}

variable "image_updater_parameter_name" {
  type        = string
  description = "Parameter Store path holding the private key of the Image Updater GitHub App. The value is written with the CLI, never by Terraform."
  default     = "/image-updater/app-private-key"

  validation {
    condition     = startswith(var.image_updater_parameter_name, "/")
    error_message = "image_updater_parameter_name must start with a slash: the ARN is built by appending it to :parameter."
  }
}

variable "github_apps" {
  type = list(object({
    name         = string
    repositories = list(string)
    # Trusts only runs of each repository's main branch. A run a pull request
    # wakes executes that branch's own copy of the workflows, so trusting every
    # ref hands the signature to whatever can push a branch there.
    main_only = optional(bool, false)
  }))
  description = "GitHub Apps whose private key is imported into KMS, each with the repositories whose workflows may sign as it. What a repository is trusted with is the signature, never the key."

  default = [
    {
      name         = "terraform-ci"
      repositories = ["github-management"]
    },
    {
      name         = "renovate"
      repositories = ["renovate-runner"]
    },
    # renovate-runner, whose sweep approves Renovate's automerge-labelled PRs
    # across the owner's repositories, and livt, whose collect station approves
    # the report PR it has just opened; each only from its main branch. The
    # owner's own PRs get their approval from ai-review as the Claude GitHub
    # App, or go in through the owner's bypass.
    {
      name         = "pr-approver"
      repositories = ["renovate-runner", "livt"]
      main_only    = true
    },
    # Writes to a repository its workflow is not running in — pushing a branch
    # and opening a pull request that, unlike one from GITHUB_TOKEN, starts the
    # checks a ruleset requires. Its permissions stay at contents and
    # pull-requests: a shared write credential that accretes them is a master
    # key. The list is who may sign; where a write lands is where it is installed.
    {
      name         = "repo-writer"
      repositories = ["livt", "scraps"]
    },
  ]

  validation {
    condition     = length(var.github_apps) == length(distinct([for app in var.github_apps : app.name]))
    error_message = "Each app name can appear once: it names the key, its alias and the role."
  }
}
