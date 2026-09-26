# Object storage for boykush/finlake's data lake: the Money Forward ME CSVs its
# ingest downloads and what its transform derives from them. R2 over DO Spaces
# because the lake is kilobytes a month — inside R2's free tier, where Spaces bills
# a flat $5 — and because creating it takes only the Cloudflare token CI already
# holds, where Spaces would need a second, all-bucket S3 key as a repository secret.
#
# Its tokens (read-write for the ingest on the owner's machine, read-only for the
# cluster) are created in the dashboard, never through Terraform: a token resource
# would put its secret into the HCP state.
resource "cloudflare_r2_bucket" "finlake" {
  account_id = local.account_id
  name       = "finlake"

  # Next to the cluster in sgp1. Without a hint R2 places the bucket near the
  # caller, which for an apply from CI is a US runner.
  location = "apac"
}
