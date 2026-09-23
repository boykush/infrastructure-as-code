# Backstage is served through the tunnel, but only to its owner: its guest
# sign-in and allow-all permission policy would otherwise hand anyone the catalog
# and the GitHub token it reads with. New Zero Trust organizations no longer get
# One-time PIN as a login method on their own, so it is declared here.
resource "cloudflare_zero_trust_access_identity_provider" "otp" {
  account_id = local.account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

resource "cloudflare_zero_trust_access_policy" "owner" {
  account_id = local.account_id
  name       = "Owner"
  decision   = "allow"
  include = [{
    email = { email = var.access_owner_email }
  }]
}

# One login method only, so the IdP picker is skipped and the PIN form comes
# straight up.
resource "cloudflare_zero_trust_access_application" "backstage" {
  account_id                = local.account_id
  name                      = "backstage"
  type                      = "self_hosted"
  domain                    = "backstage.${var.domain}"
  destinations              = [{ type = "public", uri = "backstage.${var.domain}" }]
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.otp.id]
  auto_redirect_to_identity = true
  policies = [{
    id         = cloudflare_zero_trust_access_policy.owner.id
    precedence = 1
  }]
}

# The one path that answers without a login: the MCP server coding agents read
# the catalog with. They have no identity for Access to check, and Backstage
# cannot lift its auth policy for a single plugin, so the narrowing happens
# here. Bypass skips enforcement; Allow would still send them to the PIN form.
resource "cloudflare_zero_trust_access_policy" "public" {
  account_id = local.account_id
  name       = "Public"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

# Scoped to the named server. Access evaluates the most specific path first, so
# everything else under backstage.<domain> — including /api/mcp-actions/v1
# itself, which always serves every action — stays with the application above.
resource "cloudflare_zero_trust_access_application" "catalog_mcp" {
  account_id   = local.account_id
  name         = "backstage-catalog-mcp"
  type         = "self_hosted"
  domain       = "backstage.${var.domain}/api/mcp-actions/v1/catalog"
  destinations = [{ type = "public", uri = "backstage.${var.domain}/api/mcp-actions/v1/catalog" }]
  policies = [{
    id         = cloudflare_zero_trust_access_policy.public.id
    precedence = 1
  }]
}
