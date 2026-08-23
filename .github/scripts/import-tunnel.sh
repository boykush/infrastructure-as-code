#!/usr/bin/env bash
# Adopts the Cloudflare tunnel, its routing table and its DNS records into
# Terraform state. They predate terraform/cloudflare.tf; without this, the first
# apply builds a second tunnel and collides on the DNS record. Every ID is read
# back from the API so none has to be written down. Imports and one state edit
# only — this never applies.
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TF_DIR="$REPO_ROOT/terraform"
DOMAIN=${DOMAIN:-boykush.com}

trap 'echo "FAILED at line $LINENO" >&2' ERR

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (see the tunnel section of the README)}"

tf() { mise exec -- terraform -chdir="$TF_DIR" "$@"; }

# Registered with the runner so the identifiers this repository deliberately
# keeps out of git are replaced with *** in a public Actions log. A no-op when
# the script runs on a workstation.
mask() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$1"; fi; }

api() {
  local body
  body=$(curl -sS --fail-with-body \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/$1") || {
    echo "request failed: GET $1" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
  if [ "$(jq -r '.success' <<<"$body")" != "true" ]; then
    echo "API reported failure: GET $1" >&2
    jq -r '.errors' <<<"$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

# Terraform refuses an import whose address is already in state, so every step
# below checks first and reports what it skipped.
STATE=$(tf state list)
in_state() { grep -Fqx "$1" <<<"$STATE"; }

import_once() {
  local address=$1 id=$2
  if in_state "$address"; then
    echo "    already in state, skipping: $address"
    return 0
  fi
  tf import "$address" "$id"
}

echo "==> zone and account for $DOMAIN"
ZONES=$(api "zones?name=$DOMAIN")
ZONE_ID=$(jq -r '.result[0].id // empty' <<<"$ZONES")
ACCOUNT_ID=$(jq -r '.result[0].account.id // empty' <<<"$ZONES")
if [ -z "$ZONE_ID" ] || [ -z "$ACCOUNT_ID" ]; then
  echo "no zone named $DOMAIN is visible to this token" >&2
  exit 1
fi
mask "$ZONE_ID"
mask "$ACCOUNT_ID"
echo "    found"

echo "==> tunnels on the account"
TUNNELS=$(api "accounts/$ACCOUNT_ID/cfd_tunnel?is_deleted=false")
jq -r '.result[] | "    \(.name)  status=\(.status)  remote_config=\(.remote_config)"' <<<"$TUNNELS"
COUNT=$(jq '.result | length' <<<"$TUNNELS")
if [ "$COUNT" != 1 ]; then
  echo "expected exactly one tunnel, found $COUNT — import by hand instead" >&2
  exit 1
fi
TUNNEL_ID=$(jq -r '.result[0].id' <<<"$TUNNELS")
mask "$TUNNEL_ID"

echo "==> importing the tunnel and its routing table"
import_once cloudflare_zero_trust_tunnel_cloudflared.this "$ACCOUNT_ID/$TUNNEL_ID"
import_once cloudflare_zero_trust_tunnel_cloudflared_config.this "$ACCOUNT_ID/$TUNNEL_ID"

echo "==> importing the DNS record behind each published hostname"
CONFIG=$(api "accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations")
HOSTNAMES=$(jq -r '.result.config.ingress[]? | select(.hostname != null) | .hostname' <<<"$CONFIG")
if [ -z "$HOSTNAMES" ]; then
  echo "the tunnel publishes no hostname — nothing to match against var.tunnel_routes" >&2
  exit 1
fi
RECORDS=$(api "zones/$ZONE_ID/dns_records?type=CNAME&per_page=100")
while IFS= read -r hostname; do
  subdomain=${hostname%".$DOMAIN"}
  record_id=$(jq -r --arg n "$hostname" '.result[] | select(.name == $n) | .id' <<<"$RECORDS")
  if [ -z "$record_id" ]; then
    echo "no CNAME for $hostname" >&2
    exit 1
  fi
  mask "$record_id"
  import_once "cloudflare_dns_record.tunnel[\"$subdomain\"]" "$ZONE_ID/$record_id"
done <<<"$HOSTNAMES"

# The API never returns config_src, so ImportState leaves it null while the
# configuration says "cloudflare". That mismatch trips RequiresReplaceIfConfigured
# on the next plan, which would rebuild the tunnel and change the token
# cloudflared runs on. Write the value straight into state instead.
echo "==> reconciling config_src in state"
tf state pull > /tmp/tf-state-before.json
if [ "$(jq -r '[.resources[]
      | select(.type == "cloudflare_zero_trust_tunnel_cloudflared")
      | .instances[0].attributes.config_src] | first // "null"' /tmp/tf-state-before.json)" = "cloudflare" ]; then
  echo "    already set, skipping"
else
  jq '.serial += 1
      | (.resources[]
         | select(.type == "cloudflare_zero_trust_tunnel_cloudflared")
         | .instances[0].attributes.config_src) = "cloudflare"' \
    /tmp/tf-state-before.json > /tmp/tf-state-after.json
  tf state push /tmp/tf-state-after.json
  echo "    done (state before the edit is at /tmp/tf-state-before.json)"
fi

# A plan refreshes the cluster as well, which is the only reason this needs a
# DigitalOcean token; the import above does not.
if [ -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]; then
  echo "==> import complete. Skipping the plan: DIGITALOCEAN_ACCESS_TOKEN is unset."
  exit 0
fi

echo "==> plan — the tunnel must not show as replaced"
tf plan -no-color
