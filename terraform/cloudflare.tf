# Zone and account IDs are read back from the domain name rather than written
# down, so neither identifier lands in this public repository. Costs the API
# token one extra permission (Zone: Zone Read).
data "cloudflare_zones" "this" {
  name = var.domain
}

# Marked sensitive so that tfcmt, which echoes plan output into pull request
# comments here, does not print the two IDs the lookup above exists to keep out
# of this public repository. Same reason cluster_id is sensitive in outputs.tf.
locals {
  zone       = sensitive(one(data.cloudflare_zones.this.result))
  account_id = local.zone.account.id
}

# The cluster's one way out; see applications/cloudflared for the connector
# that runs it. config_src = "cloudflare" is what lets the routing table below
# be a Terraform resource — a locally-managed tunnel keeps its ingress rules in
# a file on the connector, and cloudflared ignores those when it runs from a
# token anyway.
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = local.account_id
  name       = var.cluster_name
  config_src = "cloudflare"
}

# The routing table. cloudflared matches in order and requires the last rule to
# be a catch-all with no hostname, so it is appended here rather than left to
# whoever edits var.tunnel_routes.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      [for route in var.tunnel_routes : {
        hostname = "${route.subdomain}.${var.domain}"
        service  = route.service
      }],
      [{
        hostname = null
        service  = "http_status:404"
      }],
    )
  }
}

# Proxied so the hostname resolves to Cloudflare's edge, which is the only side
# that can open the tunnel; an unproxied CNAME to cfargotunnel.com resolves to
# nothing. TTL is forced to automatic (1) while a record is proxied.
resource "cloudflare_dns_record" "tunnel" {
  for_each = { for route in var.tunnel_routes : route.subdomain => route }

  zone_id = local.zone.id
  name    = "${each.key}.${var.domain}"
  type    = "CNAME"
  content = sensitive("${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com")
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform (infrastructure-as-code)"
}

# The tunnel resource does not carry the token, so fetching it is a second
# call — and one that Cloudflare gates behind *write* permission on tunnels,
# which is why the API token cannot be narrowed to read for this.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}
