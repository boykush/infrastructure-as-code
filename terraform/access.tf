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
