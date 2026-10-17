# Authentication comes from DIGITALOCEAN_ACCESS_TOKEN (a PAT with read + write
# scope), set locally and from the repository secret of the same name in CI.
# The provider also accepts DIGITALOCEAN_TOKEN; this name is the one doctl reads
# too, so one exported variable covers both tools.
provider "digitalocean" {}

# Authentication comes from CLOUDFLARE_API_TOKEN, a scoped token rather than the
# account-wide global key. Account: Cloudflare Tunnel, Workers R2 Storage (Edit);
# Access: Apps, Policies, Identity Providers (Write). Zone: DNS, Transform Rules
# (Edit); Zone (Read), as the zone and account IDs are looked up by name.
provider "cloudflare" {}

# Authentication comes from the environment: a local profile or SSO session on
# a workstation, and in CI the github-actions-terraform role assumed through
# GitHub's OIDC. There is no access key to hold anywhere.
provider "aws" {
  region = var.aws_region
}
