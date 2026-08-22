# Authentication comes from DIGITALOCEAN_ACCESS_TOKEN (a PAT with read + write
# scope), set locally and from the repository secret of the same name in CI.
# The provider also accepts DIGITALOCEAN_TOKEN; this name is the one doctl reads
# too, so one exported variable covers both tools.
provider "digitalocean" {}

# Authentication comes from CLOUDFLARE_API_TOKEN, a scoped token rather than the
# account-wide global key. It needs Account: Cloudflare Tunnel (Edit) plus
# Zone: DNS (Edit) and Zone: Zone (Read), the latter because the zone and
# account IDs are looked up by name instead of being committed.
provider "cloudflare" {}
