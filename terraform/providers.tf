# Authentication comes from DIGITALOCEAN_ACCESS_TOKEN (a PAT with read + write
# scope), set locally and from the repository secret of the same name in CI.
# The provider also accepts DIGITALOCEAN_TOKEN; this name is the one doctl reads
# too, so one exported variable covers both tools.
provider "digitalocean" {}
