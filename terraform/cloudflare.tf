# Zone and account IDs are read back from the domain name rather than written
# down, so neither identifier lands in this public repository. Costs the API
# token one extra permission (Zone: Zone Read), and every plan carries a
# deprecation warning about an attribute of the result nothing here reads —
# referencing the zone at all is enough to raise it.
data "cloudflare_zones" "this" {
  name = var.domain
}

# Sensitive so that tfcmt, which echoes plan output into pull request comments
# here, does not print what the lookup above exists to keep out of this public
# repository — the same reason cluster_id is sensitive in outputs.tf.
locals {
  zone_id    = sensitive(one(data.cloudflare_zones.this.result).id)
  account_id = sensitive(one(data.cloudflare_zones.this.result).account.id)
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
# whoever edits var.tunnel_routes. Cloudflare exposes no delete for it, so it
# goes away only with the tunnel it belongs to.
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

  # Guarded routes must never be live without Access in front of them, so the
  # routing table waits for the applications that guard them (access.tf).
  depends_on = [
    cloudflare_zero_trust_access_application.backstage,
    cloudflare_zero_trust_access_application.argocd,
  ]
}

# Proxied so the hostname resolves to Cloudflare's edge, which is the only side
# that can open the tunnel; an unproxied CNAME to cfargotunnel.com resolves to
# nothing. TTL is forced to automatic (1) while a record is proxied.
resource "cloudflare_dns_record" "tunnel" {
  for_each = { for route in var.tunnel_routes : route.subdomain => route }

  zone_id = local.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "CNAME"
  # Left unmarked, unlike zone_id and account_id: Cloudflare proxies
  # <UUID>.cfargotunnel.com only for records in the tunnel's own account, and
  # running the tunnel takes the token, not the UUID. Marking it would hide
  # nothing anyway: every plan and apply prints it as the tunnel's id.
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
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
